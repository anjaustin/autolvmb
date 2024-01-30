#!/bin/bash

################################################################################
# autolvmb.sh
################################################################################
# Author: Aaron `Tripp` N. Josserand Austin
# Version: v0.0.444-alpha
# Originated: 27-JAN-2024
################################################################################
# MIT License
################################################################################
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
# The above copyright notice and this permission notice shall be included in all
# copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
# SOFTWARE.
#
# Full License: https://tripp.mit-license.org/
################################################################################
# This script, autolvmb.sh, automates the management of logical volume (LV)
# snapshots. It is designed to work within an LVM2 managed system, specifically
# targeting Ubuntu-like distributions. The script provides functionalities to
# create LV snapshots, manage snapshot size, and automate the removal of old
# snapshots based on predefined conditions.
#
# Features:
# - Dynamically calculates and sets the size for new snapshots.
# - Creates snapshots with optional user-defined names.
# - Automatically identifies and removes the oldest snapshots when the number
#   exceeds a user-defined threshold.
# - Interactive confirmation prompts for critical actions.
# - Comprehensive logging of actions and system status.
#
# Dependencies: bc, awk, lvm2 (vgs, lvs, lvcreate, lvremove), date,
# sudo, mkdir, df, hostname, pwd.
#
# Usage:
# Run the script as root or using sudo. The script accepts several command-line
# options for customizing its behavior. By default, it operates on a predefined
# logical volume and volume group.
#
# Command-Line Options:
# -h, --help: Display help message and exit.
# -g, --get-groups: List available volume groups.
# -l, --list-volumes: List available logical volumes.
# -n, --snapshot-name: Set custom name for the snapshot.
# -k, --snapshot-keep-count: Define how many snapshots to retain.
# -d, --device: Specify the device for snapshot creation.
# -v, --version: Display script version.
#
# Examples:
#   sudo ./autolvmb.sh -h
#   sudo ./autolvmb.sh --snapshot-name my-snapshot
#   sudo ./autolvmb.sh --device my-vg/my-lv --snapshot-name my-snapshot
#
# Feedback and Contributions:
# Contributions and feedback are welcomed. Please reach out or contribute via
# the project's GitHub repository. https://github.com/anjaustin/autolvmb
################################################################################

# Check if the script is run as root
if [ "$(id -u)" -ne 0 ]; then
  echo "This script must be run as root. Please use sudo."
  exit 1
fi

### VARIABLES ###
DEPENDENCIES=("bc" "awk" "vgs" "lvs" "lvcreate" "lvremove" "date" "sudo" "mkdir" "df" "hostname" "pwd")
readonly VG_NAME="ubuntu-vg"
readonly LV_NAME="ubuntu-lv"
readonly THRESHOLD=25
readonly VERSION="v0.0.444-alpha"
readonly LL0="INFO"
readonly LL1="WARNING"
readonly LL2="ERROR"
SNAPSHOT_NAME=${SNAPSHOT_NAME:-"${LV_NAME}_$(date +%Y%m%d_%H%M%S)"}
SNAPSHOT_DEVICE=${SNAPSHOT_DEVICE:-"/dev/${VG_NAME}/${LV_NAME}"}
SNAPSHOT_KEEP_COUNT=${SNAPSHOT_KEEP_COUNT:-30}
LOG_DIR="/var/log/autolvmb"
DEBUG=${DEBUG:-0} # Enable DEBUG mode (set to 1 to enable)
LOG_FILE=""
SNAPSHOT_TO_REMOVE=""

# Check for dependencies
for cmd in "${DEPENDENCIES[@]}"; do
  command -v "${cmd}" >/dev/null 2>&1 || { echo >&2 "Required command ${cmd} is not installed. Aborting."; exit 1; }
done

