#!/bin/bash

################################################################################
# autolvmb.sh
################################################################################
# Author: Aaron `Tripp` N. Josserand Austin
# Version: v0.0.396-alpha
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
# Dependencies: bc, awk, lvm2 utilities (vgs, lvs, lvcreate, lvremove), date,
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
#   sudo ./autolvmb.sh
#   sudo ./autolvmb.sh --snapshot-name my-snapshot
#   sudo ./autolvmb.sh --device my-vg/my-lv --snapshot-name my-snapshot
#
# Note:
# Ensure that the script is run with sufficient privileges, as it requires root
# access for most of its operations. The script performs checks and logging to
# ensure transparency and reliability during execution.
#
# Feedback and Contributions:
# Contributions and feedback are welcomed. Please reach out or contribute via
# the project's GitHub repository.
################################################################################

# Check if the script is run as root
if [ "$(id -u)" -ne 0 ]; then
  echo "This script must be run as root. Please use sudo."
  exit 1
fi

### VARIABLES ###
readonly VG_NAME="ubuntu-vg"
readonly LV_NAME="ubuntu-lv"
readonly THRESHOLD=25
readonly VERSION="v0.0.396-alpha"
readonly LL=("INFO" "WARNING" "ERROR")
SNAPSHOT_NAME=${SNAPSHOT_NAME:-"${LV_NAME}_$(date +%Y%m%d_%H%M%S)"}
SNAPSHOT_DEVICE=${SNAPSHOT_DEVICE:-"/dev/${VG_NAME}/${LV_NAME}"}
SNAPSHOT_KEEP_COUNT=${SNAPSHOT_KEEP_COUNT:-30}
LOG_DIR="/var/log/autolvmb"
DEBUG=${DEBUG:-0} # Enable DEBUG mode (set to 1 to enable)
LOG_FILE=""
SNAPSHOT_TO_REMOVE=""

### FUNCTIONS ###
# Script logging
log_message() {
  # Define log directory and file path
  local timestamp=$(date +"%Y-%m-%d | %H:%M:%S")
  local datestamp=$(date +"%Y-%m-%d")
  local log_file="${LOG_DIR}/${LV_NAME}_${datestamp}.log"
  local log_level="$1"
  local message="$2"
  LOG_FILE="${log_file}"

  # Log the message with timestamp and log level
  local log_entry="[${timestamp}] >< [${log_level}] : ${message}"

  # Append the log entry to the log file
  echo -e "$log_entry" | sudo tee -a "$log_file" > /dev/null
}

# Print prompts (and logs if DEBUG=1) to terminal and log messages
lprompt() {
  local log_level="$1"
  local message="$2"

  # Print both log entry with prompts if DEBUG is 1
  [ "$DEBUG" = "1" ] && echo -e "${log_level}: ${message}"

  # Always prompt the user and log the activity
  log_message "${log_level}" "${message}"
  echo -e "${message}"
}

# Setup logging directory and initial log file
make_logging() {
  # Define log directory and file path
  local datestamp=$(date +"%Y-%m-%d")
  local log_file="${LOG_DIR}/${LV_NAME}_${datestamp}.log"

  # Create log directory if it doesn't exist
  if [ ! -d "$LOG_DIR" ]; then
    local make_log_dir=$(sudo mkdir -vp "${LOG_DIR}" || { lprompt "${LL[2]}" "${LL[2]}: Could not create log directory. Exiting."; exit 1; })

    if [ "$make_log_directory" != "" ]; then
      lprompt "${LL[0]}" "Log directory created -> ${make_log_dir}"
    else
      echo -e "${LL[2]}" "Failed to create log directory."
      exit 1
    fi
  fi

  # Check if log file exists, create if not
  if [ ! -f "${log_file}" ]; then
    sudo touch "${log_file}" && lprompt "${LL[0]}" "${LL[0]}: Log file created." || { lprompt "${LL[2]}" "${LL[2]}: Could not create log file. Exiting."; exit 1; }
    lprompt "${LL[0]}" "$(sudo chmod -v 644 ${log_file})" || { lprompt "${LL[2]}" "${LL[2]}: Could not chmod log file to 644. Exiting."; exit 1; }
    lprompt "${LL[0]}" "Log file created -> ${log_file}"
    LOG_FILE="${log_file}"
  fi
}

confirm_action() {
  lprompt "${LL[0]}" "$1"

  while true; do
    read -p "$1 (y/n): " yn
    case $yn in
      [Yy]* ) break;;
      [Nn]* ) lprompt "${LL[1]}" "Action cancelled by user."; return 1;;
      * ) lprompt "${LL[0]}" "Please answer Y for yes or N for no.";;
    esac
  done
}

set_snapshot_size() {
  # Retrieve the size of ubuntu-lv in megabytes (MB) and remove the 'm' character
  size=$(sudo lvs --noheadings --units m --options LV_SIZE ubuntu-vg/ubuntu-lv | tr -d '[:space:]m')

  ssize=$(echo "$size * 0.025" | bc)

  lprompt "${LL[0]}" "Snapshot size set to ${ssize}M."

  # Calculate 2.5% of this size and echo it
  echo $ssize
}

