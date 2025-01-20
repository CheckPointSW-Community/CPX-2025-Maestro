#!/bin/bash
source ./Combined_vars.txt

# Function to login and get session ID
login() {
    read -p "Press Enter to continue or 'C' to cancel: " userInput
    if [[ "$userInput" == "C" || "$userInput" == "c" ]]; then
        echo "Script cancelled."
        exit 1
    fi
    local session=$(mgmt_cli login user $Maestro_Group_user password $Maestro_Group_pass -m $Maestro_Group_SMO_IP --context gaia_api --format json --unsafe-auto-accept true | jq -r '.sid')
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
    mgmt_cli logout -m $Maestro_Group_SMO_IP --context gaia_api --session-id $1
}

# Function to setup bonds and add vlans
setup_bonds_and_vlans() {
    local session=$1
    mgmt_cli add bond-interface id $Maestro_Group_bondID mode "$Maestro_Group_bond_mode" members.1 "$Maestro_Group_slave_1" members.2 "$Maestro_Group_slave_2" xmit-hash-policy "$Maestro_Group_bond_xmithash" -m $Maestro_Group_SMO_IP --context gaia_api --version 1.8 --format json --session-id $1
    for (( loopcounter=0; loopcounter<$Maestro_Group_vlans_to_create; loopcounter++ )); do
        mgmt_cli_vlan_id=${Maestro_Group_vlans[$loopcounter]}
        mgmt_cli add vlan-interface id $mgmt_cli_vlan_id parent bond$Maestro_Group_bondID -m $Maestro_Group_SMO_IP --context gaia_api --version 1.8 --format json --session-id $1
        mgmt_cli set virtual-gateway id 0 interfaces.remove.1 bond$Maestro_Group_bondID.$mgmt_cli_vlan_id -m $Maestro_Group_SMO_IP --context gaia_api --version 1.8 --format json --session-id $1
        vs=$(( $vs + 1 ))
    done
}

