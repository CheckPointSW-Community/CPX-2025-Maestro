#!/bin/bash
source ./Combined_vars.txt

lock_database() {
  clish -c "lock database override"
}

login() {
  session=$(mgmt_cli -r true login --format json --unsafe-auto-accept true | jq -r '.sid')
  if [[ -z $session ]]; then
    echo "Failed to get session ID. Quitting..."
    exit 1
  fi
  echo $session
}

validate_ipv4_cidr() {
#This will split the CIDR format IP/mask sent as a parameter into two variables, Security_Group_IP_address for the IP address of the group, and Security_Group_Subnet_Mask, for the subnet mask of the gruop, so they can be used later
    local ip_cidr=$1
    if [[ $ip_cidr =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/([0-9]|[12][0-9]|3[0-2])$ ]]; then
        Security_Group_IP_address=${BASH_REMATCH[0]}
        Security_Group_Subnet_Mask=${BASH_REMATCH[2]}
        IFS='/' read -r Security_Group_IP_address Security_Group_Subnet_Mask <<< "$ip_cidr"
        IFS='.' read -r -a octets <<< "$Security_Group_IP_address"
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


add_policy_package() {
  local session=$1
  echo "Adding a policy package for the VS0 for Security Group"
  mgmt_cli add package name "$Maestro_Group_pp_name_vs0" comments "Created using API" color "blue" threat-prevention true access true --session-id $1
  mgmt_cli publish --session-id $1
}

add_gateway() {
  # Passed vars are: $session $Security_Group_Name_in_Mgmt $Security_Group_IP_address $Security_Group_SIC_Key
  local session=$1
  local Security_Group_Name_in_Mgmt=$2
  local Security_Group_IP_address=$3
  local Security_Group_SIC_Key=$4
  echo "Add Security Group into policy for VS0"
  mgmt_cli add simple-gateway name "$2" ipv4-address "$3" one-time-password "$4" --session-id $1
  mgmt_cli set simple-gateway name "$2" hardware "ElasticXL Appliances" firewall-settings.auto-maximum-limit-for-concurrent-connections false --session-id $1
}

pull_topology() {
  # Passed vars are: $session $Security_Group_Name_in_Mgmt
  local session=$1
  local Security_Group_Name_in_Mgmt=$2
  echo "Pull topology from Security Group VSNext Group VS0"
  mgmt_cli get-interfaces target-name "$2" with-topology true --session-id $1 --format json
}

disable_anti_spoofing() {
  # Passed vars are: $session $Security_Group_Name_in_Mgmt $Security_Group_IP_address $Security_Group_Subnet_Mask
  local session=$1
  local Security_Group_Name_in_Mgmt=$2
  local Security_Group_IP_address=$3
  local Security_Group_Subnet_Mask=$4
  echo "Disabling anti-spoofing on Security Group VSNext Group or the policy won't install"
  mgmt_cli set simple-gateway name "$2" interfaces.1.name "$Maestro_Group_mgmt_wrp_name" interfaces.1.ip-address "$Security_Group_IP_address" interfaces.1.ipv4-mask-length "$Security_Group_Subnet_Mask" interfaces.1.anti-spoofing "false" interfaces.1.topology "EXTERNAL" --format json --session-id $1
}

setup_policy_target() {
  # Passed vars are: $session $Security_Group_Name_in_Mgmt
  local session=$1
  local Security_Group_Name_in_Mgmt=$2
  echo "Adding the Security Group VSNext Group to the policy package target list"
  mgmt_cli set package name "$Maestro_Group_pp_name_vs0" installation-targets.add "$2" --session-id $1
  mgmt_cli publish --session-id $1
}

setup_policy_rules() {
  # Passed vars are: $session $Security_Group_Name_in_Mgmt
  local session=$1
  local Security_Group_Name_in_Mgmt=$2
  echo "Setup policy and rules for VS0"
  mgmt_cli set access-layer name "$Maestro_Group_pp_name_network_vs0" applications-and-url-filtering true --session-id $1
  mgmt_cli add access-rule layer "$Maestro_Group_pp_name_network_vs0" position top name "Any_to_$2" source "Any" destination "$2" service "https" action "Accept" track "Log" --session-id $1
  mgmt_cli add access-rule layer "$Maestro_Group_pp_name_network_vs0" position top name "Any_to_$2" source "Any" destination "$2" service "ssh_version_2" action "Accept" track "Log" --session-id $1
  mgmt_cli set access-rule layer "$Maestro_Group_pp_name_network_vs0" rule-number 3 track "Log" --session-id $1

  for pos in {1..3}; do
    mgmt_cli set access-rule layer "$Maestro_Group_pp_name_network_vs0" rule-number $pos install-on "$2" --session-id $1
  done
  mgmt_cli publish --session-id $1
}

install_policy() {
  # Passed vars are: $session $Security_Group_Name_in_Mgmt
  local session=$1
  local Security_Group_Name_in_Mgmt=$2
  echo "Install policy on VS0 on the Security Group"
  mgmt_cli install-policy policy-package "$Maestro_Group_pp_name_vs0" access true threat-prevention false targets.1 "$2" ignore-warnings "true" --session-id $1
  mgmt_cli publish --session-id $1
}

api_logout() {
  local session=$1
  mgmt_cli logout --session-id $1
}

# Main script execution
if [[ $# -ne 3 ]]; then
    echo "Usage: $0 <Security_Group_Name_in_Mgmt> <security_group_ip/mask> <sic_password>"
    echo "Example: $0 MySecurityGroup '192.168.14.10/24' abc123"
    exit 1
fi

Security_Group_Name_in_Mgmt=$1
system_ip_mask=$2
Security_Group_SIC_Key=$3

lock_database
session=$(login)
validate_ipv4_cidr "$system_ip_mask"
add_policy_package $session
add_gateway $session $Security_Group_Name_in_Mgmt $Security_Group_IP_address $Security_Group_SIC_Key
pull_topology $session $Security_Group_Name_in_Mgmt
disable_anti_spoofing $session $Security_Group_Name_in_Mgmt $Security_Group_IP_address $Security_Group_Subnet_Mask
setup_policy_target $session $Security_Group_Name_in_Mgmt
setup_policy_rules $session $Security_Group_Name_in_Mgmt
install_policy $session $Security_Group_Name_in_Mgmt
api_logout $session
