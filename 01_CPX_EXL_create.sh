#!/bin/bash
source ./Combined_vars.txt
bold=$(tput bold)
normal=$(tput sgr0)
clear

# Function to login to appliance BEFORE the FTW has been run, but AFTER you have manually set an IP/mask/gateway and get session ID
login_pre_ftw() {
    local session=$(mgmt_cli login user $EXL_Group_user password $EXL_Group_Appliance_initial_pass -m $EXL_Group_IP --context gaia_api --format json --unsafe-auto-accept true | jq -r '.sid')
    if [[ -z "$session" ]]; then
        echo "Failed to get session ID. Quitting..."
        exit 1
    fi
    echo $session
}

# Function to login to appliance AFTER the FTW has been run, but AFTER you have manually set an IP/mask/gateway and get session ID
login_post_ftw() {
    read -p "Press Enter to continue or 'C' to cancel: " userInput
    if [[ "$userInput" == "C" || "$userInput" == "c" ]]; then
        echo "Script cancelled."
        exit 1
    fi
    local session=$(mgmt_cli login user $EXL_Group_user password $EXL_Group_pass -m $EXL_Group_IP --context gaia_api --format json --unsafe-auto-accept true | jq -r '.sid')
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
    mgmt_cli logout -m $EXL_Group_IP --context gaia_api --session-id $1
}

# Function to set management interface and other settings
set_mgmt_and_other_settings() {
    local session=$1
    mgmt_cli set password-policy password-history.check-history-enabled "false" -m $EXL_Group_IP --context gaia_api --format json --version $GAIA_API_Ver --session-id $1 > /dev/null 2>&1
    mgmt_cli set user name $EXL_Group_user password $EXL_Group_pass -m $EXL_Group_IP --context gaia_api --format json --version $GAIA_API_Ver --session-id $1 > /dev/null 2>&1
    mgmt_cli set expert-password password-hash $EXL_Group_ExpertHash -m $EXL_Group_IP --context gaia_api --format json --version $GAIA_API_Ver --session-id $1 > /dev/null 2>&1
    #Note, setting the interface settings (or default route) to something else, while connected via SSH is a bad idea :) Included as an example - for use via console server for example
    #mgmt_cli set physical-interface name $EXL_Group_ftw_mgmt_int ipv4-address $EXL_Group_IP ipv4-mask-length $EXL_Group_IP_mask enabled True -m $EXL_Group_IP --context gaia_api --version $GAIA_API_Ver --format json --session-id $1 > /dev/null 2>&1
    #mgmt_cli set static-route address "0.0.0.0" mask-length 0 next-hop.add.gateway $EXL_Group_DG type "gateway" comment "Default Route" -m $EXL_Group_IP --context gaia_api --version $GAIA_API_Ver --format json --session-id $1 > /dev/null 2>&1
}

# Function to set DNS
set_dns() {
    local session=$1
    mgmt_cli set dns primary "$EXL_Group_dns1" secondary "$EXL_Group_dns2" tertiary "$EXL_Group_dns3" suffix "$EXL_Group_dns_suffix" -m $EXL_Group_IP --context gaia_api --format json --version $GAIA_API_Ver --session-id $1 > /dev/null 2>&1
}

# Function to set NTP
set_ntp() {
    local session=$1
    mgmt_cli set ntp enabled True preferred "$EXL_Group_ntp1" servers.1.address "$EXL_Group_ntp1" servers.1.type "server" servers.1.version 4 servers.2.address "$EXL_Group_ntp2" servers.2.type "server" servers.2.version 4 -m $EXL_Group_IP --context gaia_api --format json --version $GAIA_API_Ver --session-id $1 > /dev/null 2>&1
}

# Function to set hostname
set_hostname() {
    local session=$1
    mgmt_cli set hostname name $EXL_Group_hostname -m $EXL_Group_IP --context gaia_api --format json --version $GAIA_API_Ver --session-id $1 > /dev/null 2>&1
}

# Function to set timezone
set_timezone() {
    local session=$1
    mgmt_cli set time-and-date timezone "$EXL_Group_ftw_tzone" -m $EXL_Group_IP --context gaia_api --format json --version $GAIA_API_Ver --session-id $1 > /dev/null 2>&1
}

# Function to set large scale use
set_large_scale_use() {
    local session=$1
    #Settings needed for large installs. Remember, root partition needs to be resized (lvm _manager) on each appliance before deploying many VS. These settings were tested with 100+ VS.
    mgmt_cli run-script script "echo 'fs.inotify.max_user_instances = 9048' >> /etc/sysctl.conf; echo 'kernel.sem = 500 64000 64 512' >> /etc/sysctl.conf; echo 'fs.file-max = 800000' >> /etc/sysctl.conf;" -m $EXL_Group_IP --context gaia_api --version $GAIA_API_Ver --format json --session-id $1 > /dev/null 2>&1
}

# Function to check appliance status
check_appliance_status() {
    sshpass -p $EXL_Group_pass ssh -o "UserKnownHostsFile=/dev/null" -o StrictHostKeyChecking=no -o ConnectTimeout=$ftw_ssh_timeout $EXL_Group_user@$EXL_Group_IP "show uptime" &>/dev/null
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
    mgmt_cli set initial-setup password $EXL_Group_pass grub-password $EXL_Group_grub_pass security-gateway.cluster-member $EXL_Group_cluster_state security-gateway.activation-key $EXL_Group_sic_key security-gateway.dynamically-assigned-ip $EXL_Group_daip_gw security-gateway.vsnext $EXL_Group_ftw_vsn_on_state security-gateway.elastic-xl $EXL_Group_ftw_exl_on_state -m $EXL_Group_IP --context gaia_api --version $GAIA_API_Ver --format json --session-id $1 --sync true > /dev/null 2>&1
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

# Function to start timer
reboot_timer() {
    local reboot_timer=$1
    reason_message=$2
    echo "Waiting $1 seconds before checking again, to allow $2."
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
            #In labs, --unsafe-auto-accept true is helpful, as it allows you to rebuild the same system multiple times, without having cert issues. May not be suitable for your production environment!
            session=$(mgmt_cli login user $EXL_Group_user password $EXL_Group_pass -m $EXL_Group_IP --context gaia_api --format json --unsafe-auto-accept true | jq -r '.sid')
            mgmt_cli set password-policy password-history.check-history-enabled "true" -m $EXL_Group_IP --context gaia_api --format json --version $GAIA_API_Ver --session-id $1 > /dev/null 2>&1
            api_logout $session
            break
        else
            echo "Device is down. Check again in 20 seconds."
            sleep 20
        fi
    done
}

# Main script execution
echo "This script will run the First Time Wizard on the device, in ElasticXL mode"
session=$(login_pre_ftw)
echo "Setting up Mgmt interface and other settings"
set_mgmt_and_other_settings $session
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
reboot_timer 480 "FTW to run and appliance(s) to reboot"
echo "Restoring settings for password complexity post FTW"
session=$(login_post_ftw)
gateway_running $session
api_logout $session
