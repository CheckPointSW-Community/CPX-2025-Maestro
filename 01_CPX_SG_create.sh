#!/bin/bash
source ./Combined_vars.txt
bold=$(tput bold)
normal=$(tput sgr0)

clear

# Function to login to MHO and get session ID
login_device() {
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
    echo $session
}

# Function for log output
log_message() {
  echo "${bold}$(date '+%Y-%m-%d %H:%M:%S') - $1${normal}"
}

# Function to logout
api_logout() {
    local session=$1
    local device_ip=$2
    echo "Logging out of the system IP $2"
    mgmt_cli logout -m $device_ip --context gaia_api --session-id $session
}

# Function to discard any outstanding change before trying to work on the group
maestro_discard_outstanding_changes() {
    local session=$1
    local device_ip=$2
    echo "Discarding outstanding changes before making any new changes"
    mgmt_cli discard-maestro-security-groups-changes -m $device_ip --context gaia_api --session-id $session > /dev/null 2>&1
}

# Function to Show Gateways in Maestro
maestro_show_gateways() {
    local session=$1
    echo "Logging into the MHO, to find the attached gateways and then filtering for those that are unassigned therefore can be used"
    full_output=$(mgmt_cli show maestro-gateways -m $Maestro_Group_MHO_IP --version $GAIA_API_Ver --context gaia_api --format json --session-id $session | jq .)
    sh_maestro_gw=$(echo "$full_output" | jq -c '.gateways[] | select(.state == "UNASSIGNED") | {id, model, major: .version.major}')
}

