#!/bin/bash
source ./Maestro_script_vars.txt

clear

# Function to login to MHO and get session ID
login_device() {
    #Passed vars $mho_user $mho_pass $mho_ip
    local device_user=$1
    local device_pass=$2
    local device_IP=$3
    read -p "Press Enter to continue or 'C' to cancel: " userInput
    if [[ "$userInput" == "C" || "$userInput" == "c" ]]; then
        echo "Script cancelled."
        exit 1
    fi
    local session=$(mgmt_cli login user $device_user password $device_pass -m $device_IP --context gaia_api --format json --unsafe-auto-accept true | jq -r '.sid')
    if [[ -z "$session" ]]; then
        echo "Failed to get session ID. Quitting..."
        exit 1
    fi
    #echo "Continuing..."
    echo $session
}

# Function for log output
log_message() {
  echo "$(date '+%Y-%m-%d %H:%M:%S') - $1"
}

# Function to logout
api_logout() {
    local session=$1
    local device_ip=$2
    mgmt_cli logout -m $device_ip --context gaia_api --session-id $session
}

# Function to discard any outstanding change before trying to work on the group
maestro_discard_outstanding_changes() {
    local session=$1
    echo "Discarding outstanding changes before making any new changes"
    mgmt_cli discard-maestro-security-groups-changes -m $mho_ip --context gaia_api --session-id $session > /dev/null 2>&1
}

# Function to Show Gateways in Maestro
maestro_show_gateways() {
    local session=$1
    full_output=$(mgmt_cli show maestro-gateways -m $mho_ip --version 1.8 --context gaia_api --format json --session-id $session | jq .)
    sh_maestro_gw=$(echo "$full_output" | jq -c '.gateways[] | select(.state == "UNASSIGNED") | {id, model, major: .version.major}')
}

