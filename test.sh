#!/bin/bash

vg_name="ubuntu-vg" # replace with your volume group name
lv_name="ubuntu-lv" # replace with your logical volume name

lv_attributes=$(lvs --noheadings -o lv_attr $vg_name/$lv_name | awk '{print $1}')
echo "${lv_attributes:0:1}"
echo "${lv_attributes:4:1}"

if [[ "${lv_attributes:0:1}" == "o" ]] && [[ "${lv_attributes:4:1}" == "a" ]]; then
    echo "Logical volume $lv_name is open and active."
else
    echo "Logical volume $lv_name does not have 'o' and 'a' attributes set in positions 1 and 5."
fi
