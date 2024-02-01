# AutoLVMB - Automated Logical Volume Management Backup

## Overview
`autolvmb.sh` is a Bash script designed to automate the management of logical volume (LV) snapshots in LVM2 managed systems, primarily targeting Ubuntu-like distributions. It dynamically calculates snapshot sizes, creates snapshots with user-defined names, and automatically removes the oldest snapshots based on predefined conditions.

### Version: v0.0.528-alpha

## Compatibility
- Developed and tested on Ubuntu Server 22.04 LTS
- Should be compatible with most Debian-based distributions

## Features
- Dynamically calculates and sets the size for new snapshots.
- Creates snapshots with optional user-defined names.
- Non-interactive mode for script automation.
- Automatically identifies and removes the oldest snapshots when their number exceeds a user-defined threshold.
- Interactive confirmation prompts for critical actions to prevent accidental data loss.
- Comprehensive logging of actions and system status for better traceability and debugging.
- Command-line options for customizing behavior, such as listing volume groups, logical volumes, and setting snapshot parameters.

## Requirements
- Dependencies: `bc`, `awk`, `lvm2` (including `vgs`, `lvs`, `lvcreate`, `lvremove`), `date`, `sudo`, `mkdir`, `df`, `hostname`, `pwd`.
- Root privileges are required for managing logical volumes and snapshots.

## Options
- `-h`, `--help`: Display help message and exit.
- `-g`, `--get-groups`: List available volume groups.
- `-l`, `--list-volumes`: List available logical volumes.
- `-nim`, `--non-interactive-mode`: For use with `crontab` or other means of automation.
- `-n`, `--snapshot-name NAME`: Set custom name for the snapshot.
- `-k`, `--snapshot-keep-count COUNT`: Define how many snapshots to retain.
- `-d`, `--device DEVICE`: Specify the device for snapshot creation.
- `-v`, `--version`: Display script version.

## How to Use
1. Ensure the script is executable: `chmod u+x autolvmb.sh`
2. Run the script as root or using sudo: `sudo ./autolvmb.sh [OPTIONS]`
3. Use the command-line options to customize the behavior as needed.

## Disclaimer
This script manages logical volumes and snapshots, which are critical system components. Use it at your own risk. Ensure you understand the operations being performed and have adequate backups before using the script.

## Feedback and Contributions
Contributions and feedback are welcome. Please reach out or contribute via the project's [GitHub repository](https://github.com/anjaustin/autolvmb).

## License
This script is licensed under the [MIT License](https://tripp.mit-license.org/).

## Author
- Aaron `Tripp` N. Josserand Austin, via Z Tangerine, LLC

---
