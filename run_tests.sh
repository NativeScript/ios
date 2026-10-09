#!/bin/bash

# Test output contains non-ASCII characters (e.g. the Unicode property tests);
# without a UTF-8 locale xcpretty dies with "invalid byte sequence in US-ASCII"
export LC_ALL=en_US.UTF-8

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TESTS_ROOT="$SCRIPT_DIR/build/tests"

# Every simulator this script creates carries this prefix; --delete-sims
# removes anything matching it, so never give it to a hand-made simulator.
SIM_PREFIX="ns-test-"
PREFERRED_DEVICE_TYPE="iPhone 16 Pro"

get_available_devices() {
  xcrun simctl list devices available --json 2>/dev/null | python3 -c "
import json, sys
data = json.load(sys.stdin)
for runtime, devices in data['devices'].items():
    if 'iOS' not in runtime:
        continue
    os_ver = runtime.split('.')[-1].replace('-', '.')
    for d in devices:
        if d['isAvailable']:
            print(f'{d[\"state\"]}\t{d[\"udid\"]}\t{d[\"name\"]}\t{os_ver}')
"
}

# Resolves a device name to a UDID the same way xcodebuild would for a
# name-only destination: a booted match wins, otherwise the newest OS.
resolve_device_name() {
  local matches
  matches=$(get_available_devices | awk -F'\t' -v name="$1" '$3 == name')

  if [ -z "$matches" ]; then
    echo "No available iOS simulator named '$1'." >&2
    exit 1
  fi

  local chosen
  chosen=$(echo "$matches" | grep "^Booted" | head -n 1)
  if [ -z "$chosen" ]; then
    chosen=$(echo "$matches" | sort -t$'\t' -k4,4V | tail -n 1)
  fi

  DEVICE_UDID=$(echo "$chosen" | cut -f2)
  echo "Using simulator: $(echo "$chosen" | cut -f3) ($(echo "$chosen" | cut -f4))" >&2
}

