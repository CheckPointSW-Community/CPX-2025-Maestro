!/bin/bash
source ./CPX_script_vars.txt

clear
echo "This script will run the First Time Wizard on the Manager setting it as a Primary Mgmt"
read -p "Press Enter to continue or 'C' to cancel: " userInput

# Check if the input is 'C' or 'c'
if [[ "$userInput" == "C" || "$userInput" == "c" ]]; then
    echo "Script cancelled."
    exit 1
fi
#Run the Mgmt FTW
session=$(mgmt_cli login user "$ftw_Mgmt_user" password "$ftw_Mgmt_pass" --context gaia_api --format json --unsafe-auto-accept true --version 1.8 | jq -r '.sid')
mgmt_cli set password-policy password-history.check-history-enabled "false" --context gaia_api --format json --version 1.8 --session-id "$session"
mgmt_cli set ntp enabled True preferred $ftw_ntp1 servers.1.address $ftw_ntp1 servers.1.type "pool" servers.1.version 4 servers.2.address $ftw_ntp2 servers.2.type "pool" servers.2.version 4 --context gaia_api --format json --version 1.8 --session-id $session
mgmt_cli set time-and-date timezone "$ftw_tzone" --context gaia_api --format json --version 1.8 --session-id $session
mgmt_cli set dns primary $ftw_dns1 secondary $ftw_dns2 tertiary $ftw_dns3 suffix $ftw_domain --context gaia_api --format json --version 1.8 --session-id $session

ftw_task_id=$(mgmt_cli set initial-setup password "$ftw_Mgmt_pass" security-management.type "$ftw_Mgmt_type" grub-password "$ftw_Mgmt_grub" --context gaia_api --version 1.8 --format json --sync false --session-id "$session" | jq -r '.["task-id"]')

# Function to check task status
check_task_status() {
  local status=$(mgmt_cli show task task-id "$ftw_task_id" --context gaia_api --version 1.8 --format json --session-id "$session" | jq -r '.tasks[0].status')
  echo "$status"
}
sleep 5
# Loop to check the task status until it is not in progress
while true; do
  loop_status=$(check_task_status)
  if [[ "$loop_status" == "succeeded" ]]; then
    echo "Task succeeded! You will need to wait a few minutes and then login to the management server."
    while [ $ftw_Mgmt_settle_timer -gt 0 ]; do
      # Display the time remaining
      echo -ne "Time remaining in seconds: $ftw_Mgmt_settle_timer\033[0K\r"
      # Sleep for 10 seconds
      sleep 10
      # Decrease the countdown by 10
      ((ftw_Mgmt_settle_timer-=10))
    done
    break
  elif [[ "$loop_status" == "failed" ]]; then
    echo "Task failed!"
    break
  elif [[ "$loop_status" == "in progress" ]]; then
    echo -n "First time wizard still running. Checking again in 45 seconds"
    for ((i=0; i<45; i++)); do
      echo -n "."
      sleep 1
    done
    echo ""
  else
    echo "Unknown status: $loop_status"
    break
  fi
done
# Re-enable password policy and logout
mgmt_cli set password-policy password-history.check-history-enabled "true" --context gaia_api --format json --version 1.8 --session-id "$session"
mgmt_cli logout --context gaia_api --session-id "$session"