# Function to Create a Security Group in Maestro
maestro_create_group() {
    # Passed vars $session $Mgmt_Interface_Count "${Mgmt_Interface_eth_Names[@]}" $Data_Interface_Count "${Data_Interface_eth_Names[@]}" $Maestro_Group_GW_Quantity $Maestro_Group_System_Name $Maestro_Group_System_CIDR_IP_Mask $Maestro_Group_System_Def_GW $Maestro_Group_MHO_IP

    local session=$1
    local Mgmt_Interface_Count=$2
    shift 2
    local Mgmt_Interface_eth_Names=("${@:1:$Mgmt_Interface_Count}")
    shift $Mgmt_Interface_Count
    local Data_Interface_Count=$1
    shift 1
    local Data_Interface_eth_Names=("${@:1:$Data_Interface_Count}")
    shift $Data_Interface_Count
    local Maestro_Group_GW_Quantity=$1
    shift 1
    local Maestro_Group_System_Name=$1
    local Maestro_Group_System_CIDR_IP_Mask=$2
    local Maestro_Group_System_Def_GW=$3
    local Maestro_Group_MHO_IP=$4

    # Validate Maestro_Group_System_CIDR_IP_Mask
    if ! validate_ipv4_cidr "$Maestro_Group_System_CIDR_IP_Mask"; then
         log_message "Invalid system IP/Mask format: $Maestro_Group_System_CIDR_IP_Mask"
         api_logout $session $Maestro_Group_MHO_IP
        exit 1
    fi

    IFS='/' read -r Maestro_Group_SMO_IP Maestro_Group_SMO_Mask_Length <<< "$Maestro_Group_System_CIDR_IP_Mask"

    # Validate management interfaces
    echo "Testing Mgmt interface is in the expected format."
    #This code block could be ignored if needed
    for iface in "${Mgmt_Interface_eth_Names[@]}"; do
        if [[ ! $iface =~ ^eth[12]-Mgmt[1-4]$ ]]; then
            log_message "Invalid management interface name: $iface"
            api_logout $session $Maestro_Group_MHO_IP
            exit 1
        fi
    done

    # Validate data interfaces
    echo "Testing Data interfaces are in the expected format."
    #This code block could be ignored if needed
    for iface in "${Data_Interface_eth_Names[@]}"; do
        if [[ ! $iface =~ ^eth[12]-[0-9]{2}$ ]]; then
            log_message "Invalid data interface name: $iface"
            api_logout $session $Maestro_Group_MHO_IP
            exit 1
        fi
    done

    # Generate gateway IDs
    local gateways=()
    echo "Extracting a list of gateway IDs (Serial), based on the output of maestro_show_gateways function by reading contents of sh_maestro_gw"
    for ((i=0; i<Maestro_Group_GW_Quantity; i++)); do
        gateways+=($(echo "$sh_maestro_gw" | jq -r ".id" | sed -n "$((i+1))p"))
    done
    # Check if enough gateways are available
    echo "Testing if we have enough gateways currently in unassigned state, versus the number you requested for the group"
    if [[ ${#gateways[@]} -lt $Maestro_Group_GW_Quantity ]]; then
        log_message "Not enough gateways with the Unassigned state to continue. Exiting script."
        api_logout $session $Maestro_Group_MHO_IP
        exit 1
    fi
    # Create the group
    echo "Generating the command that will create the security group via API"
    #Start with mgmt_cli add maestro-security-group then add each requested mgmt interface to the list, along with its ID
    local cmd="mgmt_cli add maestro-security-group"
    for ((i=0; i<${#Mgmt_Interface_eth_Names[@]}; i++)); do
        cmd+=" interfaces.$((i+1)).name ${Mgmt_Interface_eth_Names[$i]}"
    done
    #Then add each requested Data interface to the list, along with its ID
    for ((i=0; i<${#Data_Interface_eth_Names[@]}; i++)); do
        cmd+=" interfaces.$((i+1+${#Mgmt_Interface_eth_Names[@]})).name ${Data_Interface_eth_Names[$i]}"
    done
    #Finally, add each requested gateway to the list, along with its ID
    for ((i=0; i<Maestro_Group_GW_Quantity; i++)); do
        cmd+=" gateways.$((i+1)).id ${gateways[$i]}"
    done
    #Finally, add in some static settings via API, the values of this can be seen in the ./Combined_vars.txt file
    #Bug with API cretion on bond, required w/a mgmt-interface-settings.create-mgmt-as-bond False mgmt-interface-settings.bond-mode active-backup. IA and MM notified 9Jan25. Temp fix on MHO, to sgdb.py in /usr/lib/python/sgdb/ provided to TK.
    #See https://support.checkpoint.com/results/sk/sk183031 
    #cmd+=" sites.1.id $Maestro_Group_SiteID sites.1.description Site_1 ftw-configuration.hostname $Maestro_Group_System_Name ftw-configuration.is-vsx $Maestro_Group_VirtGW ftw-configuration.one-time-password $Maestro_Group_OTP ftw-configuration.admin-password $Maestro_Group_pass mgmt-connectivity.ipv4-address $sg_ip mgmt-connectivity.ipv4-mask-length $sg_mask mgmt-interface-settings.create-mgmt-as-bond False mgmt-interface-settings.bond-mode active-backup  mgmt-connectivity.default-gateway $Maestro_Group_System_Def_GW description SecGrp_created_via_API -m $Maestro_Group_MHO_IP --context gaia_api --version $GAIA_API_Ver --format json --session-id $session"
    cmd+=" sites.1.id $Maestro_Group_SiteID sites.1.description Site_1 ftw-configuration.hostname $Maestro_Group_System_Name ftw-configuration.is-vsx $Maestro_Group_VirtGW ftw-configuration.one-time-password $Maestro_Group_OTP ftw-configuration.admin-password $Maestro_Group_pass mgmt-connectivity.ipv4-address $sg_ip mgmt-connectivity.ipv4-mask-length $sg_mask mgmt-connectivity.default-gateway $Maestro_Group_System_Def_GW description SecGrp_created_via_API -m $Maestro_Group_MHO_IP --context gaia_api --version $GAIA_API_Ver --format json --session-id $session"
   eval $cmd > /dev/null 2>&1
}

# Function to apply configuration
apply_config() {
    local session=$1
    local Maestro_Group_MHO_IP=$2
    echo "Applying changes to the MHO: $Maestro_Group_MHO_IP"
    # Apply configuration and capture output
    makegroup=$(mgmt_cli apply-maestro-security-groups-changes -m $Maestro_Group_MHO_IP --context gaia_api --format json --session-id $session 2>&1)
    if [ $? -ne 0 ]; then
        echo "Error applying configuration: $makegroup"
        api_logout $session $Maestro_Group_MHO_IP
        return 1
    fi
    ActiveSMO_Group=$(echo "$makegroup" | jq -c '.["security-groups"][] | .sites[] | .id')
    echo "Extracting the Security group ID of the group just created"
    if [ $? -ne 0 ]; then
        echo "Error extracting group ID: $makegroup"
        api_logout $session $Maestro_Group_MHO_IP
        return 1
    fi
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

# Function to check if SecGroup is Active
sg_active() {
    local session=$1
    local sg_ip=$2
    local Maestro_Group_MHO_IP=$3
    for ((rebooting_gw=1; rebooting_gw<=30; rebooting_gw++)); do
        if check_sg_ssh_access; then
            echo "Checking which appliance is active...."
            #ActiveSMO_Group=1
            #Line above used for debugging if much of the build code (up to and including reboot) is skipped
            mho_full_output=$(mgmt_cli show maestro-security-group id $ActiveSMO_Group -m $Maestro_Group_MHO_IP --context gaia_api --format json --unsafe-auto-accept true --session-id $session | jq .)
            ActiveSMO_Serial=$(echo "$mho_full_output" | jq -r '.gateways[] | select(.state == "ACTIVE") | .id')
            ActiveSMO_ID=$(echo "$mho_full_output" | jq -c '.gateways[] | select(.state == "ACTIVE") | {id}')
            echo "The Active device after initial FTW is: $ActiveSMO_Serial"
            if [[ -n "$ActiveSMO_ID" ]]; then
              sg_login_session=$(mgmt_cli login user $Maestro_Group_user password $Maestro_Group_pass -m $sg_ip --context gaia_api --format json --unsafe-auto-accept true | jq -r '.sid')
              set_dns $sg_login_session $sg_ip
              set_timezone $sg_login_session $sg_ip
              set_large_scale_use $sg_login_session $sg_ip
              set_history_and_expert $sg_login_session $sg_ip
              #Setting NTP needs further check, due to API restart - possible issue to check.
              set_ntp $sg_login_session $sg_ip
              api_logout $sg_login_session $sg_ip
              return 1
              break
            fi
        else
            echo "Device is down. Check again in 30 seconds."
            sleep 30
        fi
    done
}

# Function to set DNS
set_dns() {
    local sg_login_session=$1
    local device_ip=$2
    echo "Setting DNS"
    mgmt_cli set dns primary "$Maestro_Group_dns1" secondary "$Maestro_Group_dns2" tertiary "$Maestro_Group_dns3" suffix "$Maestro_Group_dns_suffix" -m $2 --context gaia_api --format json --version $GAIA_API_Ver --session-id $1 > /dev/null 2>&1
}

# Function to set NTP
set_ntp() {
    local sg_login_session=$1
    local device_ip=$2
    echo "Setting NTP"
    mgmt_cli set ntp enabled True preferred "$Maestro_Group_ntp1" servers.1.address "$Maestro_Group_ntp1" servers.1.type "server" servers.1.version 4 servers.2.address "$Maestro_Group_ntp2" servers.2.type "server" servers.2.version 4 -m $2 --context gaia_api --format json --version $GAIA_API_Ver --session-id $1 > /dev/null 2>&1
}

# Function to set Expert pass and other settings
set_history_and_expert() {
    local sg_login_session=$1
    local device_ip=$2
    echo "Setting password policy and expert password for lab easy password policy and expert password for lab easy use. Remember to re-enable"
    #Complexity change not needed on MHO - commented out
    #mgmt_cli set password-policy password-history.check-history-enabled "false" -m $2 --context gaia_api --format json --version $GAIA_API_Ver --session-id $1 > /dev/null 2>&1
    mgmt_cli set expert-password password-hash $Maestro_Group_ExpertHash -m $2 --context gaia_api --format json --version $GAIA_API_Ver --session-id $1 > /dev/null 2>&1
    mgmt_cli set grub-password password-hash $Maestro_Group_GrubHash -m $2 --context gaia_api --format json --version $GAIA_API_Ver --session-id $1 > /dev/null 2>&1
}

# Function to set timezone
set_timezone() {
    local sg_login_session=$1
    local device_ip=$2
    echo "Setting Timezone"
    mgmt_cli set time-and-date timezone "\"$Maestro_Group_ftw_tzone\"" -m $2 --context gaia_api --format json --version $GAIA_API_Ver --session-id $1 > /dev/null 2>&1
}

# Function to set large scale use
set_large_scale_use() {
    local sg_login_session=$1
    local device_ip=$2
    echo "Setting for large scale use"
    mgmt_cli run-script script "echo 'fs.inotify.max_user_instances = 9048' >> /etc/sysctl.conf; echo 'kernel.sem = 500 64000 64 512' >> /etc/sysctl.conf; echo 'fs.file-max = 800000' >> /etc/sysctl.conf;" -m $2 --context gaia_api --version $GAIA_API_Ver --format json --session-id $1 > /dev/null 2>&1
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
    echo "Usage: $0 <number_of_gateways> <mgmt_interface_count> <management_interfaces> <data_interface_count> <Data_Interface_eth_Names> <security_group_name> <security_group_ip/mask> <security_group_default_gateway> <Maestro_Group_MHO_IP_to_connect_to>"
    echo "Example: $0 2 2 'eth1-Mgmt1 eth2-Mgmt2' 6 'eth1-05 eth2-05 eth1-14 eth2-14 eth1-23 eth2-23' My-SecGroup '192.168.14.10/24' '192.168.14.1' '192.168.05.23'"
    exit 1
fi

Maestro_Group_GW_Quantity=$1
Mgmt_Interface_Count=$2
Mgmt_Interface_eth_Names=($3)
Data_Interface_Count=$4
Data_Interface_eth_Names=($5)
Maestro_Group_System_Name=$6
Maestro_Group_System_CIDR_IP_Mask=$7
Maestro_Group_System_Def_GW=$8
Maestro_Group_MHO_IP=$9

clear

log_message "Starting the script to make a Security Group using APIs."
echo "About to create a group with ${bold}$Maestro_Group_GW_Quantity gateways${normal}"
echo "You have asked for ${bold}$Mgmt_Interface_Count management interfaces${normal}"
echo "The Mgmt interface names are: "${bold}${Mgmt_Interface_eth_Names[@]}${normal}
echo "You requested ${bold}$Data_Interface_Count data interfaces${normal}"
echo "The data interface names are: "${bold}${Data_Interface_eth_Names[@]}${normal}
echo "You requested ${bold}$Maestro_Group_System_Name${normal} to be the Security Group name"
echo "The group will be configured with this IP and mask: "${bold}$Maestro_Group_System_CIDR_IP_Mask${normal}" and default gateway "${bold}$Maestro_Group_System_Def_GW${normal}
echo "And finally, a connection to the MHO with address ${bold}$Maestro_Group_MHO_IP${normal} will be made, using the credentials in the local settings file to make the group"
echo "***************************************"

session=$(login_device $Maestro_Group_MHO_user $Maestro_Group_MHO_pass $Maestro_Group_MHO_IP)
validate_ipv4_cidr "$Maestro_Group_System_CIDR_IP_Mask"
maestro_show_gateways $session
maestro_discard_outstanding_changes $session $Maestro_Group_MHO_IP
maestro_create_group $session $Mgmt_Interface_Count "${Mgmt_Interface_eth_Names[@]}" $Data_Interface_Count "${Data_Interface_eth_Names[@]}" $Maestro_Group_GW_Quantity $Maestro_Group_System_Name $Maestro_Group_System_CIDR_IP_Mask $Maestro_Group_System_Def_GW $Maestro_Group_MHO_IP
apply_config $session $Maestro_Group_MHO_IP
reboot_timer 840 "FTW to run and appliance(s) to reboot"
session=$(login_device $Maestro_Group_MHO_user $Maestro_Group_MHO_pass $Maestro_Group_MHO_IP)
sg_active $session $sg_ip $Maestro_Group_MHO_IP
api_logout $session $Maestro_Group_MHO_IP