select_device() {
  local devices
  devices=$(get_available_devices)

  if [ -z "$devices" ]; then
    echo "No available iOS simulators found." >&2
    exit 1
  fi

  # Check for booted devices first
  local booted
  booted=$(echo "$devices" | grep "^Booted")

  if [ -n "$booted" ]; then
    local booted_count
    booted_count=$(echo "$booted" | wc -l | tr -d ' ')
    if [ "$booted_count" -eq 1 ]; then
      local name os_ver
      DEVICE_UDID=$(echo "$booted" | cut -f2)
      name=$(echo "$booted" | cut -f3)
      os_ver=$(echo "$booted" | cut -f4)
      echo "Using running simulator: $name ($os_ver)" >&2
      return
    fi
  fi

  if [ ! -t 0 ]; then
    echo "No single booted simulator and stdin is not a terminal; pass -d, -u, --temp-sim or --keep-sim." >&2
    exit 1
  fi

  # Interactive selection
  echo "Available iOS Simulators:" >&2
  if [ -n "$booted" ]; then
    echo "(* = currently running)" >&2
  fi
  echo "" >&2

  local i=1
  local udids=() names=() os_vers=()
  while IFS=$'\t' read -r state udid name os_ver; do
    local marker=""
    if [ "$state" = "Booted" ]; then
      marker=" *"
    fi
    printf "  %2d) %s (%s)%s\n" "$i" "$name" "$os_ver" "$marker" >&2
    udids+=("$udid")
    names+=("$name")
    os_vers+=("$os_ver")
    i=$((i + 1))
  done <<< "$devices"

  echo "" >&2
  read -rp "Select device [1]: " choice
  choice=${choice:-1}

  if ! [[ "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt "${#udids[@]}" ]; then
    echo "Invalid selection." >&2
    exit 1
  fi

  local idx=$((choice - 1))
  echo "Selected: ${names[$idx]} (${os_vers[$idx]})" >&2
  DEVICE_UDID="${udids[$idx]}"
}

# Prints "<runtime id>\t<device type id>\t<description>" for a new simulator.
# Runtime: --runtime, else the newest available iOS runtime.
# Device type: --device-type, else PREFERRED_DEVICE_TYPE when the runtime
# supports it, else the newest iPhone the runtime supports.
pick_sim_spec() {
  xcrun simctl list runtimes --json 2>/dev/null | python3 -c "
import json, sys
want_runtime, want_type, preferred = sys.argv[1], sys.argv[2], sys.argv[3]

def vkey(v):
    return [int(p) for p in v.split('.') if p.isdigit()]

runtimes = [r for r in json.load(sys.stdin)['runtimes']
            if r.get('isAvailable') and r.get('platform', 'iOS') == 'iOS'
            and r['identifier'].startswith('com.apple.CoreSimulator.SimRuntime.iOS')]
if want_runtime:
    runtimes = [r for r in runtimes
                if want_runtime in (r['identifier'], r['name'], r['version'])]
    if not runtimes:
        sys.exit(f'No available iOS runtime matches \"{want_runtime}\".')
if not runtimes:
    sys.exit('No available iOS simulator runtime installed.')
runtime = max(runtimes, key=lambda r: vkey(r['version']))

types = runtime.get('supportedDeviceTypes', [])
if want_type:
    chosen = [t for t in types if want_type in (t['identifier'], t['name'])]
    if not chosen:
        sys.exit(f'Runtime {runtime[\"name\"]} does not support device type \"{want_type}\".')
    dtype = chosen[0]
else:
    iphones = [t for t in types if t.get('productFamily') == 'iPhone']
    if not iphones:
        sys.exit(f'Runtime {runtime[\"name\"]} supports no iPhone device type.')
    exact = [t for t in iphones if t['name'] == preferred]
    dtype = exact[0] if exact else max(iphones, key=lambda t: t.get('minRuntimeVersion', 0))
print(f'{runtime[\"identifier\"]}\t{dtype[\"identifier\"]}\t{dtype[\"name\"]}, {runtime[\"name\"]}')
" "$SIM_RUNTIME" "$SIM_DEVICE_TYPE" "$PREFERRED_DEVICE_TYPE"
}

# Prints "<udid>\t<state>\t<name>" for every simulator whose name starts with
# SIM_PREFIX, including ones whose runtime has since been removed.
list_temp_sims() {
  xcrun simctl list devices --json 2>/dev/null | python3 -c "
import json, sys
prefix = sys.argv[1]
for devices in json.load(sys.stdin)['devices'].values():
    for d in devices:
        if d['name'].startswith(prefix):
            print(f'{d[\"udid\"]}\t{d[\"state\"]}\t{d[\"name\"]}')
" "$SIM_PREFIX"
}

# Sets DEVICE_UDID to the simulator named $1, creating it if needed, and boots
# it. Reusing by name lets --keep-sim runs share one warm simulator.
ensure_sim() {
  local name="$1" existing
  existing=$(list_temp_sims | awk -F'\t' -v name="$name" '$3 == name' | head -n 1)

  if [ -n "$existing" ]; then
    DEVICE_UDID=$(echo "$existing" | cut -f1)
    echo "Reusing simulator: $name ($DEVICE_UDID)" >&2
  else
    local spec runtime_id type_id desc
    spec=$(pick_sim_spec) || exit 1
    runtime_id=$(echo "$spec" | cut -f1)
    type_id=$(echo "$spec" | cut -f2)
    desc=$(echo "$spec" | cut -f3)
    DEVICE_UDID=$(xcrun simctl create "$name" "$type_id" "$runtime_id") || {
      echo "Failed to create simulator '$name'." >&2
      exit 1
    }
    echo "Created simulator: $name ($desc) $DEVICE_UDID" >&2
  fi

  # bootstatus -b boots if needed and waits until the device is usable.
  if ! xcrun simctl bootstatus "$DEVICE_UDID" -b >/dev/null; then
    echo "Failed to boot simulator '$name'." >&2
    exit 1
  fi
}

delete_sim() {
  xcrun simctl shutdown "$1" >/dev/null 2>&1
  xcrun simctl delete "$1"
}

print_temp_sims() {
  local sims
  sims=$(list_temp_sims)
  if [ -z "$sims" ]; then
    echo "No simulators named ${SIM_PREFIX}*."
    return 0
  fi
  echo "$sims" | awk -F'\t' '{ printf "%-40s %s  %s\n", $3, $1, $2 }'
}

# Deletes one prefixed simulator by UDID, full name, or name without the
# prefix. Refuses anything outside the prefix so it can't remove a hand-made
# simulator.
delete_one_temp_sim() {
  local target="$1" match
  match=$(list_temp_sims | awk -F'\t' -v t="$target" -v p="$SIM_PREFIX" \
    '$1 == t || $3 == t || $3 == p t')
  if [ -z "$match" ]; then
    echo "No ${SIM_PREFIX}* simulator matches '$target'. Use --list-sims to see them." >&2
    return 1
  fi
  if [ "$(echo "$match" | wc -l | tr -d ' ')" -gt 1 ]; then
    echo "'$target' matches several simulators; pass a UDID instead:" >&2
    echo "$match" | awk -F'\t' '{ printf "  %s  %s\n", $3, $1 }' >&2
    return 1
  fi
  local udid name
  udid=$(echo "$match" | cut -f1)
  name=$(echo "$match" | cut -f3)
  if delete_sim "$udid"; then
    echo "Deleted: $name ($udid)"
  else
    echo "Failed to delete: $name ($udid)" >&2
    return 1
  fi
}

delete_all_temp_sims() {
  local sims
  sims=$(list_temp_sims)
  if [ -z "$sims" ]; then
    echo "No simulators named ${SIM_PREFIX}*."
    return 0
  fi

  local status=0 udid state name
  while IFS=$'\t' read -r udid state name; do
    if delete_sim "$udid"; then
      echo "Deleted: $name ($udid)"
    else
      echo "Failed to delete: $name ($udid)" >&2
      status=1
    fi
  done <<< "$sims"
  return $status
}

default_sim_name() {
  # The checkout directory name keeps worktrees from sharing a simulator.
  basename "$SCRIPT_DIR" | tr -c 'A-Za-z0-9._\n-' '-'
}

usage() {
  cat <<EOF
Usage: $0 [options]

Device selection (default: the single booted simulator, else a prompt):
  -d, --device <name>     Existing simulator by name (e.g. 'iPhone 16 Pro')
  -u, --udid <udid>       Existing simulator by UDID
      --temp-sim          Create a throwaway ${SIM_PREFIX}* simulator for this run
                          and delete it afterwards
      --keep-sim          Run on ${SIM_PREFIX}<sim-name>, creating and booting it if
                          needed, and leave it booted for later runs

Simulator management (no tests run):
      --create-sim        Create and boot ${SIM_PREFIX}<sim-name>, print its UDID, exit
      --list-sims         List every ${SIM_PREFIX}* simulator (name, UDID, state), exit
      --delete-sim <s>    Shut down and delete one ${SIM_PREFIX}* simulator, given by UDID,
                          full name, or name without the prefix, exit
      --delete-sims       Shut down and delete every ${SIM_PREFIX}* simulator, exit

Simulator options:
      --sim-name <name>   Suffix for --keep-sim / --create-sim
                          (default: checkout directory name, here '$(default_sim_name)')
      --device-type <t>   Device type name or identifier for new simulators
                          (default: '$PREFERRED_DEVICE_TYPE' when available, else newest iPhone)
      --runtime <r>       iOS runtime version, name or identifier for new simulators
                          (default: newest installed)

Run options:
  -a, --asan              Run under AddressSanitizer (-enableAddressSanitizer YES)
  -t, --temp-folder       Write results to a random temp folder instead of build/tests/<udid>
  -h, --help              Show this help

Results go to build/tests/<udid> (one simulator can only run one suite at a time).
EOF
}

die_usage() {
  echo "$1" >&2
  echo "Run '$0 --help' for usage." >&2
  exit 1
}

DEVICE_NAME=""
DEVICE_UDID=""
ASAN=0
TEMP_FOLDER=0
SIM_MODE=""
SIM_NAME=""
SIM_DEVICE_TYPE=""
SIM_RUNTIME=""
DELETE_TARGET=""
TEST_FOLDER=""

set_sim_mode() {
  if [ -n "$SIM_MODE" ] && [ "$SIM_MODE" != "$1" ]; then
    die_usage "--$SIM_MODE and --$1 cannot be combined."
  fi
  SIM_MODE="$1"
}

# Reads the value of an option given as "--opt value" or "--opt=value".
# Sets OPT_VALUE and OPT_SHIFT (how many args were consumed).
take_value() {
  local opt="$1" arg="$2" next="$3" has_next="$4"
  if [[ "$arg" == *=* ]]; then
    OPT_VALUE="${arg#*=}"
    OPT_SHIFT=1
  elif [ "$has_next" -eq 1 ]; then
    OPT_VALUE="$next"
    OPT_SHIFT=2
  else
    die_usage "$opt requires a value."
  fi
  [ -n "$OPT_VALUE" ] || die_usage "$opt requires a non-empty value."
}

while [ $# -gt 0 ]; do
  has_next=0
  [ $# -gt 1 ] && has_next=1
  case "$1" in
    -d|--device|--device=*)
      take_value "--device" "$1" "${2:-}" "$has_next"; DEVICE_NAME="$OPT_VALUE"; shift "$OPT_SHIFT" ;;
    -u|--udid|--udid=*)
      take_value "--udid" "$1" "${2:-}" "$has_next"; DEVICE_UDID="$OPT_VALUE"; shift "$OPT_SHIFT" ;;
    --sim-name|--sim-name=*)
      take_value "--sim-name" "$1" "${2:-}" "$has_next"; SIM_NAME="$OPT_VALUE"; shift "$OPT_SHIFT" ;;
    --device-type|--device-type=*)
      take_value "--device-type" "$1" "${2:-}" "$has_next"; SIM_DEVICE_TYPE="$OPT_VALUE"; shift "$OPT_SHIFT" ;;
    --runtime|--runtime=*)
      take_value "--runtime" "$1" "${2:-}" "$has_next"; SIM_RUNTIME="$OPT_VALUE"; shift "$OPT_SHIFT" ;;
    --temp-sim)    set_sim_mode "temp-sim"; shift ;;
    --keep-sim)    set_sim_mode "keep-sim"; shift ;;
    --create-sim)  set_sim_mode "create-sim"; shift ;;
    --delete-sim|--delete-sim=*)
      take_value "--delete-sim" "$1" "${2:-}" "$has_next"; DELETE_TARGET="$OPT_VALUE"
      set_sim_mode "delete-sim"; shift "$OPT_SHIFT" ;;
    --list-sims)   set_sim_mode "list-sims"; shift ;;
    --delete-sims) set_sim_mode "delete-sims"; shift ;;
    -a|--asan)        ASAN=1; shift ;;
    -t|--temp-folder) TEMP_FOLDER=1; shift ;;
    -h|--help)        usage; exit 0 ;;
    *) die_usage "Unknown argument: $1" ;;
  esac
