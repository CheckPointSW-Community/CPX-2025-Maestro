#In this script, and others in the group, positional parameters are used, so if you call a function, and pass 3 parameters, you can access them within the function based on their position.
#However, where there are lots of parameters passed, then someimes, they are converted to local variables, of the same name. 
#!/bin/bash
source ./Combined_vars.txt


# Function to login to MHO and get session ID
login_mho() {
    read -p "Press Enter to continue or 'C' to cancel: " userInput
    if [[ "$userInput" =~ ^[Cc]$ ]]; then
        echo "Script cancelled."
        exit 1
    fi

    session=$(mgmt_cli login user "$mho_user" password "$mho_pass" -m "$2" --context gaia_api --format json --unsafe-auto-accept true | jq -r '.sid')
    if [[ -z "$session" ]]; then
        echo "Failed to get session ID. Quitting..."
        exit 1
    fi
    echo "$session"
}

# Function for log output
log_message() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1"
}

# Function to logout
api_logout() {
    echo "Logging out of the system"
    mgmt_cli logout -m "$2" --context gaia_api --session-id "$1" > /dev/null 2>&1
}

# Function to discard any outstanding changes before trying to work on the group
maestro_discard_outstanding_changes() {
    echo "Discarding outstanding changes before making any new changes"
    mgmt_cli discard-maestro-security-groups-changes -m "$2" --context gaia_api --session-id "$1" > /dev/null 2>&1
}

# Function to delete a Security Group in Maestro
maestro_delete_group() {
    echo "Deleting security group number $2 from MHO $3"
    mgmt_cli delete maestro-security-group id "$2" -m "$3" --context gaia_api --version 1.8 --format json --session-id "$1" > /dev/null 2>&1
}

# Function to apply configuration
apply_config() {
    echo "Applying changes to the MHO: $2"
    mgmt_cli apply-maestro-security-groups-changes -m "$2" --context gaia_api --session-id "$1" > /dev/null 2>&1
}

# Main script execution
if [[ $# -ne 2 ]]; then
    echo "Usage to DELETE group: $0 <Group_ID_to_delete> <mho_IP_to_connect_to>"
    echo "Example: $0 3 '192.168.5.23' will delete group 3 via orchestrator 192.168.5.23"
    exit 1
fi

group_ID=$1
mho_ip=$2

clear

log_message "Starting the script to delete a Security Group using APIs."
echo "I've read you want to delete group ID ${bold}$group_ID${normal} on the MHO ${bold}$mho_ip${normal}"
echo "***************************************"

# API activity below here
session=$(login_mho "$group_ID" "$mho_ip")
maestro_discard_outstanding_changes "$session" "$mho_ip"
maestro_delete_group "$session" "$group_ID" "$mho_ip"
apply_config "$session" "$mho_ip"
api_logout "$session" "$mho_ip"
