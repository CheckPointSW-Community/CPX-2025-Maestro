#!/bin/bash
source ./CPX_script_vars.txt
clear

# Function to login and get session ID
login_pre_ftw() {
    local session=$(mgmt_cli login user $gw_user password $gw_pass_initial -m $exl_gw --context gaia_api --format json --unsafe-auto-accept true | jq -r '.sid')
    if [[ -z "$session" ]]; then
        echo "Failed to get session ID. Quitting..."
        exit 1
    fi
    echo $session
}

# Function to login and get session ID
login_post_ftw() {
    read -p "Press Enter to continue or 'C' to cancel: " userInput
    if [[ "$userInput" == "C" || "$userInput" == "c" ]]; then
        echo "Script cancelled."
        exit 1
    fi
    local session=$(mgmt_cli login user $gw_user password $api_pass -m $exl_gw --context gaia_api --format json --unsafe-auto-accept true | jq -r '.sid')
    if [[ -z "$session" ]]; then
        echo "Failed to get session ID. Quitting..."
        exit 1
    fi
    echo $session
}

# Function for log output
log_message() {
  echo "$(date '+%Y-%m-%d %H:%M:%S') - $1"
}

# Function to logout
api_logout() {
    local session=$1
    mgmt_cli logout -m $exl_gw --context gaia_api --session-id $1
}

# Function to set management interface and other settings
set_mgmt_and_other_interface() {
    local session=$1
    mgmt_cli set password-policy password-history.check-history-enabled "false" -m $exl_gw --context gaia_api --format json --version 1.8 --session-id $1
    mgmt_cli set user name $gw_user password $api_pass -m $exl_gw --context gaia_api --format json --version 1.8 --session-id $1
    mgmt_cli set expert-password password $ftw_expert -m $exl_gw --context gaia_api --format json --version 1.8 --session-id $1
    mgmt_cli set physical-interface name $ftw_mgmt_int ipv4-address $exl_gw ipv4-mask-length $exl_gw_mask enabled True -m $exl_gw --context gaia_api --version 1.8 --format json --session-id $1
    mgmt_cli set static-route address "0.0.0.0" mask-length 0 next-hop.add.gateway $exl_vs0_dg type "gateway" comment "Default Route" -m $exl_gw --context gaia_api --version 1.8 --format json --session-id $1
}

# Function to set DNS
set_dns() {
    local session=$1
    mgmt_cli set dns primary $ftw_dns1 secondary $ftw_dns2 tertiary $ftw_dns3 suffix $ftw_domain -m $exl_gw --context gaia_api --format json --version 1.8 --session-id $1
}

# Function to set NTP
set_ntp() {
    local session=$1
    mgmt_cli set ntp enabled True preferred $ftw_ntp1 servers.1.address $ftw_ntp1 servers.1.type "pool" servers.1.version 4 servers.2.address $ftw_ntp2 servers.2.type "pool" servers.2.version 4 -m $exl_gw --context gaia_api --format json --version 1.8 --session-id $1
}

# Function to set hostname
set_hostname() {
    local session=$1
    mgmt_cli set hostname name $ftw_hostname -m $exl_gw --context gaia_api --format json --version 1.8 --session-id $1
}

# Function to set timezone
set_timezone() {
    local session=$1
    mgmt_cli set time-and-date timezone "$ftw_tzone" -m $exl_gw --context gaia_api --format json --version 1.8 --session-id $1
}

# Function to set large scale use
set_large_scale_use() {
    local session=$1
    mgmt_cli run-script script "echo 'fs.inotify.max_user_instances = 9048' >> /etc/sysctl.conf; echo 'kernel.sem = 500 64000 64 512' >> /etc/sysctl.conf; echo 'fs.file-max = 800000' >> /etc/sysctl.conf;" -m $exl_gw --context gaia_api --version 1.8 --format json --session-id $1
}

# Function to check appliance status
check_appliance_status() {
    sshpass -p $api_pass ssh -o "UserKnownHostsFile=/dev/null" -o StrictHostKeyChecking=no -o ConnectTimeout=$ftw_ssh_timeout $gw_user@$exl_gw "show uptime" &>/dev/null
    if [ $? -eq 0 ]; then
        echo "The appliance is up and reachable via SSH."
        return 0
    else
        echo "The appliance is down, not responding, wrong credentials or unreachable via SSH."
        return 1
    fi
}

# Function to set initial setup
set_initial_setup() {
    local session=$1
    mgmt_cli set initial-setup password $api_pass grub-password $api_grub_pass security-gateway.cluster-member $cxl_cluster security-gateway.activation-key $sic_key security-gateway.dynamically-assigned-ip $daip_gw security-gateway.vsnext $ftw_vsn_on security-gateway.elastic-xl $ftw_exl_on -m $exl_gw --context gaia_api --version 1.8 --format json --session-id $1 --sync true 2>&1
}

# Function to check appliance up
appliance_up() {
    local session=$1
    if check_appliance_status; then
        set_initial_setup $session
    else
        echo "Cannot proceed with FTW automation as the appliance is down."
        exit 1
    fi
}

# Function to start 8 minute timer
reboot_timer() {
    local reboot_timer=480
    echo "Waiting 8 minutes before checking again, to allow FTW to run and appliance to reboot"
    while [ $reboot_timer -gt 0 ]; do
        echo -ne "Time remaining in seconds: $reboot_timer\033[0K\r"
        sleep 10
        ((reboot_timer-=10))
    done
    echo -e "\nTime's up!"
}

# Function to check if GW is back up
gateway_running() {
    local session=$1
    for ((rebooting_gw=1; rebooting_gw<=30; rebooting_gw++)); do
        if check_appliance_status; then
            echo "Device is up, carry on!"
            session=$(mgmt_cli login user $gw_user password $api_pass -m $exl_gw --context gaia_api --format json --unsafe-auto-accept true | jq -r '.sid')
            mgmt_cli set password-policy password-history.check-history-enabled "true" -m $exl_gw --context gaia_api --format json --version 1.8 --session-id $1
            api_logout $session
            break
        else
            echo "Device is down. Check again in 20 seconds."
            sleep 20
        fi
    done
}

# Main script execution
echo "This script will run the First Time Wizard on the device, setting it as ElasticXL and VSNext mode"
session=$(login_pre_ftw)
echo "Setting up Mgmt interface and other settings"
set_mgmt_and_other_interface $session
echo "Setting DNS"
set_dns $session
echo "Setting NTP"
set_ntp $session
echo "Setting Hostname"
set_hostname $session
echo "Setting Timezone"
set_timezone $session
echo "Setting for large scale use"
set_large_scale_use $session
echo "Running appliance up test"
appliance_up $session
reboot_timer
echo "Restoring settings for password complexity post FTW"
session=$(login_post_ftw)
gateway_running $session
api_logout $session