# Generate lv snapshot
create_snapshot() {
  confirm_action "Are you sure you want to create a snapshot?" || return

  # Call set_snapshot_size and capture the output
  local SNAPSHOT_SIZE="$(set_snapshot_size)M"

  # Create the snapshot
  lprompt "${LL[0]}" "$(lvcreate --size $SNAPSHOT_SIZE --snapshot --name $SNAPSHOT_NAME $SNAPSHOT_DEVICE)"

  # Check if the snapshot creation was successful
  if [ $? -eq 0 ]; then
    lprompt "${LL[0]}" "Snapshot created: ${SNAPSHOT_NAME}"
  else
    lprompt "${LL[2]}" "Snapshot creation failed for ${SNAPSHOT_NAME}."
    exit 1
  fi
}

get_oldest_snapshot() {
  # Variable to store the name of the oldest snapshot
  local oldest_snapshot=""

  # Get the list of logical volumes along with their creation times
  lv_list=$(sudo lvs --noheadings --sort=-lv_time --rows -o lv_name $VG_NAME)

  # Count the number of logical volumes
  lv_count=$(echo "$lv_list" | awk '/ / {count += NF} END {print count}')

  # If there's only one LV, you might choose to handle it differently
  if [ "$lv_count" -le 1 ]; then
    log_message "${LL[0]}" "Only one logical volume present. Nothing to compare."

    if [ "$LV_NAME" == "$oldest_snapshot" ]; then
      log_message "${LL[1]}" "Only the active logical volume, ${SNAPSHOT_DEVICE}, exists. No snapshots detected."
    fi
  else
    # Process the list to find the oldest snapshot
    oldest_snapshot=$(sudo lvs --sort=-lv_time --rows -o lv_name $VG_NAME | awk '/ / {print $(NF-1)}')

    # Set snapshot to be retired if need be
    SNAPSHOT_TO_REMOVE=$oldest_snapshot

    # Output the oldest snapshot
    log_message "${LL[0]}" "Oldest snapshot: ${oldest_snapshot}"
  fi
}

# Housekeeping
retire_old_snapshots() {
  # Get the free space information for the current volume and extract the free space percentage
  local used_space_percentage=$(df -h . | awk 'NR==2 { sub("%", "", $5); print $5 }')
  local oldest_snapshot="/dev/${VG_NAME}/${SNAPSHOT_TO_REMOVE}"
  local total_snapshots=$(echo "$old_snapshots" | wc -l)
  local old_snapshots=$(sudo lvs --noheadings -o lv_name --sort lv_time | grep 'ubuntu-lv_' | head -n 10)

  # Check if the used space percentage is less than or equal to the threshold
  if [ "${used_space_percentage}" -ge "${THRESHOLD}" ]; then
    lprompt "${LL[0]}" "Used space is greater than or equal to ${THRESHOLD}% of the total volume size."

    # Check if an oldest file exists and retire it
    if [ -b "${oldest_snapshot}" ]; then
      confirm_action "Are you sure you want to remove snapshot ${oldest_snapshot}?" || return
      lprompt "${LL[0]}" "Removing the oldest snapshot: ${oldest_snapshot}"
      lvremove "${oldest_snapshot}"
    else
      lprompt "${LL[1]}" "No matching snapshots were found."
    fi
  elif [ "$total_snapshots" -ge 30 ]; then
    confirm_action "Are you sure you want to remove the 10 oldest snapshots?" || return
    lprompt "${LL[0]}" "Removing the 10 oldest snapshots..."
    for snapshot in $old_snapshots; do
      lvremove -f "${snapshot}"
    done
  elif [ "$total_snapshots" -lt 30 ]; then
    lprompt "${LL[0]}" "There less than 30 snapshots of the active logical volume. No snapshots need to be retired at this time."
  else
    lprompt "${LL[0]}" "At ${used_space_percentage}%, used space is less than ${THRESHOLD}% of the total volume size. No snapshots need to be retired at this time."
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
      sudo vgs
      exit 0
      ;;
    -l|--list-volumes)
      sudo lvs
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
log_message "${LL[0]}" "Logging ready."

log_message "${LL[0]}" "Script execution started on $(hostname -f):$(pwd)."

log_message "${LL[0]}" "Starting snapshot script..."
create_snapshot
log_message "${LL[0]}" "Snapshot completed."

log_message "${LL[0]}" "Check for oldest snapshot..."
get_oldest_snapshot
log_message "${LL[0]}" "Check for oldest snapshot completed."

log_message "${LL[0]}" "Preparing to remove old snapshots if need..."
retire_old_snapshots
log_message "${LL[0]}" "Check log file ${LOG_DIR}/${LOG_FILE} for details."

log_message "${LL[0]}" "Snapshot script completed."