# Function to setup vSwitches
setup_vswitches() {
    local session=$1
    if [ ${#Maestro_Group_vswitchid[@]} -eq 0 ]; then
        echo "Error: Maestro_Group_vswitchid array is empty."
        exit 1
    fi
    for (( loopcounter=0; loopcounter<${#Maestro_Group_vswitchid[@]}; loopcounter++ )); do
        mgmt_cli_vsw_id=${Maestro_Group_vswitchid[$loopcounter]}
        mgmt_cli_vlan_id=${Maestro_Group_vlans[$loopcounter]}
        mgmt_cli_name="Vsw_Bond"$Maestro_Group_bondID"_Vlan"$mgmt_cli_vlan_id
        mgmt_cli_bond_parent="bond"$Maestro_Group_bondID"."$mgmt_cli_vlan_id
        mgmt_cli add virtual-switch id "$mgmt_cli_vsw_id" name "$mgmt_cli_name" interfaces.1 "$mgmt_cli_bond_parent" -m $Maestro_Group_SMO_IP --context gaia_api --version 1.8 --format json --session-id $1
        vs=$(( $vs + 1 ))
    done
}

# Function to create VS
create_vs() {
  last_task_id=""
  local session=$1
  for vs in $(seq $Maestro_Group_start_vs_id $Maestro_Group_end_vs_id); do
    vs_exists=$(mgmt_cli show virtual-gateway id $vs -m $Maestro_Group_SMO_IP --context gaia_api --version 1.8 --format json --session-id $1 2>&1)
    first=${Maestro_Group_mgmt_ips[Maestro_Group_ipcounter]}
    interface1="VS_${vs}_${first}"
    id_index=$((Maestro_Group_vscounter % ${#Maestro_Group_vswitchid[@]}))
    interface2="${Maestro_Group_vswitchid[id_index]}"
    ((Maestro_Group_vscounter++))
    id_index=$((Maestro_Group_vscounter % ${#Maestro_Group_vswitchid[@]}))
    interface3="${Maestro_Group_vswitchid[id_index]}"
    ((Maestro_Group_vscounter++))
    if [[ $vs_exists == *"does not exist"* ]]; then
      log_message "Virtual Gateway $vs does not exist. Creating..."
      # Version WITH setting mgmt IP during API call
      create_task_id=$(mgmt_cli add virtual-gateway id $vs one-time-password "$Maestro_Group_new_vs_OTP" resources.firewall-ipv4-instances $Maestro_Group_vs_core_count resources.firewall-ipv6-instances 0 resources.virtual-switches.1.id $Maestro_Group_mgmt_vsw_id resources.virtual-switches.2.id $interface2 resources.virtual-switches.3.id $interface3 mgmt-connection.mgmt-connection-identifier "$Maestro_Group_mgmt_vsw_id" mgmt-connection.mgmt-connection-type "virtual-switch-id" mgmt-connection.mgmt-ipv4-configuration.ipv4-address $Maestro_Group_vs_subnet.$vs mgmt-connection.mgmt-ipv4-configuration.ipv4-mask $Maestro_Group_vs_mask_length mgmt-connection.mgmt-ipv4-configuration.ipv4-default-gateway "$Maestro_Group_vs_def_gw" -m $Maestro_Group_SMO_IP --context gaia_api --version 1.8 --format json --sync false --session-id $1 2>&1 | jq -r '.["task-id"]')
      log_message "Working on vs $vs.  Task remotely executed on Gateway and takes 1 to 3 minutes per VS"
    else
      log_message "Virtual Gateway $vs exists. Skipping creation..."
    fi
    ((ipcounter++))
  done
}
# Function to check VS creation status
check_vs_creation_status() {
# Function to print dots while waiting and check for cancellation
local session=$1
full_output=$(mgmt_cli show virtual-systems limit 1 offset 0 order "ASC" -m $Maestro_Group_SMO_IP --context gaia_api --version 1.8 --format json --session-id $1 2>&1 | jq -r ".total")
clear
echo "Total VS Count (including VS0, vSwitch(s) and other) : $full_output"

# Calculate expected and created virtual systems
#Expected VS is vs0 (1) plus the difference between the end and start counter (which is +1 on what you expect)
ExpectedVSs=$(expr $Maestro_Group_end_vs_id - $Maestro_Group_start_vs_id + 1)
CreatedVS=$(expr $full_output - $Maestro_Group_vlans_to_create)
echo "System has created $CreatedVS of the requested $ExpectedVSs Virtual Systems"

# Check if created VS matches expected VS
while [[ $CreatedVS -ne $ExpectedVSs ]]; do
  echo "Waiting for virtual systems to be created... (Press C to cancel)"
    for ((i=0; i<12; i++)); do
    echo -n "."
    sleep 5
    # Check if 'C' was pressed
    if read -t 0.1 -n 1 key && [[ $key = "C" ]]; then
      echo -e "\nScript cancelled by user."
      mgmt_cli logout -m $Maestro_Group_SMO_IP --context gaia_api --session-id $1 2>&1
      exit 1
    fi
  done
  echo ""

  # Re-check the virtual systems count
  full_output=$(mgmt_cli show virtual-systems offset 0 order "ASC" limit 1  -m $Maestro_Group_SMO_IP --context gaia_api --version 1.8 --format json --session-id $1 2>&1 | jq -r ".total")
  clear
  echo "VS Count is: $full_output"
  CreatedVS=$(expr $full_output - $Maestro_Group_vlans_to_create - 2)
  echo "System has created $CreatedVS of the requested $ExpectedVSs Virtual Systems"
done

echo "All expected virtual systems have been created."
}

# Function to setup interfaces
setup_interfaces() {
    local session=$1
    for id in $(seq $Maestro_Group_start_vs_id $Maestro_Group_end_vs_id); do
        echo -ne "\nWorking on vs $id"
        echo -n "."
        vs_ints=$(mgmt_cli show interfaces virtual-system-id $id -m $Maestro_Group_SMO_IP --context gaia_api --format json --session-id $1 | jq .)
        ints=$(echo "$vs_ints" | jq -r '.objects[].name')
        IFS=$'\n' read -r -d '' -a new_warp_int_array <<< "$ints"$'\n'
        for i in "${new_warp_int_array[@]}"; do
            if [[ "${Maestro_Group_ips[$Maestro_Group_int_loop_count]}" =~ $Maestro_Group_first_octet ]]; then
                mask=22
            else
                mask=16
            fi
            mgmt_cli set physical-interface name $i ipv4-address ${Maestro_Group_ips[$Maestro_Group_int_loop_count]} ipv4-mask-length $mask virtual-system-id $id -m $Maestro_Group_SMO_IP --context gaia_api --version 1.8 --session-id $1
            Maestro_Group_int_loop_count=$(( $Maestro_Group_int_loop_count + 1 ))
            echo -n "."
        done
    done
}


# Main script execution

clear
echo "This script will setup the bonds, VLANs, vSwitches, and VS on the on the group"
echo "Before running this script, ensure the gateway is in VSNext + EXL mode, and SIC is established to VS0 from this Mgmt Server"
session=$(login)
echo "Bond and vswitch setup"
setup_bonds_and_vlans $session
echo "VSwitch setup"
setup_vswitches $session
echo "VS creation"
create_vs $session
echo "Monitoring VS Creation task"
check_vs_creation_status $session
echo "Setting up interfaces"
setup_interfaces $session
api_logout $session
