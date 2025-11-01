#!/bin/bash
source ./Combined_vars.txt

# Configuration
DEBUG_MODE=${DEBUG_MODE:-0}  # Set to 1 for verbose output
USE_NEW_SYNTAX=0
ftw_ssh_timeout=${ftw_ssh_timeout:-10}

# Logging functions
log_message() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1"
}

log_debug() {
    [[ $DEBUG_MODE -eq 1 ]] && echo "DEBUG: $1" >&2
}

# Check appliance SSH connectivity
check_ssh_status() {
    log_message "Checking SSH connectivity to $EXL_Group_IP..."
    if sshpass -p "$EXL_Group_pass" ssh -o "UserKnownHostsFile=/dev/null" -o StrictHostKeyChecking=no -o ConnectTimeout=$ftw_ssh_timeout "$EXL_Group_user@$EXL_Group_IP" "show uptime" &>/dev/null; then
        log_message "Appliance is reachable via SSH"
        return 0
    else
        log_message "SSH connectivity failed"
        return 1
    fi
}

# Check appliance HTTPS/API connectivity
check_api_status() {
    log_message "Checking HTTPS connectivity to $EXL_Group_IP:443..."

    # Check if curl_cli is available
    if ! command -v curl_cli &>/dev/null; then
        log_message "Warning: curl_cli not found, skipping HTTPS check"
        return 1
    fi

    # Try to fetch the root page to verify HTTPS connectivity
    local response=$(curl_cli -k -s -m $ftw_ssh_timeout --connect-timeout $ftw_ssh_timeout \
        "https://$EXL_Group_IP/" 2>&1)

    if [[ $? -eq 0 ]] && [[ "$response" == *"GAiA"* || "$response" == *"login"* || "$response" == *"WEBUI"* ]]; then
        log_message "Appliance is reachable via HTTPS"
        return 0
    else
        log_message "HTTPS connectivity failed"
        return 1
    fi
}

# Check appliance connectivity (HTTPS first, SSH fallback)
check_appliance_status() {
    log_message "Verifying appliance connectivity..."

    # Try HTTPS first (primary method)
    if check_api_status; then
        return 0
    fi

    # HTTPS failed, try SSH as fallback
    log_message "HTTPS failed, attempting SSH check..."
    if check_ssh_status; then
        log_message "Warning: HTTPS unavailable but SSH is reachable"
        return 0
    fi

    # Both failed
    log_message "ERROR: Appliance unreachable via both HTTPS and SSH"
    log_message "Possible issues:"
    log_message "  - Appliance is down or rebooting"
    log_message "  - Network connectivity issue"
    log_message "  - Invalid credentials"
    log_message "  - Firewall blocking ports 443 and 22"
    read -p "Press Enter to exit..." dummy
    return 1
}

# Login and get session ID
login() {
    local response=$(mgmt_cli login user "$EXL_Group_user" password "$EXL_Group_pass" -m "$EXL_Group_IP" --context gaia_api --format json --unsafe-auto-accept true 2>&1)
    log_debug "Login response: $response"

    local session=$(echo "$response" | jq -r '.sid // empty' 2>/dev/null)
    if [[ -z "$session" || "$session" == "null" ]]; then
        log_message "ERROR: Failed to get session ID"
        log_message "Response: $response"
        read -p "Press Enter to exit..." dummy
        exit 1
    fi
    echo "$session"
}

# Logout
api_logout() {
    [[ -n "$1" ]] && mgmt_cli logout -m "$EXL_Group_IP" --context gaia_api --session-id "$1" &>/dev/null
}

