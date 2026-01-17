#!/bin/bash

###############################################################################
# Script: disable_ovf_validation_flag.sh
# Purpose: Disable OVF validation during Edge/MP deployment
# Usage: bash /tmp/disable_ovf_validation_flag.sh
###############################################################################

set -euo pipefail

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Configuration
PROPERTIES_FILE="/config/vmware/auth/ovf_validation.properties"
PROPERTIES_FILE_CHANGED_BY_SCRIPT="/config/vmware/auth/ovf_validation_file_changed_by_script"
FLAG_NAME="INTERNAL_OVFS_VALIDATION_FLAG"
OLD_VALUE="0"
NEW_VALUE="2"

# Logging function
log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Function to verify current flag value
verify_current_flag() {
    if ! grep -q "^${FLAG_NAME}=${OLD_VALUE}$" "${PROPERTIES_FILE}"; then
        log_warn "Current flag value is not ${OLD_VALUE}. Checking current value..."
        if grep -q "^${FLAG_NAME}=${NEW_VALUE}$" "${PROPERTIES_FILE}"; then
            log_warn "Flag is already set to ${NEW_VALUE}. No changes needed."
            return 2
        else
            local current_value=$(grep "^${FLAG_NAME}=" "${PROPERTIES_FILE}" | cut -d'=' -f2 || echo "not found")
            log_error "Unexpected flag value: ${current_value}"
            log_error "Expected: ${FLAG_NAME}=${OLD_VALUE}"
            exit 1
        fi
    fi
    return 0
}

# Function to update the flag
update_flag() {
    # Use sed to update the flag value
    sed -i "s/^${FLAG_NAME}=${OLD_VALUE}$/${FLAG_NAME}=${NEW_VALUE}/" "${PROPERTIES_FILE}" || {
        log_error "Failed to update the flag in properties file"
        exit 1
    }
    
    # Verify the change
    if grep -q "^${FLAG_NAME}=${NEW_VALUE}$" "${PROPERTIES_FILE}"; then
        log_info "Flag updated successfully"
        touch "${PROPERTIES_FILE_CHANGED_BY_SCRIPT}"
        return 0
    else
        log_error "Flag update verification failed"
        exit 1
    fi
}

# Function to display success message
display_success() {
    echo ""
    log_info "==================================================================="
    log_info "SUCCESS: Flag update completed successfully"
    log_info "==================================================================="
    echo ""
    log_warn "Please run this script on the remaining Manager node(s) in the cluster."
    echo ""
}

# Function to display failure message
display_failure() {
    echo ""
    log_error "==================================================================="
    log_error "FAILURE: Script execution failed"
    log_error "==================================================================="
}

# Main execution
main() {
    echo ""
    log_info "Starting OVF validation flag update script"
    log_info "Timestamp: $(date)"
    echo ""
    
    # Verify current flag value
    verify_current_flag
    local verify_result=$?
    if [ ${verify_result} -eq 2 ]; then
        log_info "Flag already set to desired value. Exiting."
        exit 0
    fi
    
    # Update flag
    if update_flag; then
        display_success
        exit 0
    else
        display_failure
        exit 1
    fi
}

# Trap to handle script interruption
trap 'log_error "Script interrupted"; exit 1' INT TERM

# Run main function
main "$@"

