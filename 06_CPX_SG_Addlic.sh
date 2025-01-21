#!/bin/bash
source ./Combined_vars.txt

# Function to login and get session ID
login() {
    read -p "Press Enter to continue or 'C' to cancel: " userInput
    if [[ "$userInput" == "C" || "$userInput" == "c" ]]; then
        echo "Script cancelled."
        exit 1
    fi
    local session=$(mgmt_cli login user $Maestro_Group_user password $Maestro_Group_pass -m $1  --context gaia_api --format json --unsafe-auto-accept true | jq -r '.sid')
    if [[ -z "$1" ]]; then
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
    mgmt_cli logout -m $2 --context gaia_api --session-id $1
}

# Function to setup bonds and add vlans
add_lics() {
    mgmt_cli add license license "<smo_IP> <expiry> <code> CPSG-C-8-U CPSB-FW CPSB-VPN CPSB-IPSA CPSB-DLP CPSB-SSLVPN-U CPSB-IA CPSB-ADNC CPSG-VSX-25S CPSB-SWB CPSB-IPS CPSB-AV CPSB-URLF CPSB-ASPM CPSB-APCL CPSB-ABOT CPSB-CTNT CK-<My_Cert_Key>" -m $2 --context gaia_api --session-id $1
    mgmt_cli add license license "<smo_IP> <expiry> <code> CPSG-C-8-U CPSB-FW CPSB-VPN CPSB-IPSA CPSB-DLP CPSB-SSLVPN-U CPSB-IA CPSB-ADNC CPSG-VSX-25S CPSB-SWB CPSB-IPS CPSB-AV CPSB-URLF CPSB-ASPM CPSB-APCL CPSB-ABOT CPSB-CTNT CK-<My_Cert_Key>" -m $2 --context gaia_api --session-id $1
    mgmt_cli add license license "<smo_IP> <expiry> <code> CPSG-C-8-U CPSB-FW CPSB-VPN CPSB-IPSA CPSB-DLP CPSB-SSLVPN-U CPSB-IA CPSB-ADNC CPSG-VSX-25S CPSB-SWB CPSB-IPS CPSB-AV CPSB-URLF CPSB-ASPM CPSB-APCL CPSB-ABOT CPSB-CTNT CK-<My_Cert_Key>" -m $2 --context gaia_api --session-id $1

}
# Main script execution
if [[ $# -ne 1 ]]; then
    echo "Usage: $0 <Maestro_SMO_IPAddress_for_License>"
    echo "Example: $0 '192.168.05.23'"
    exit 1
fi

Maestro_SMO_IPAddress_for_License=$1

# Main script execution

clear
echo "This script will add some licenses to the appliances in the group and will target the Group itself."
session=$(login $Maestro_SMO_IPAddress_for_License)
add_lics $session $Maestro_SMO_IPAddress_for_License
api_logout $session $Maestro_SMO_IPAddress_for_License