done

if [ -n "$SIM_MODE" ] && { [ -n "$DEVICE_NAME" ] || [ -n "$DEVICE_UDID" ]; }; then
  die_usage "--$SIM_MODE cannot be combined with --device or --udid."
fi
if [ -n "$SIM_NAME" ] && [ "$SIM_MODE" != "keep-sim" ] && [ "$SIM_MODE" != "create-sim" ]; then
  die_usage "--sim-name only applies to --keep-sim and --create-sim."
fi
case "$SIM_MODE" in
  temp-sim|keep-sim|create-sim) CREATES_SIM=1 ;;
  *) CREATES_SIM=0 ;;
esac
if { [ -n "$SIM_DEVICE_TYPE" ] || [ -n "$SIM_RUNTIME" ]; } && [ "$CREATES_SIM" -eq 0 ]; then
  die_usage "--device-type and --runtime only apply when a simulator may be created."
fi
if [ -n "$SIM_MODE" ] && [ "$SIM_MODE" != "temp-sim" ] && [ "$SIM_MODE" != "keep-sim" ]; then
  if [ "$ASAN" -eq 1 ] || [ "$TEMP_FOLDER" -eq 1 ]; then
    die_usage "--asan and --temp-folder do not apply to --$SIM_MODE."
  fi
fi

