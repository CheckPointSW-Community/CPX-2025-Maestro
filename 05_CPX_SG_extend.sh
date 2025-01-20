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
    echo "Logging out of the system IP $2"
    mgmt_cli logout -m $2 --context gaia_api --session-id $1
}

# Function to discard any outstanding change before trying to work on the group
maestro_discard_outstanding_changes() {
    local session=$1
    local device_ip=$2
    echo "Discarding outstanding changes before making any new changes"
    mgmt_cli discard-maestro-security-groups-changes -m $2 --context gaia_api --session-id $1 > /dev/null 2>&1
}

# Function to Show Gateways in Maestro
maestro_show_gateways() {
    local session=$1
    echo "Logging into the MHO, to find the attached gateways and then filtering for those that are unassigned therefore can be used"
    full_output=$(mgmt_cli show maestro-gateways -m $Maestro_Group_MHO_IP --version $GAIA_API_Ver --context gaia_api --format json --session-id $session | jq .)
    sh_maestro_gw=$(echo "$full_output" | jq -c '.gateways[] | select(.state == "UNASSIGNED") | {id, model, major: .version.major}')
}

# Function to UpdateSecurity Group in Maestro
maestro_update_group() {
  # $session $Maestro_Group_ID  $Maestro_Group_MHO_IP $Maestro_Group_GW_Quantity
  local session=$1
  local Maestro_Group_ID=$2
  local Maestro_Group_MHO_IP=$3
  local Maestro_Group_GW_Quantity=$4
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
  echo "Generating the command that will add additional gateways to the group via API"
  local cmd="mgmt_cli set maestro-security-group id $2 "
  for ((i=0; i<Maestro_Group_GW_Quantity; i++)); do
    cmd+=" gateways.add.$((i+1)).id ${gateways[$i]}"
  done
  cmd+="  -m $Maestro_Group_MHO_IP --context gaia_api --version $GAIA_API_Ver --format json --session-id $session"
  eval $cmd  > /dev/null 2>&1
}

# Function to apply configuration
apply_config() {
    local session=$1
    local Maestro_Group_MHO_IP=$2
    echo "Applying changes to the MHO: $2"
    # Apply configuration and capture output
    makegroup=$(mgmt_cli apply-maestro-security-groups-changes -m $Maestro_Group_MHO_IP --context gaia_api --format json --session-id $session 2>&1)
    if [ $? -ne 0 ]; then
        echo "Error applying configuration: $makegroup"
        api_logout $session $Maestro_Group_MHO_IP
        return 1
    fi
}


# Main script execution
if [[ $# -ne 3 ]]; then
    echo "Usage: $0 <number_of_gateways_to_add> <Security_Group_ID> <Maestro_Group_MHO_IP_to_connect_to>"
    echo "Example: $0 3 1 '192.168.05.23' will add 3 gateways to group 1 on the given MHO"
    exit 1
fi

Maestro_Group_GW_Quantity=$1
Maestro_Group_ID=$2
Maestro_Group_MHO_IP=$3

clear

log_message "Starting the script to extend a Security Group using APIs."
echo "About to extend Security Group ${bold}$Maestro_Group_ID${normal} on MHO: ${bold}$Maestro_Group_MHO_IP${normal} with ${bold}$Maestro_Group_GW_Quantity${normal} additional Gateways."
echo "***************************************"

session=$(login_device $Maestro_Group_MHO_user $Maestro_Group_MHO_pass $Maestro_Group_MHO_IP)
maestro_show_gateways $session
maestro_discard_outstanding_changes $session $Maestro_Group_MHO_IP
maestro_update_group $session $Maestro_Group_ID $Maestro_Group_MHO_IP $Maestro_Group_GW_Quantity
apply_config $session $Maestro_Group_MHO_IP
api_logout $session $Maestro_Group_MHO_IP