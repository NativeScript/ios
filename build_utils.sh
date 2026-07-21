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

# Shared --spm-mode argument parsing for build_npm_ios.sh / build_npm_vision.sh.
# Sets SPM_MODE (embedded|remote, default embedded). The calling script must
# define usage(); accepts both "--spm-mode <mode>" and "--spm-mode=<mode>".
function parse_spm_mode_args {
    SPM_MODE="embedded"
    while [ $# -gt 0 ]; do
        case "$1" in
            --spm-mode)
                if [ $# -lt 2 ]; then
                    echo "--spm-mode requires a value" >&2
                    usage >&2
                    exit 1
                fi
                SPM_MODE="$2"
                shift 2
                ;;
            --spm-mode=*)
                SPM_MODE="${1#*=}"
                shift
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                echo "Unknown argument: $1" >&2
                usage >&2
                exit 1
                ;;
        esac
    done

    case "$SPM_MODE" in
        embedded|remote) ;;
        *)
            echo "Invalid --spm-mode '$SPM_MODE' (expected embedded or remote)" >&2
            usage >&2
            exit 1
            ;;
    esac
}