sim_label() {
  local name
  name=$(xcrun simctl list devices --json 2>/dev/null | python3 -c "
import json, sys
for devices in json.load(sys.stdin)['devices'].values():
    for d in devices:
        if d['udid'] == sys.argv[1]:
            print(d['name'])
" "$1")
  echo "${name:-unknown} ($1)"
}

# Runs on every exit of a test run, including interrupts, so the last lines
# always say which simulator was used and whether it still exists.
finish_run() {
  local status=$?
  [ -n "$DEVICE_UDID" ] || exit "$status"
  local label disposition
  label=$(sim_label "$DEVICE_UDID")
  case "$SIM_MODE" in
    temp-sim)
      if delete_sim "$DEVICE_UDID"; then
        disposition="deleted (--temp-sim)"
      else
        disposition="DELETE FAILED, remove it with --delete-sim $DEVICE_UDID"
      fi
      ;;
    keep-sim)
      disposition="left booted for reuse (--keep-sim, or -u $DEVICE_UDID)"
      ;;
    *)
      disposition="existing simulator, left as is"
      ;;
  esac
  [ -n "$TEST_FOLDER" ] && echo "Test folder: $TEST_FOLDER"
  echo "Simulator: $label, $disposition"
  exit "$status"
}

case "$SIM_MODE" in
  list-sims)
    print_temp_sims
    exit $?
    ;;
  delete-sim)
    delete_one_temp_sim "$DELETE_TARGET"
    exit $?
    ;;
  delete-sims)
    delete_all_temp_sims
    exit $?
    ;;
  create-sim)
    ensure_sim "${SIM_PREFIX}${SIM_NAME:-$(default_sim_name)}"
    echo "$DEVICE_UDID"
    exit 0
    ;;
  keep-sim)
    ensure_sim "${SIM_PREFIX}${SIM_NAME:-$(default_sim_name)}"
    ;;
  temp-sim)
    # Installed before creation so an interrupt mid-boot still cleans up.
    trap finish_run EXIT
    trap 'exit 130' INT TERM
    ensure_sim "${SIM_PREFIX}run-$(date +%Y%m%d-%H%M%S)-$$"
    ;;
  *)
    if [ -z "$DEVICE_UDID" ]; then
      if [ -n "$DEVICE_NAME" ]; then
        resolve_device_name "$DEVICE_NAME"
      else
        select_device
      fi
    fi
    ;;
