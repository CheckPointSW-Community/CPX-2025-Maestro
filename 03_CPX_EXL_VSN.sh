#!/bin/bash
# Virtual Systems setup script (extended automatic detection for R82.10+ and JHF>=25)
# Source variables
source ./Combined_vars.txt

# Configuration
DEBUG_MODE=${DEBUG_MODE:-0}  # Set to 1 for verbose output
USE_NEW_SYNTAX=0
ftw_ssh_timeout=${ftw_ssh_timeout:-10}

# Manual overrides (can be set in Combined_vars.txt or exported)
# EXL_Group_force_new_syntax=1 -> force new API syntax
# EXL_Group_os_version="82.10" -> explicit OS version to consider
EXL_Group_force_new_syntax=${EXL_Group_force_new_syntax:-0}
EXL_Group_os_version=${EXL_Group_os_version:-""}

# Logging
log_message() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1"
}

log_debug() {
    [[ $DEBUG_MODE -eq 1 ]] && echo "DEBUG: $1" >&2
}

# Version comparison helper: returns 0 if ver_a >= ver_b
version_ge() {
    local ver_a=$1 ver_b=$2
    local IFS=.
    read -a a_parts <<< "$ver_a"
    read -a b_parts <<< "$ver_b"
    local i
    for ((i=0; i<3; i++)); do
        local A=${a_parts[i]:-0}
        local B=${b_parts[i]:-0}
        # avoid octal interpretation
        A=$((10#$A))
        B=$((10#$B))
        if (( A > B )); then
            return 0
        elif (( A < B )); then
            return 1
        fi
    done
    return 0
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

    if ! command -v curl_cli &>/dev/null; then
        log_message "Warning: curl_cli not found, skipping HTTPS check"
        return 1
    fi

    local response
    response=$(curl_cli -k -s -m $ftw_ssh_timeout --connect-timeout $ftw_ssh_timeout "https://$EXL_Group_IP/" 2>&1)

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

    if check_api_status; then
        return 0
    fi

    log_message "HTTPS failed, attempting SSH check..."
    if check_ssh_status; then
        log_message "Warning: HTTPS unavailable but SSH is reachable"
        return 0
    fi

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
    local response
    response=$(mgmt_cli login user "$EXL_Group_user" password "$EXL_Group_pass" -m "$EXL_Group_IP" --context gaia_api --format json --unsafe-auto-accept true 2>&1)
    log_debug "Login response: $response"

    local session
    session=$(echo "$response" | jq -r '.sid // empty' 2>/dev/null)
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

# Combined detection: JHF Take (old) and kernel/software/FW1 (new)
check_jhf_version() {
    local session=$1
    log_message "Detecting JHF/OS version (JHF Take + kernel/software/FW1 checks)..."

    # 1) Manual override highest precedence
    if [[ "${EXL_Group_force_new_syntax}" == "1" ]]; then
        USE_NEW_SYNTAX=1
        log_message "NEW API syntax forced by EXL_Group_force_new_syntax=1"
        return
    fi

    # 2) Explicit OS version provided
    if [[ -n "$EXL_Group_os_version" ]]; then
        local normalized
        normalized=$(echo "$EXL_Group_os_version" | sed -E 's/[^0-9.]/./g' | sed -E 's/\.+/./g' | sed -E 's/^\.//; s/\.$//')
        log_debug "Normalized EXL_Group_os_version: $normalized"
        if version_ge "$normalized" "82.10"; then
            USE_NEW_SYNTAX=1
            log_message "Using NEW API syntax based on EXL_Group_os_version ($EXL_Group_os_version)"
            return
        else
            log_message "EXL_Group_os_version provided ($EXL_Group_os_version) indicates OLD syntax"
            # continue to allow cpinfo/JHF detection to run (explicit override could be considered final if desired)
        fi
    fi

    # 3) Automatic detection via cpinfo
    local run_response
    run_response=$(mgmt_cli run-script script "cpinfo -y all" -m "$EXL_Group_IP" --context gaia_api --version 1.8 --format json --session-id "$session" 2>&1)

    if [[ "$run_response" == *"generic_error"* ]] || [[ "$run_response" == *"Management API service is not available"* ]]; then
        log_message "Warning: API returned error during cpinfo check, attempting fallback parsing"
        log_debug "API error: $run_response"
        # proceed: attempt to parse whatever text is present
    fi

    if [[ -z "$run_response" ]]; then
        log_message "Warning: Empty response from cpinfo, using OLD syntax unless overrides present"
        USE_NEW_SYNTAX=${USE_NEW_SYNTAX:-0}
        return
    fi

    log_debug "cpinfo run_response (first 500 chars): ${run_response:0:500}"

    # Extract JSON block if present
    local json_response
    json_response=$(echo "$run_response" | sed -n '/{/,$ p')

    # Extract task-id if present
    local task_id
    task_id=$(echo "$json_response" | jq -r '.tasks[0]."task-id" // empty' 2>/dev/null || true)
    if [[ -z "$task_id" || "$task_id" == "null" ]]; then
        task_id=$(echo "$json_response" | jq -r '.tasks[]."task-id" // empty' 2>/dev/null | head -1 || true)
    fi

    # Poll if task-id exists
    local task_json=""
    if [[ -n "$task_id" ]]; then
        log_debug "cpinfo task-id: $task_id"
        local status="in progress"
        local attempt=0
        while [[ "$status" != "succeeded" && "$status" != "failed" && $attempt -lt 30 ]]; do
            sleep 2
            local task_response
            task_response=$(mgmt_cli show task task-id "$task_id" -m "$EXL_Group_IP" --context gaia_api --version 1.8 --format json --session-id "$session" 2>&1)
            task_json=$(echo "$task_response" | sed -n '/{/,$ p')
            status=$(echo "$task_json" | jq -r '.tasks[0].status // empty' 2>/dev/null || true)
            [[ -z "$status" ]] && status="in progress"
            ((attempt++))
        done

        if [[ "$status" != "succeeded" ]]; then
            log_message "Warning: cpinfo task status: $status (or timed out), will attempt to parse available output"
            log_debug "Last task_json (first 1000 chars): ${task_json:0:1000}"
        fi
    fi

    # Extract textual output
    local output=""
    if [[ -n "$task_json" ]]; then
        output=$(echo "$task_json" | jq -r '.tasks[0]."task-details"[0].output // empty' 2>/dev/null || true)
    fi
    if [[ -z "$output" || "$output" == "null" ]]; then
        # Try to extract raw leading text from run_response
        output=$(echo "$run_response" | sed -n '1,400p' || true)
    fi

    if [[ -z "$output" ]]; then
        log_message "Warning: No cpinfo textual output available, using OLD syntax unless overrides present"
        USE_NEW_SYNTAX=${USE_NEW_SYNTAX:-0}
        return
    fi

    # Decode base64 if needed
    local decoded_output
    decoded_output=$(echo "$output" | base64 -d 2>/dev/null || echo "$output")
    log_debug "Decoded cpinfo output (first 800 chars): ${decoded_output:0:800}"

    # --- Old test: JHF Take number ---
    local take_number
    take_number=$(echo "$decoded_output" | grep -oP 'BUNDLE_R82_JUMBO_HF_MAIN.*?Take:\s*\K[0-9]+' 2>/dev/null | head -1 || true)
    if [[ -z "$take_number" ]]; then
        take_number=$(echo "$decoded_output" | sed -n '1,300p' | awk '/JUMBO_HF/{f=1} f && /Take:/{print $NF; exit}' 2>/dev/null || true)
    fi

    # --- New test: kernel/software/FW1 version detection ---
    local kernel_ver sw_ver fw1_ver
    kernel_ver=$(echo "$decoded_output" | sed -n '1,300p' | grep -i -oP 'kernel[: ]*\s*R?\d+\.\d+' 2>/dev/null | grep -oP '\d+\.\d+' | head -1 || true)
    sw_ver=$(echo "$decoded_output" | sed -n '1,300p' | grep -i -oP "software version[^\\n]*R?\d+\.\d+" 2>/dev/null | grep -oP '\d+\.\d+' | head -1 || true)
    fw1_ver=$(echo "$decoded_output" | sed -n '/\[FW1\]/,/\[/{p}' 2>/dev/null | grep -oP 'R?\d+\.\d+' 2>/dev/null | sed 's/^R//' | head -1 || true)

    # Fallback: first Rxx.yy anywhere in top lines
    if [[ -z "$kernel_ver" && -z "$sw_ver" && -z "$fw1_ver" ]]; then
        kernel_ver=$(echo "$decoded_output" | sed -n '1,300p' | grep -oP 'R?\d+\.\d+' 2>/dev/null | sed 's/^R//' | head -1 || true)
    fi

    kernel_ver=$(echo "$kernel_ver" | sed 's/^R//' || true)
    sw_ver=$(echo "$sw_ver" | sed 's/^R//' || true)
    fw1_ver=$(echo "$fw1_ver" | sed 's/^R//' || true)

    log_debug "Parsed values: take_number='$take_number', kernel_ver='$kernel_ver', sw_ver='$sw_ver', fw1_ver='$fw1_ver'"

    # Decision: enable NEW syntax if any test matches
    if [[ -n "$take_number" && "$take_number" =~ ^[0-9]+$ ]]; then
        log_message "Detected JHF Take number: $take_number"
        if (( take_number >= 25 )); then
            USE_NEW_SYNTAX=1
            log_message "Using NEW API syntax because JHF Take >= 25 (Take: $take_number)"
            return
        else
            log_debug "JHF Take < 25"
        fi
    fi

    if [[ -n "$kernel_ver" ]]; then
        log_message "Detected kernel version: $kernel_ver"
        if version_ge "$kernel_ver" "82.10"; then
            USE_NEW_SYNTAX=1
            log_message "Using NEW API syntax based on detected kernel ($kernel_ver)"
            return
        fi
    fi

    if [[ -n "$sw_ver" ]]; then
        log_message "Detected software version: $sw_ver"
        if version_ge "$sw_ver" "82.10"; then
            USE_NEW_SYNTAX=1
            log_message "Using NEW API syntax based on detected software version ($sw_ver)"
            return
        fi
    fi

    if [[ -n "$fw1_ver" ]]; then
        log_message "Detected FW1 version: $fw1_ver"
        if version_ge "$fw1_ver" "82.10"; then
            USE_NEW_SYNTAX=1
            log_message "Using NEW API syntax based on detected FW1 version ($fw1_ver)"
            return
        fi
    fi

    # Final textual presence check (conservative)
    if echo "$decoded_output" | sed -n '1,300p' | grep -q -E 'R?82\.10'; then
        USE_NEW_SYNTAX=1
        log_message "Using NEW API syntax due to presence of R82.10 in cpinfo output"
        return
    fi

    log_message "Warning: Did not detect JHF>=25 nor kernel/software >= R82.10 — using OLD syntax"
    USE_NEW_SYNTAX=0
}

# Setup bonds and VLANs
setup_bonds_and_vlans() {
    local session=$1
    log_message "Creating bond interface $EXL_Group_bondID..."

    local response
    response=$(mgmt_cli add bond-interface id "$EXL_Group_bondID" mode "$EXL_Group_bond_mode" \
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
        local exists
        exists=$(mgmt_cli show virtual-gateway id $vs -m "$EXL_Group_IP" --context gaia_api --version 1.8 --format json --session-id "$session" 2>&1)

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

    log_message "Expecting $expected new Virtual Systems (VS${EXL_Group_start_vs_id} to VS${EXL_Group_end_vs_id})"

    while true; do
        local created=0
        local missing_vs=""

        for vs_id in $(seq $EXL_Group_start_vs_id $EXL_Group_end_vs_id); do
            local check_result
            check_result=$(mgmt_cli show virtual-gateway id $vs_id -m "$EXL_Group_IP" --context gaia_api --version 1.8 --format json --session-id "$session" 2>&1)
            log_debug "VS $vs_id check result: ${check_result:0:200}"

            if [[ $check_result != *"does not exist"* ]] && [[ $check_result != *"not found"* ]]; then
                ((created++))
                log_debug "VS $vs_id found"
            else
                missing_vs="$missing_vs VS$vs_id"
                log_debug "VS $vs_id missing"
            fi
        done

        clear
        echo "=========================================="
        echo "Virtual System Creation Monitor"
        echo "=========================================="
        echo "Target Range: VS${EXL_Group_start_vs_id} to VS${EXL_Group_end_vs_id}"
        echo "Created: $created of $expected VSs"
        [[ -n "$missing_vs" ]] && echo "Missing:$missing_vs"
        echo "=========================================="

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

    log_message "All $expected Virtual Systems created successfully (VS${EXL_Group_start_vs_id} to VS${EXL_Group_end_vs_id})"
}

# Configure interfaces
setup_interfaces() {
    local session=$1
    log_message "Configuring VS interfaces..."

    for id in $(seq $EXL_Group_start_vs_id $EXL_Group_end_vs_id); do
        echo -n "VS $id: "

        local vs_ints
        vs_ints=$(mgmt_cli show interfaces virtual-system-id $id -m "$EXL_Group_IP" --context gaia_api --format json --session-id "$session" 2>&1)
        local ints
        ints=$(echo "$vs_ints" | jq -r '.objects[].name // empty' 2>/dev/null || true)

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

    # Check connectivity
    check_appliance_status || exit 1

    # Login
    local session
    session=$(login)
    log_message "Logged in successfully"
    trap "api_logout $session" EXIT INT TERM

    # Detect JHF / OS version and set USE_NEW_SYNTAX accordingly
    check_jhf_version "$session"
    log_debug "USE_NEW_SYNTAX=$USE_NEW_SYNTAX"

    # Execute setup steps
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