### FUNCTIONS ###
# Script logging
log_message() {
  # Define log directory and file path
  local timestamp=$(date +"%Y-%m-%d | %H:%M:%S")
  local datestamp=$(date +"%Y-%m-%d")
  local log_file="${LOG_DIR}/${LV_NAME}_${datestamp}.log"
  local log_level="$1"
  local message="$2"
  local function_name="$3"
  LOG_FILE="${log_file}"

  # Log the message with timestamp and log level
  local log_entry="[${timestamp}] >< [${log_level}] > ${function_name} < ${message}"

  # Append the log entry to the log file
  echo -e "${log_entry}" | tee -a "${log_file}" > /dev/null
}

# Print prompts (and logs if DEBUG=1) to terminal and log messages
lprompt() {
  local function_name="${FUNCNAME[1]}"
  local log_level="$1"
  local message="$2"

  # Print both log entry with prompts if DEBUG is 1
  [ "$DEBUG" = "1" ] && echo -e "${function_name} > ${log_level} < ${message}"

  # Always prompt the user and log the activity
  log_message "${log_level}" "${message}" "${function_name}"
  echo -e "${message}"
}

# Setup logging directory and initial log file
make_logging() {
  # Define log directory and file path
  local datestamp=$(date +"%Y-%m-%d")
  local log_file="${LOG_DIR}/${LV_NAME}_${datestamp}.log"

  # Create log directory if it doesn't exist
  if [ ! -d "$LOG_DIR" ]; then
    local make_log_directory=$(mkdir -vp "${LOG_DIR}" || { lprompt "${LL2}" "${LL2}: Could not create log directory. Exiting."; exit 1; })

    if [ "$make_log_directory" != "" ]; then
      lprompt "${LL0}" "Log directory created -> ${make_log_directory}"
    else
      echo -e "${LL2}" "Failed to create log directory."
      exit 1
    fi
  fi

  # Check if log file exists, create if not
  if [ ! -f "${log_file}" ]; then
    touch "${log_file}" && lprompt "${LL0}" "${LL0}: Log file created." || { lprompt "${LL2}" "${LL2}: Could not create log file. Exiting."; exit 1; }
    lprompt "${LL0}" "$(chmod -v 644 ${log_file})" || { lprompt "${LL2}" "${LL2}: Could not chmod log file to 644. Exiting."; exit 1; }
    lprompt "${LL0}" "Log file created -> ${log_file}"
    LOG_FILE="${log_file}"
  fi
}

confirm_action() {
  log_message "${LL0}" "$1" "${FUNCNAME[0]}"

  while true; do
    read -p "$1 (y/n): " yn
    case $yn in
      [Yy]* ) break;;
      [Nn]* ) lprompt "${LL1}" "Action cancelled by user."; return 1;;
      * ) lprompt "${LL0}" "Please answer Y for yes or N for no.";;
    esac
  done
}

set_snapshot_size() {
  # Retrieve the size of ubuntu-lv in megabytes (MB) and remove the 'm' character
  local size=$(lvs --noheadings --units m --options LV_SIZE ${VG_NAME}/${LV_NAME} | tr -d '[:space:]m' || { lprompt "${LL2}" "${LL2}: Could not get size of active logical volume. Exiting."; exit 1; })
  local ssize=$(echo "$size * 0.025" | bc || { lprompt "${LL2}" "${LL2}: Could not set size for snapshot. Exiting."; exit 1; })
  
  log_message "${LL0}" "Snapshot size set to ${ssize}M." "${FUNCNAME[0]}"
  local ssize=$(echo "$ssize" | cut -d. -f1)
  echo $ssize
}

# Generate lv snapshot
create_snapshot() {
  confirm_action "Are you sure you want to create a snapshot?" || return

  # Call set_snapshot_size and capture the output
  local SNAPSHOT_SIZE="$(set_snapshot_size)"

  # Create the snapshot
  lprompt "${LL0}" "$(lvcreate --size ${SNAPSHOT_SIZE} --snapshot --name ${SNAPSHOT_NAME} ${SNAPSHOT_DEVICE})"

  # Check if the snapshot creation was successful
  if [ $? -eq 0 ]; then
    lprompt "${LL0}" "Snapshot created: ${SNAPSHOT_NAME}"
  else
    lprompt "${LL2}" "Snapshot creation failed for ${SNAPSHOT_NAME}."
    exit 1
  fi
}