esac

trap finish_run EXIT
trap 'exit 130' INT TERM

DESTINATION="platform=iOS Simulator,id=$DEVICE_UDID"

mkdir -p "$TESTS_ROOT"
if [ "$TEMP_FOLDER" -eq 1 ]; then
  TEST_FOLDER=$(mktemp -d "$TESTS_ROOT/tmp.XXXXXXXX")
else
  TEST_FOLDER="$TESTS_ROOT/$DEVICE_UDID"
  rm -rf "$TEST_FOLDER"
  mkdir -p "$TEST_FOLDER"
fi

echo "Test folder: $TEST_FOLDER"

XCODEBUILD_ARGS=()
if [ "$ASAN" -eq 1 ]; then
  echo "AddressSanitizer: enabled"
  XCODEBUILD_ARGS+=(-enableAddressSanitizer YES)
fi

set -o pipefail
xcodebuild -project "$SCRIPT_DIR/v8ios.xcodeproj" -scheme TestRunner \
  -resultBundlePath "$TEST_FOLDER/test_results" \
  -destination "$DESTINATION" \
  "${XCODEBUILD_ARGS[@]}" \
  build test | xcpretty

TEST_EXIT=$?

if [ $TEST_EXIT -ne 0 ]; then
  echo "Tests failed with exit code $TEST_EXIT"
fi

if command -v xcparse &>/dev/null; then
  xcparse attachments "$TEST_FOLDER/test_results.xcresult" "$TEST_FOLDER/test-out"
  find "$TEST_FOLDER/test-out" -name "*junit*.xml" -maxdepth 1 -print0 | xargs -n 1 -0 npx junit-cli-report-viewer
  find "$TEST_FOLDER/test-out" -name "*junit*.xml" -maxdepth 1 -print0 | xargs -n 1 -0 npx verify-junit-xml
fi

exit $TEST_EXIT
