#!/bin/bash
source ./Combined_vars.txt

# Function to login and get session ID
gw_api_login() {
    local session=$(mgmt_cli login user $Maestro_Group_user password $Maestro_Group_pass -m $Maestro_Group_IP --context gaia_api --format json --unsafe-auto-accept true | jq -r '.sid')
    if [[ -z "$session" ]]; then
        echo "Failed to get session ID. Quitting..."
        exit 1
    fi
    echo $session
}

# Function to login to Mgmt and get session ID
mgmt_api_login() {
  session=$(mgmt_cli -r true login --format json --unsafe-auto-accept true | jq -r '.sid')
  if [[ -z $session ]]; then
    echo "Failed to get session ID. Quitting..."
    exit 1
  fi
  echo $session
}

# Function to logout
gw_api_logout() {
    local session=$1
    mgmt_cli logout -m $Maestro_Group_IP --context gaia_api --session-id $1
}

# Function to logout
mgmt_api_logout() {
    local session=$1
    mgmt_cli logout --session-id $1
}

# Function to setup Skyline
setup_skyline() {
    local session=$1
    mgmt_cli set open-telemetry enabled True export-targets.add.1.name "vsnext" export-targets.add.1.client-auth.basic.username "$skyline_user" \
             export-targets.add.1.client-auth.basic.password "$skyline_pass"  export-targets.add.1.enabled True \
             export-targets.add.1.server-auth.ca-public-key.type "PEM-X509" export-targets.add.1.server-auth.ca-public-key.value "$skyline_cert" \
             export-targets.add.1.type "prometheus-remote-write" export-targets.add.1.url "$skyline_url" \
             -m $Maestro_Group_IP --context gaia_api --version $GAIA_API_Ver --format json --session-id $1 > /dev/null 2>&1
}

# Function to setup VS
setup_vs() {
    clish -c "lock database override"
    local session=$1
    mgmt_cli add package name $Maestro_Group_pp_name comments "Created using API" color "green" threat-prevention true access true --session-id $1 > /dev/null 2>&1
    mgmt_cli publish --session-id $1
    for id in $(seq $Maestro_Group_start_vs_id $Maestro_Group_end_vs_id); do
        echo -en "\nAdding VS $id into the Management"
        gw_ip_in_mgmt=${Maestro_Group_mgmt_ips[Maestro_Group_mgmt_ipcounter]}
        gw_name_in_mgmt="$Maestro_Group_VS_naming"$id
        mgmt_cli add simple-gateway name "$gw_name_in_mgmt" ipv4-address "$gw_ip_i_mgmt" one-time-password "$Maestro_Group_new_vs_OTP" --session-id $1 > /dev/null 2>&1
        mgmt_cli set simple-gateway name "$gw_name_in_mgmt" hardware "ElasticXL Appliances" firewall-settings.auto-maximum-limit-for-concurrent-connections false --session-id $1 > /dev/null 2>&1
        mgmt_cli publish --session-id $1 > /dev/null 2>&1
        ((Maestro_Group_mgmt_ipcounter++))
    done
}

# Function to configure interfaces and packages
configure_interfaces_and_packages() {
    local session=$1
    for id in $(seq $Maestro_Group_start_vs_id $Maestro_Group_end_vs_id); do
        gw_name_in_mgmt="$Maestro_Group_VS_naming"$id
        echo -en "\nUpdating topology and setting 25k concurrent conns. limit for VS $id"
        mgmt_cli get-interfaces target-name "$gw_name_in_mgmt" with-topology true --session-id $1 > /dev/null 2>&1
        mgmt_cli set package name "$Maestro_Group_pp_name" installation-targets.add "$gw_name_in_mgmt" --session-id $1 > /dev/null 2>&1
        mgmt_cli publish --session-id $1 > /dev/null 2>&1
    done
}

# Function to add networks
add_networks() {
    local session=$1
    for net in "${Common_networks[@]}"; do
        IFS=':' read -r name subnet mask color <<< "$net"
        # Check if the network already exists
        network_check=$(mgmt_cli show network name "$name" --format json --session-id "$session")
        network_exists=$(echo "$network_check" | jq -r '.code')
        if [ "$network_exists" == "generic_err_object_not_found" ]; then
            mgmt_cli add network name "$name" subnet "$subnet" subnet-mask "$mask" color "$color" --session-id "$session" > /dev/null 2>&1
        else
            echo -en"\nNetwork $name already exists, skipping creation."
        fi
    done
    mgmt_cli publish --session-id $1 > /dev/null 2>&1
}
# Function to set access rules
set_access_rules() {
    local session=$1
    echo "Adding rules to rule base"
    mgmt_cli set access-layer name "$Maestro_Group_pp_name_network" applications-and-url-filtering true --session-id $1
    max_rule_pos=$((Maestro_Group_end_vs_id - Maestro_Group_start_vs_id + 1))
    drop_rule_pos=$((Maestro_Group_end_vs_id - Maestro_Group_start_vs_id + 2))

    for ((rule_pos=1; rule_pos<=max_rule_pos; rule_pos++)); do
        vs_no=$((Maestro_Group_last_octet + rule_pos -1))
        index=$(( (rule_pos-1) % 4 ))
        source=${Common_Group_src_nets[$index]}
        destination=${Common_Group_dst_nets[$index]}
        echo -ne "\nWorking on rule $rule_pos"
        mgmt_cli add access-rule layer "$Maestro_Group_pp_name_network" position $rule_pos name "VS${vs_no} Inside to Outside" source "$source" destination "$destination" service "Any" action "Accept" track "Log" --session-id $1 > /dev/null 2>&1
    done
    mgmt_cli publish --session-id $1 > /dev/null 2>&1
}

