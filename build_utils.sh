#!/bin/bash
set -e

# include this in other bash scripts with the following line:
#
# source "$(dirname "$0")/build_utils.sh"
#

# Prints a timestamp + title for a step/section
function checkpoint {
    local delimiter="--------------------------------------------------------------------------------"

    echo ""
    echo ""
    echo "$delimiter"
    echo "--- $(date +'%T') --- $1 "
    echo "$delimiter"
    echo ""
}