# Check JHF version and determine syntax
check_jhf_version() {
    local session=$1
    log_message "Detecting JHF version..."

    # Run cpinfo - capture both stdout and stderr
    local run_response=$(mgmt_cli run-script script "cpinfo -y all" -m "$EXL_Group_IP" --context gaia_api --version 1.8 --format json --session-id "$session" 2>&1)

    # Check for API error responses
    if [[ "$run_response" == *"generic_error"* ]] || [[ "$run_response" == *"Management API service is not available"* ]]; then
        log_message "Warning: API returned error, using OLD syntax"
        log_debug "API error: $run_response"
        USE_NEW_SYNTAX=0
        return
    fi

    if [[ -z "$run_response" ]]; then
        log_message "Warning: Empty response from cpinfo, using OLD syntax"
        USE_NEW_SYNTAX=0
        return
    fi

    log_debug "cpinfo response: $run_response"

    # Extract JSON part (strip banner/header lines before first {)
    local json_response=$(echo "$run_response" | sed -n '/{/,$ p')
    log_debug "JSON extracted (first 300 chars): ${json_response:0:300}"

    # Extract task-id from JSON
    local task_id=$(echo "$json_response" | jq -r '.tasks[0]."task-id" // empty' 2>/dev/null)

    # Try alternative extraction if first attempt fails
    if [[ -z "$task_id" || "$task_id" == "null" || "$task_id" == "empty" ]]; then
        task_id=$(echo "$json_response" | jq -r '.tasks[]."task-id"' 2>/dev/null | head -1)
    fi

    if [[ -z "$task_id" || "$task_id" == "null" || "$task_id" == "empty" ]]; then
        log_message "Warning: Could not extract task-id, using OLD syntax"
        log_debug "First 500 chars: ${json_response:0:500}"
        USE_NEW_SYNTAX=0
        return
    fi

    log_debug "cpinfo task-id: $task_id"

    # Poll until complete
    local status="in progress"
    local attempt=0
    while [[ "$status" != "succeeded" && "$status" != "failed" && $attempt -lt 30 ]]; do
        sleep 2
        local task_response=$(mgmt_cli show task task-id "$task_id" -m "$EXL_Group_IP" --context gaia_api --version 1.8 --format json --session-id "$session" 2>&1)

        # Extract JSON from task response too
        local task_json=$(echo "$task_response" | sed -n '/{/,$ p')
        status=$(echo "$task_json" | jq -r '.tasks[0].status // empty' 2>/dev/null)
        [[ -z "$status" ]] && status="in progress"
        ((attempt++))
    done

    if [[ "$status" != "succeeded" ]]; then
        log_message "Warning: cpinfo task status: $status, using OLD syntax"
        USE_NEW_SYNTAX=0
        return
    fi

    # Extract and decode output
    local output=$(echo "$task_json" | jq -r '.tasks[0]."task-details"[0].output // empty' 2>/dev/null)
    if [[ -z "$output" || "$output" == "null" || "$output" == "empty" ]]; then
        log_message "Warning: No cpinfo output, using OLD syntax"
        USE_NEW_SYNTAX=0
        return
    fi

    # Try base64 decode, fallback to plain text
    local decoded_output=$(echo "$output" | base64 -d 2>/dev/null || echo "$output")
    log_debug "cpinfo output (first 500 chars): ${decoded_output:0:500}"

    # Parse for JHF Take number
    local take_number=$(echo "$decoded_output" | grep "BUNDLE_R82_JUMBO_HF_MAIN" | grep -oP 'Take:\s+\K\d+' | head -1)
    if [[ -z "$take_number" ]]; then
        log_message "Warning: Could not find JHF version, using OLD syntax"
        USE_NEW_SYNTAX=0
        return
    fi

    log_message "JHF Take: $take_number"
    if [[ $take_number -ge 25 ]]; then
        USE_NEW_SYNTAX=1
        log_message "Using NEW API syntax (JHF >= 25)"
    else
        USE_NEW_SYNTAX=0
        log_message "Using OLD API syntax (JHF < 25)"
    fi
}

# Setup bonds and VLANs
setup_bonds_and_vlans() {
    local session=$1
    log_message "Creating bond interface $EXL_Group_bondID..."

    local response=$(mgmt_cli add bond-interface id "$EXL_Group_bondID" mode "$EXL_Group_bond_mode" \
        members.1 "$EXL_Group_slave_1" members.2 "$EXL_Group_slave_2" \
        xmit-hash-policy "$EXL_Group_bond_xmithash" \
        -m "$EXL_Group_IP" --context gaia_api --version 1.8 --format json --session-id "$session" 2>&1)
    log_debug "Bond creation response: $response"

    log_message "Creating VLANs..."
    for (( i=0; i<$EXL_Group_vlans_to_create; i++ )); do
        local vlan_id=${EXL_Group_vlans[$i]}

        response=$(mgmt_cli add vlan-interface id "$vlan_id" parent "bond$EXL_Group_bondID" \
            -m "$EXL_Group_IP" --context gaia_api --version 1.8 --format json --session-id "$session" 2>&1)
        log_debug "VLAN $vlan_id creation: $response"

        response=$(mgmt_cli set virtual-gateway id 0 interfaces.remove.1 "bond$EXL_Group_bondID.$vlan_id" \
            -m "$EXL_Group_IP" --context gaia_api --version 1.8 --format json --session-id "$session" 2>&1)
        log_debug "VLAN $vlan_id removal from VS0: $response"

        log_message "Created VLAN $vlan_id"
    done
}