# Function to Create a Security Group in Maestro
maestro_create_group() {
    local session=$1
    local mgmt_count=$2
    shift 2
    local mgmt_interfaces=("${@:1:$mgmt_count}")
    shift $mgmt_count
    local data_count=$1
    shift 1
    local data_interfaces=("${@:1:$data_count}")
    shift $data_count
    local num_gateways=$1
    shift 1
    local system_name=$1
    local system_ip_mask=$2
    local system_gateway=$3
    local mho_ip=$4

    # Validate system_ip_mask
    if ! validate_ipv4_cidr "$system_ip_mask"; then
         log_message "Invalid system IP/Mask format: $system_ip_mask"
        exit 1
    fi

    IFS='/' read -r Maestro_Group_1_SMO_IP Maestro_Group_1_SMO_Mask_Length <<< "$system_ip_mask"

    # Validate management interfaces
    for iface in "${mgmt_interfaces[@]}"; do
        if [[ ! $iface =~ ^eth[12]-Mgmt[1-4]$ ]]; then
            log_message "Invalid management interface name: $iface"
            exit 1
        fi
    done

    # Validate data interfaces
    for iface in "${data_interfaces[@]}"; do
        if [[ ! $iface =~ ^eth[12]-[0-9]{2}$ ]]; then
            log_message "Invalid data interface name: $iface"
            exit 1
        fi
    done

    # Generate gateway IDs
    local gateways=()
    for ((i=0; i<num_gateways; i++)); do
        gateways+=($(echo "$sh_maestro_gw" | jq -r ".id" | sed -n "$((i+1))p"))
    done

    #echo "Gateways: ${gateways[@]}"

    # Check if enough gateways are available
    if [[ ${#gateways[@]} -lt $num_gateways ]]; then
        log_message "Not enough gateways with the Unassigned state to continue. Exiting script."
        exit 1
    fi

    # Create the group
    local cmd="mgmt_cli add maestro-security-group"
    for ((i=0; i<${#mgmt_interfaces[@]}; i++)); do
        cmd+=" interfaces.$((i+1)).name ${mgmt_interfaces[$i]}"
    done
    for ((i=0; i<${#data_interfaces[@]}; i++)); do
        cmd+=" interfaces.$((i+1+${#mgmt_interfaces[@]})).name ${data_interfaces[$i]}"
    done
    for ((i=0; i<num_gateways; i++)); do
        cmd+=" gateways.$((i+1)).id ${gateways[$i]}"
    done
    cmd+=" sites.1.id $Maestro_Group_1_SiteID sites.1.description Site_1 ftw-configuration.hostname $system_name ftw-configuration.is-vsx $Maestro_Group_1_VirtGW ftw-configuration.one-time-password $Maestro_Group_1_OTP ftw-configuration.admin-password $Maestro_Group_1_pass mgmt-connectivity.ipv4-address $sg_ip mgmt-connectivity.ipv4-mask-length $sg_mask mgmt-connectivity.default-gateway $system_gateway description SecGrp_created_via_API -m $mho_ip --context gaia_api --version 1.8 --format json --session-id $session"
    eval $cmd  > /dev/null 2>&1
}

# Function to apply configuration
apply_config() {
    local session=$1
    local mho_ip=$2

    # Apply configuration and capture output
    makegroup=$(mgmt_cli apply-maestro-security-groups-changes -m $mho_ip --context gaia_api --format json --session-id $session 2>&1)
    if [ $? -ne 0 ]; then
        echo "Error applying configuration: $makegroup"
        return 1
    fi
    ActiveSMO_Group=$(echo "$makegroup" | jq -c '.["security-groups"][] | .sites[] | {id}')
    if [ $? -ne 0 ]; then
        echo "Error extracting group ID: $makegroup"
        return 1
    fi
    ActiveSMO_Group=$(echo $ActiveSMO_Group | jq '.id')
    echo "The group ID that was created is:" $ActiveSMO_Group
}
validate_ipv4_cidr() {
    local ip_cidr=$1
    if [[ $ip_cidr =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/([0-9]|[12][0-9]|3[0-2])$ ]]; then
        sg_ip=${BASH_REMATCH[0]}
        sg_mask=${BASH_REMATCH[2]}
        IFS='/' read -r sg_ip sg_mask <<< "$ip_cidr"
        IFS='.' read -r -a octets <<< "$sg_ip"
        for octet in "${octets[@]}"; do
            if ((octet < 0 || octet > 255)); then
                return 1
            fi
        done
        return 0
    else
        return 1
    fi
}

# Function to check if SG can be accessed
check_sg_ssh_access() {
    sshtest=$(sshpass -p "$api_pass" ssh -o "UserKnownHostsFile=/dev/null" -o StrictHostKeyChecking=no -o ConnectTimeout="$ftw_ssh_timeout" "$gw_user@$sg_ip" "show uptime" 2>&1)
    if [[ $? -eq 0 || "$sshtest" == *"Warning: Permanently added"* ]]; then
        echo "The Group is up and reachable via SSH."
        return 0
        break
    else
        echo "The Group is down, not responding, wrong credentials or unreachable via SSH."
        return 1
    fi
}

# Function to start 8 minute timer
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

# Function to check if SecGroup is Active
sg_active() {
    local session=$1
    local sg_ip=$2
    local mho_ip=$3
    for ((rebooting_gw=1; rebooting_gw<=30; rebooting_gw++)); do
        if check_sg_ssh_access; then
            echo "After the check ssh access check...."
            echo "Running command: mgmt_cli show maestro-security-group id $ActiveSMO_Group -m $mho_ip --context gaia_api --format json --unsafe-auto-accept true --session-id $session | jq ."
            mho_full_output=$(mgmt_cli show maestro-security-group id $ActiveSMO_Group -m $mho_ip --context gaia_api --format json --unsafe-auto-accept true --session-id $session | jq .)
            echo "MHO Full Output: $mho_full_output"
            ActiveSMO_ID=$(echo "$mho_full_output" | jq -c '.gateways[] | select(.state == "ACTIVE") | {id}')
            echo "ActiveSMO_ID: $ActiveSMO_ID"
            if [[ -n "$ActiveSMO_ID" ]]; then
              reboot_timer 5 "Group to settle after FTW and reboot"
              sg_login_session=$(mgmt_cli login user $api_user password $Maestro_Group_1_pass -m $sg_ip --context gaia_api --format json --unsafe-auto-accept true | jq -r '.sid')
              echo "Setting DNS"
              set_dns $sg_login_session $sg_ip
              echo "Setting NTP"
              set_ntp $sg_login_session $sg_ip
              echo "Setting Timezone"
              set_timezone $sg_login_session $sg_ip
              echo "Setting for large scale use"
              set_large_scale_use $sg_login_session $sg_ip
              api_logout $sg_login_session $sg_ip
              return 1
              break
            fi
        else
            echo "Device is down. Check again in 20 seconds."
            sleep 20
        fi
    done
}


# Function to set DNS
set_dns() {
    local session=$1
    local device_ip=$2
    mgmt_cli set dns primary $sg_ftw_dns1 secondary $sg_ftw_dns2 tertiary $sg_ftw_dns3 suffix $ftw_domain -m $device_ip --context gaia_api --format json --version 1.8 --session-id $1
}

# Function to set NTP
set_ntp() {
    local session=$1
    local device_ip=$2
    mgmt_cli set ntp enabled True preferred $sg_ftw_ntp1 servers.1.address $sg_ftw_ntp1 servers.1.type "pool" servers.1.version 4 servers.2.address $sg_ftw_ntp2 servers.2.type "pool" servers.2.version 4 -m $device_ip --context gaia_api --format json --version 1.8 --session-id $1
}

# Function to set timezone
set_timezone() {
    local session=$1
    local device_ip=$2
    mgmt_cli set time-and-date timezone "$ftw_tzone" -m $device_ip --context gaia_api --format json --version 1.8 --session-id $1
}

# Function to set large scale use
set_large_scale_use() {
    local session=$1
    local device_ip=$2
    mgmt_cli run-script script "echo 'fs.inotify.max_user_instances = 9048' >> /etc/sysctl.conf; echo 'kernel.sem = 500 64000 64 512' >> /etc/sysctl.conf; echo 'fs.file-max = 800000' >> /etc/sysctl.conf;" -m $device_ip --context gaia_api --version 1.8 --format json --session-id $1
}

# Function to check appliance status
check_appliance_status() {
    sshpass -p $api_pass ssh -o "UserKnownHostsFile=/dev/null" -o StrictHostKeyChecking=no -o ConnectTimeout=$ftw_ssh_timeout $gw_user@$sg_ip "show uptime" >/dev/null
    if [ $? -eq 0 ]; then
        echo "The appliance is up and reachable via SSH."
        return 0
    else
        echo "The appliance is down, not responding, wrong credentials or unreachable via SSH."
        return 1
    fi
}


# Main script execution
if [[ $# -ne 9 ]]; then
    echo "Usage: $0 <number_of_gateways> <mgmt_interface_count> <management_interfaces> <data_interface_count> <data_interfaces> <security_group_name> <security_group_ip/mask> <security_group_default_gateway> <mho_IP_to_connect_to>"
    echo "Example: $0 2 2 'eth1-Mgmt1 eth2-Mgmt2' 6 'eth1-05 eth2-05 eth1-14 eth2-14 eth1-23 eth2-23' My-SecGroup '192.168.14.10/24' '192.168.14.1' '192.168.05.23'"
    exit 1
fi

num_gateways=$1
mgmt_count=$2
mgmt_interfaces=($3)
data_count=$4
data_interfaces=($5)
system_name=$6
system_ip_mask=$7
system_gateway=$8
mho_ip=$9

clear

log_message "Starting the script to make a Security Group using APIs."
echo "Ive read you want to make a group with $num_gateways gateways"
echo "You have asked for $mgmt_count management interfaces"
echo "The Mgmt interface names are: "${mgmt_interfaces[@]}
echo "You requested $data_count data interfaces"
echo "The data interface names are: "${data_interfaces[@]}
echo "You requested $system_name to be the Security Group name"
echo "The group will be configured with this IP and mask: "$system_ip_mask" and default gateway "$system_gateway
echo "And finally, a connection to the MHO with address $mho_ip will be made, using the credentials in the local settings file to make the group"

#echo "Here we go...!"
echo "***************************************"

session=$(login_device $mho_user $mho_pass $mho_ip)
validate_ipv4_cidr "$system_ip_mask"
maestro_show_gateways $session
maestro_discard_outstanding_changes $session
maestro_create_group $session $mgmt_count "${mgmt_interfaces[@]}" $data_count "${data_interfaces[@]}" $num_gateways $system_name $system_ip_mask $system_gateway $mho_ip
apply_config $session $mho_ip
reboot_timer 620 "FTW to run and appliance to reboot"
#Login again, after reboot...
session=$(login_device $mho_user $mho_pass $mho_ip)
sg_active $session $sg_ip $mho_ip
api_logout $session $mho_ip