# Function to set rule targets
set_rule_targets() {
    local session=$1
    for target_gw in $(seq $Maestro_Group_start_vs_id $Maestro_Group_end_vs_id); do
        gw_name_in_mgmt=$Maestro_Group_VS_naming$target_gw
        pos=$((target_gw - Maestro_Group_last_octet + 1))
        echo -ne "\nSetting $gw_name_in_mgmt as the target of rule $pos"
        mgmt_cli set access-rule layer "$Maestro_Group_pp_name_network" rule-number $pos install-on $gw_name_in_mgmt --session-id $1 > /dev/null 2>&1
    done
    mgmt_cli publish --session-id $1 > /dev/null 2>&1
}
parallel_install_policies() {
local session=$1
for pol_inst in $(seq $Maestro_Group_start_vs_id $Maestro_Group_end_vs_id); do
  gw_name_in_mgmt="$Maestro_Group_VS_naming"$pol_inst
  Maestro_Group_Target_List+=("targets.$Maestro_Group_Target_Index \"$gw_name_in_mgmt\"")
  ((Maestro_Group_Target_Index++))
  if ((Maestro_Group_Target_Index > Maestro_Group_Max_Concurrent_Install_Targets)); then
    # Install policy for the current batch of targets, for low core systems, Maestro_Group_Max_Concurrent_Install_Targets could be 2, with more cores, 10 has been tested. Depends on customer.
    echo -ne "\nInstalling Policy Package "$Maestro_Group_pp_name onto $(IFS=' ' ; echo "${Maestro_Group_Target_List[*]}")
    mgmt_cli install-policy policy-package "$Maestro_Group_pp_name" access true threat-prevention false $(IFS=' ' ; echo "${Maestro_Group_Target_List[*]}") ignore-warnings "true" --session-id $1 > /dev/null 2>&1
    #NOTE: TP Installation not set, to speed up install for this lab.
    mgmt_cli publish --session-id $1 > /dev/null 2>&1
    # Reset for the next batch
    Maestro_Group_Target_Index=1
    Maestro_Group_Target_List=()
  fi
done

# Install policy for any remaining targets
if (( ${#Maestro_Group_Target_List[@]} > 0 )); then
  mgmt_cli install-policy policy-package "$Maestro_Group_pp_name" access true threat-prevention false $(IFS=' ' ; echo "${Maestro_Group_Target_List[*]}") ignore-warnings "true" --session-id $1 > /dev/null 2>&1
  echo "Installing Policy Package "$Maestro_Group_pp_name onto $(IFS=' ' ; echo "${Maestro_Group_Target_List[*]}")
  mgmt_cli publish --session-id $1 > /dev/null 2>&1
fi
}

reinstall_vs0_policy() {
    local session=$1
    echo -ne "\nInstall policy on VS0"
    echo -ne "\nReading the package name from the config file and determining the VS0 policy target name"

    # Capture the package info
    Maestro_Group_VS0_package_info=$(mgmt_cli show package name "$Maestro_Group_pp_name_vs0" --format json --session-id "$session")
    # Extract the installation-targets name using jq
    Maestro_Group_vs0_target_name=$(echo "$Maestro_Group_VS0_package_info" | jq -r '.["installation-targets"][] | .name')
    # Install the policy
    mgmt_cli install-policy policy-package "$Maestro_Group_pp_name_vs0" access true threat-prevention false targets.1 "$Maestro_Group_vs0_target_name" ignore-warnings "true" --session-id $1 > /dev/null 2>&1
    # Publish the changes
    echo -ne "\n"
    mgmt_cli publish --session-id $1 > /dev/null 2>&1
}

# Main script execution
echo "Management Tasks about to begin. Confirm that SIC is established with VS0, all the tasks in the VSNext GW are completed before you continue"
echo "Check under VSNext Gateway -> Virtual Systems Tab -> Tasks window"

#Disabled while checking Autoupdated 129 installation
#echo "Setup Skyline"
#session=$(gw_api_login)
#setup_skyline $session
#gw_api_logout $session

echo "Setup Mgmt, policy and targets"
session=$(mgmt_api_login)
setup_vs $session
configure_interfaces_and_packages $session
add_networks $session
set_access_rules $session
set_rule_targets $session
parallel_install_policies $session
reinstall_vs0_policy $session
mgmt_api_logout $session