get_oldest_snapshot() {
  # Get the list of logical volumes along with their creation times
  local lv_count=$(lvs --noheadings --sort=-lv_time -o lv_name "${VG_NAME}" | wc -l || { lprompt "${LL2}" "${LL2}: Could not get list of logical volumes. Exiting."; exit 1; })

  # If there's only one LV, or if the only LV is the active logical volume set SNAPSHOT_TO_REMOVE to None.
  if [ "$lv_count" -le 1 ]; then
    log_message "${LL0}" "Only one logical volume exists in the volume group ${VG_NAME}." "${FUNCNAME[0]}"
    log_message "${LL1}" "Only the active logical volume, ${SNAPSHOT_DEVICE}, exists. No snapshots detected." "${FUNCNAME[0]}"
    SNAPSHOT_TO_REMOVE=None
    log_message "${LL0}" "Oldest snapshot: ${SNAPSHOT_TO_REMOVE}" "${FUNCNAME[0]}"
  else
    # Get the oldest snapshot from lvs
    local oldest_snapshot=$(lvs --sort=-lv_time --row -o lv_name "${VG_NAME}" | awk '/ / {print $(NF-1)}' || { lprompt "${LL2}" "${LL2}: Could not get list of logical volumes. Exiting."; exit 1; })
    local lv_attributes=$(lvs --noheadings -o lv_attr ${VG_NAME}/${oldest_snapshot} | awk '{print $1}')
    if [[ "$LV_NAME" == "$oldest_snapshot" ]] && [[ "${lv_attributes:0:1}" == "o" ]]; then
      SNAPSHOT_TO_REMOVE=None
      log_message "${LL0}" "Oldest snapshot: ${SNAPSHOT_TO_REMOVE}. Removing a snapshot that is currently in use would not be wise." "${FUNCNAME[0]}"
    else
      SNAPSHOT_TO_REMOVE="${oldest_snapshot}"
      log_message "${LL0}" "Oldest snapshot: ${SNAPSHOT_TO_REMOVE}" "${FUNCNAME[0]}"
    fi
  fi
}

# Housekeeping
retire_old_snapshots() {
  if [ $SNAPSHOT_TO_REMOVE == None ]; then
    lprompt "$LL0" "No snapshots exist. Nothing to remove."
    exit 0
  fi
  # Get the free space information for the current volume and extract the free space percentage
  local used_space_percentage=$(df -h . | awk 'NR==2 { sub("%", "", $5); print $5 }')
  local oldest_snapshot="/dev/${VG_NAME}/${SNAPSHOT_TO_REMOVE}"
  local old_snapshots=$(lvs --noheadings -o lv_name --sort lv_time | grep 'ubuntu-lv_' | head -n 16 || { lprompt "${LL2}" "${LL2}: Could not get list of logical volumes. Exiting."; exit 1; })
  local total_snapshots=$(echo "${old_snapshots}" | wc -l)

  # Remove oldest snapshot if the used space percentage is less than or equal to the threshold
  if [ "${used_space_percentage}" -ge "${THRESHOLD}" ]; then
    lprompt "${LL0}" "Used space is greater than or equal to ${THRESHOLD}% of the total volume size."

    # Check if an oldest file exists and retire it
    if [ -b "${oldest_snapshot}" ]; then
      lprompt "${LL0}" "$(lvs ${VG_NAME}/${oldest_snapshot} && lvs -o lv_time ${VG_NAME}/${oldest_snapshot})"
      confirm_action "Are you sure you want to remove snapshot ${oldest_snapshot}?" || return
      lprompt "${LL0}" "Removing the oldest snapshot: ${oldest_snapshot}"
      lvremove -f "${oldest_snapshot}"
    else
      lprompt "${LL1}" "No matching snapshots were found."
    fi
  else
    lprompt "${LL0}" "At ${used_space_percentage}%, used space is less than ${THRESHOLD}% of the total volume size. No snapshots need to be retired at this time."
  fi

  # Remove the last 16 snapshots if there are more than 32 snapshots
  if [ "$total_snapshots" -ge 34 ]; then # Set to 34 to account for the origin/open LV
    confirm_action "Are you sure you want to remove the 10 oldest snapshots?" || return
    lprompt "${LL0}" "Removing the 10 oldest snapshots..."
    for snapshot in $old_snapshots; do
      local lv_attributes=$(lvs --noheadings -o lv_attr ${VG_NAME}/${snapshot} | awk '{print $1}' || { lprompt "${LL2}" "${LL2}: Could not get list of logical volumes. Exiting."; exit 1; })
      if [ "$snapshot" != "$LV_NAME" ] && [[ "${lv_attributes:0:1}" == "s" ]]; then
        lprompt "${LL0}" "$(lvremove -f /dev/${VG_NAME}/${snapshot})"
      fi
    done
  else
    lprompt "${LL0}" "There less than 33 snapshots of the open logical volume. No snapshots need to be retired at this time."
  fi
}

