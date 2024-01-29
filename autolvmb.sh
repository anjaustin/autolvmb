#!/bin/bash

################################################################################
# autolvmb.sh
################################################################################
# Author: Aaron `Tripp` N. Josserand Austin
# Version: v0.0.3-alpha
# Date: 27-JAN-2024 T 21:13 Mountain US
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

# Check if the script is run as root
if [ "$(id -u)" -ne 0 ]; then
    echo "This script must be run as root. Please use sudo."
    exit 1
fi

### VARIABLES ###
readonly VG_NAME="ubuntu-vg"
readonly LV_NAME="ubuntu-lv"
readonly SNAPSHOT_DEVICE="/dev/${VG_NAME}/${LV_NAME}"
readonly SNAPSHOT_NAME="${LV_NAME}_$(date +%Y%m%d_%H%M%S)"
readonly THRESHOLD=75
readonly SNAPSHOT_PATTERN="${LV_NAME}_*"
readonly VERSION="v0.0.3-alpha"
readonly LL=("INFO" "WARNING" "ERROR")
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
  log_message "$log_level" "$message"
  echo -e "$message"
}

# Setup logging directory and initial log file
make_logging() {
  # Define log directory and file path
  local datestamp=$(date +"%Y-%m-%d")
  local log_file="${LOG_DIR}/${LV_NAME}_${datestamp}.log"

  # Create log directory if it doesn't exist
  if [ ! -d "$LOG_DIR" ]; then
    local make_log_dir=$(sudo mkdir -vp "${LOG_DIR}" || exit 1)

    if [ "$make_log_directory" != "" ]; then
      lprompt "${LL[0]}" "Log directory created -> ${make_log_dir}"
    else
      echo -e "${LL[2]}" "Failed to create log directory."
      exit 1
    fi
  fi

  # Check if log file exists, create if not
  if [ ! -f "$log_file" ]; then
    sudo touch "$log_file" || { lprompt "${LL[2]}" "${LL[2]}: Could not create log file. Exiting."; exit 1; }
    sudo chmod 644 "$log_file"
    lprompt "${LL[0]}" "Log file created -> ${log_file}"
    LOG_FILE="$log_file"
  fi
}

set_snapshot_size() {
  # Retrieve the size of ubuntu-lv in megabytes (MB) and remove the 'm' character
  size=$(sudo lvs --noheadings --units m --options LV_SIZE ubuntu-vg/ubuntu-lv | tr -d '[:space:]m')

  # Calculate 2.5% of this size and echo it
  echo $(echo "$size * 0.025" | bc)
}

# Generate lv snapshot
create_snapshot() {
  # Call set_snapshot_size and capture the output
  local SNAPSHOT_SIZE="$(set_snapshot_size)M"

  # Create the snapshot
  lvcreate --size "${SNAPSHOT_SIZE}" --snapshot --name "${SNAPSHOT_NAME}" "${SNAPSHOT_DEVICE}"

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

    # Get the oldest LV
    # oldest_snapshot=$(echo "${lv_list}" | awk '/ / {print $(NF-1)}')

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

  echo "$oldest_snapshot"

  # Check if the used space percentage is less than or equal to the threshold
  if [ "${used_space_percentage}" -ge "${THRESHOLD}" ]; then
    lprompt "${LL[0]}" "Used space is greater than or equal to ${THRESHOLD}% of the total volume size."

    # Check if an oldest file exists and retire it
    if [ -b "${oldest_snapshot}" ]; then
      lprompt "${LL[0]}" "Removing the oldest snapshot: ${oldest_snapshot}"
      # lvremove "${oldest_snapshot}"
    else
      lprompt "${LL[1]}" "No matching snapshots were found."
    fi

  else
    lprompt "${LL[0]}" "At ${used_space_percentage}%, used space is less than ${THRESHOLD}% of the total volume size. No snapshots need to be retired at this time."
  fi
}

make_logging
log_message "${LL[0]}" "Logging ready."

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