# Setup vSwitches
setup_vswitches() {
    local session=$1

    if [[ ${#EXL_Group_vswitchid[@]} -eq 0 ]]; then
        log_message "ERROR: No vSwitches configured in EXL_Group_vswitchid array"
        exit 1
    fi

    log_message "Creating vSwitches..."
    for (( i=0; i<${#EXL_Group_vswitchid[@]}; i++ )); do
        local vsw_id=${EXL_Group_vswitchid[$i]}
        local vlan_id=${EXL_Group_vlans[$i]}
        local name="Vsw_Bond${EXL_Group_bondID}_Vlan${vlan_id}"
        local parent="bond${EXL_Group_bondID}.${vlan_id}"

        local response
        if [[ $USE_NEW_SYNTAX -eq 1 ]]; then
            response=$(mgmt_cli add virtual-switch id "$vsw_id" name "$name" interface "$parent" \
                -m "$EXL_Group_IP" --context gaia_api --version 1.8 --format json --session-id "$session" 2>&1)
        else
            response=$(mgmt_cli add virtual-switch id "$vsw_id" name "$name" interfaces.1 "$parent" \
                -m "$EXL_Group_IP" --context gaia_api --version 1.8 --format json --session-id "$session" 2>&1)
        fi
        log_debug "vSwitch $vsw_id creation: $response"
        log_message "Created vSwitch $vsw_id ($name)"
    done
}

# Create Virtual Systems
create_vs() {
    local session=$1
    log_message "Creating Virtual Systems..."

    for vs in $(seq $EXL_Group_start_vs_id $EXL_Group_end_vs_id); do
        local exists=$(mgmt_cli show virtual-gateway id $vs -m "$EXL_Group_IP" \
            --context gaia_api --version 1.8 --format json --session-id "$session" 2>&1)

        if [[ $exists == *"does not exist"* ]]; then
            local idx=$((EXL_Group_vscounter % ${#EXL_Group_vswitchid[@]}))
            local vsw2="${EXL_Group_vswitchid[$idx]}"
            ((EXL_Group_vscounter++))

            idx=$((EXL_Group_vscounter % ${#EXL_Group_vswitchid[@]}))
            local vsw3="${EXL_Group_vswitchid[$idx]}"
            ((EXL_Group_vscounter++))

            local task_id
            if [[ $USE_NEW_SYNTAX -eq 1 ]]; then
                task_id=$(mgmt_cli add virtual-gateway id $vs \
                    one-time-password "$EXL_Group_new_vs_OTP" \
                    resources.firewall-ipv4-instances $EXL_Group_vs_core_count \
                    resources.firewall-ipv6-instances 0 \
                    virtual-switches.1 $EXL_Group_mgmt_vsw_id \
                    virtual-switches.2 $vsw2 \
                    virtual-switches.3 $vsw3 \
                    mgmt-connection.mgmt-connection-identifier "$EXL_Group_mgmt_vsw_id" \
                    mgmt-connection.mgmt-connection-type "virtual-switch-id" \
                    mgmt-connection.mgmt-ipv4-configuration.ipv4-address $EXL_Group_vs_subnet.$vs \
                    mgmt-connection.mgmt-ipv4-configuration.ipv4-mask $EXL_Group_vs_mask_length \
                    mgmt-connection.mgmt-ipv4-configuration.ipv4-default-gateway "$EXL_Group_vs_def_gw" \
                    -m "$EXL_Group_IP" --context gaia_api --version 1.8 --format json --sync false \
                    --session-id "$session" 2>&1 | jq -r '.["task-id"] // empty')
            else
                task_id=$(mgmt_cli add virtual-gateway id $vs \
                    one-time-password "$EXL_Group_new_vs_OTP" \
                    resources.firewall-ipv4-instances $EXL_Group_vs_core_count \
                    resources.firewall-ipv6-instances 0 \
                    resources.virtual-switches.1.id $EXL_Group_mgmt_vsw_id \
                    resources.virtual-switches.2.id $vsw2 \
                    resources.virtual-switches.3.id $vsw3 \
                    mgmt-connection.mgmt-connection-identifier "$EXL_Group_mgmt_vsw_id" \
                    mgmt-connection.mgmt-connection-type "virtual-switch-id" \
                    mgmt-connection.mgmt-ipv4-configuration.ipv4-address $EXL_Group_vs_subnet.$vs \
                    mgmt-connection.mgmt-ipv4-configuration.ipv4-mask $EXL_Group_vs_mask_length \
                    mgmt-connection.mgmt-ipv4-configuration.ipv4-default-gateway "$EXL_Group_vs_def_gw" \
                    -m "$EXL_Group_IP" --context gaia_api --version 1.8 --format json --sync false \
                    --session-id "$session" 2>&1 | jq -r '.["task-id"] // empty')
            fi

            log_message "VS $vs creation task: $task_id (1-3 min per VS)"
        else
            log_message "VS $vs already exists, skipping"
        fi
        ((EXL_Group_ipcounter++))
    done
}

# Monitor VS creation status
check_vs_creation_status() {
    local session=$1
    local expected=$((EXL_Group_end_vs_id - EXL_Group_start_vs_id + 1))

    while true; do
        local total=$(mgmt_cli show virtual-systems limit 1 offset 0 order "ASC" \
            -m "$EXL_Group_IP" --context gaia_api --version 1.8 --format json \
            --session-id "$session" 2>&1 | jq -r ".total // 0")
        local created=$((total - EXL_Group_vlans_to_create))

        clear
        echo "=========================================="
        echo "Virtual System Creation Monitor"
        echo "=========================================="
        echo "Created: $created of $expected VSs"

        [[ $created -ge $expected ]] && break

        echo -n "Waiting (Press C to cancel): "
        for ((i=0; i<12; i++)); do
            echo -n "."
            sleep 5
            read -t 0.1 -n 1 key && [[ $key =~ ^[Cc]$ ]] && {
                echo -e "\nCancelled by user"
                api_logout "$session"
                exit 1
            }
        done
        echo
    done

    log_message "All $expected Virtual Systems created successfully"
}

# Configure interfaces
setup_interfaces() {
    local session=$1
    log_message "Configuring VS interfaces..."

    for id in $(seq $EXL_Group_start_vs_id $EXL_Group_end_vs_id); do
        echo -n "VS $id: "

        local vs_ints=$(mgmt_cli show interfaces virtual-system-id $id \
            -m "$EXL_Group_IP" --context gaia_api --format json --session-id "$session" 2>&1)
        local ints=$(echo "$vs_ints" | jq -r '.objects[].name // empty' 2>/dev/null)

        IFS=$'\n' read -r -d '' -a int_array <<< "$ints"$'\n'

        for iface in "${int_array[@]}"; do
            [[ -z "$iface" ]] && continue

            local mask=16
            [[ "${EXL_Group_ips[$EXL_Group_int_loop_count]}" =~ $EXL_Group_first_octet ]] && mask=22

            mgmt_cli set physical-interface name "$iface" \
                ipv4-address "${EXL_Group_ips[$EXL_Group_int_loop_count]}" \
                ipv4-mask-length $mask virtual-system-id $id \
                -m "$EXL_Group_IP" --context gaia_api --version 1.8 \
                --session-id "$session" &>/dev/null

            ((EXL_Group_int_loop_count++))
            echo -n "."
        done
        echo " Done"
    done

    log_message "Interface configuration complete"
}

# Main execution
main() {
    clear
    echo "=========================================="
    echo "Virtual System Setup Script"
    echo "=========================================="
    echo "Requirements:"
    echo "  - Gateway in VSNext + EXL mode"
    echo "  - SIC established to VS0"
    echo "=========================================="
    echo

    [[ $DEBUG_MODE -eq 1 ]] && log_message "DEBUG MODE ENABLED"

    # Check SSH connectivity
    check_appliance_status || exit 1

    # Login
    local session=$(login)
    log_message "Logged in successfully"
    trap "api_logout $session" EXIT INT TERM

    # Detect JHF version
    check_jhf_version "$session"

    # Execute setup
    log_message "Starting bond and VLAN setup..."
    setup_bonds_and_vlans "$session"

    log_message "Starting vSwitch setup..."
    setup_vswitches "$session"

    log_message "Starting VS creation..."
    create_vs "$session"

    log_message "Monitoring VS creation..."
    check_vs_creation_status "$session"

    log_message "Configuring interfaces..."
    setup_interfaces "$session"

    log_message "Script completed successfully!"
}

main