# Parse command-line options
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)
      # Display usage information
      cat <<EOF
Usage: [sudo] $0 [-h|--help] [-v|--version] [-n|--snapshot-name NAME] [-k|--snapshot-keep-count 30] [-d|--device DEVICE PATH] ...

Create a snapshot of a logical volume.

Options:
  -h, --help                        Display this help message and exit.
  -g, --get-groups                  List availavble volume groups.
  -l, --list-volumes                List the available logical volumes.
  -n, --snapshot-name NAME          Set the name for the snapshot. Default is "backup-snapshot".
  -k, --snapshot-keep-count INTEGER Set the number of snapshots to keep. Snapshots in excess of this number will be removed. Default is 30.
  -d, --device DEVICE               Set the device you wish to snapshot. Default is "/dev/ubuntu-vg/ubuntu-lv".
  -v, --version                     Display version information.

Examples:
  ./autolvmb.sh
  sudo ./autolvmb.sh --snapshot-name my-snapshot
  sudo ./autolvmb.sh --device my-vg/my-lv --snapshot-name my-snapshot

Requirements:
  - This script selectively requires elevated privileges. You can run it with 'sudo' for your convenience.
  - Dependencies: lvm2 (for lvcreate, lvs, lvremove).

How to Run:
  1. Make the script executable: chmod u+x $0
  2. Run the script: [sudo] $0
  3. Optionally, specify snapshot name and device.

EOF
      exit 0
      ;;
    -g|--get-groups)
      vgs
      exit 0
      ;;
    -l|--list-volumes)
      lvs
      exit 0
      ;;
    -n|--snapshot-name)
      shift
      SNAPSHOT_NAME="$1"
      ;;
    -k|--snapshot-keep-count)
      shift
      SNAPSHOT_KEEP_COUNT="$1"
      ;;
    -d|--device)
      shift
      SNAPSHOT_DEVICE="$1"
      ;;
    -v|--version)
      echo "$VERSION"
      exit
      ;;
    *)
      echo "Invalid option. Use -h or --help for usage information."
      exit 1
      ;;
  esac
  shift
done

make_logging
log_message "${LL0}" "Logging ready." "MAIN"

log_message "${LL0}" "Script execution started on $(hostname -f):$(pwd)." "MAIN"

log_message "${LL0}" "Starting snapshot script..." "MAIN"
create_snapshot
log_message "${LL0}" "Snapshot completed." "MAIN"

log_message "${LL0}" "Check for oldest snapshot..." "MAIN"
get_oldest_snapshot
log_message "${LL0}" "Check for oldest snapshot completed." "MAIN"

log_message "${LL0}" "Preparing to remove old snapshots if need..." "MAIN"
retire_old_snapshots
log_message "${LL0}" "Check log file ${LOG_DIR}/${LOG_FILE} for details." "MAIN"

log_message "${LL0}" "Snapshot script completed." "MAIN"

exit 0
# EOF >>>