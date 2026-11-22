#!/bin/bash
# Fails unless the JS suite's junit reports show it ran under the expected
# wrapper lifetime mode and scope. The mode reaches the app through a build
# phase, so a passing suite alone does not prove which mode it exercised; the
# "Wrapper lifetime modes" suite names a spec after the mode the runtime read.
set -euo pipefail

usage() {
  echo "Usage: ./scripts/check-wrapper-lifetime-report.sh --reports <dir> --expect <mode>/<scope>"
  echo ""
  echo "  --reports <dir>   directory holding the suite's *junit*.xml reports"
  echo "  --expect <m>/<s>  mode and scope the suite must report, e.g. canary/all"
  echo "  -h, --help        show this help"
}

REPORTS=""
EXPECT=""
while [ $# -gt 0 ]; do
  case "$1" in
    --reports)
      [ $# -ge 2 ] || { echo "--reports needs a value" >&2; usage >&2; exit 1; }
      REPORTS="$2"
      shift 2
      ;;
    --reports=*) REPORTS="${1#*=}"; shift ;;
    --expect)
      [ $# -ge 2 ] || { echo "--expect needs a value" >&2; usage >&2; exit 1; }
      EXPECT="$2"
      shift 2
      ;;
    --expect=*) EXPECT="${1#*=}"; shift ;;
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

if [ -z "$REPORTS" ] || [ -z "$EXPECT" ]; then
  echo "--reports and --expect are required" >&2
  usage >&2
  exit 1
fi

REPORT_FILES=()
while IFS= read -r -d '' f; do
  REPORT_FILES+=("$f")
done < <(find "$REPORTS" -maxdepth 1 -name "*junit*.xml" -print0 2>/dev/null)

if [ "${#REPORT_FILES[@]}" -eq 0 ]; then
  echo "error: no *junit*.xml report in $REPORTS" >&2
  exit 1
fi

# Must match the spec title in TestRunner/app/tests/WrapperLifetimeModesTests.js.
NEEDLE="reports the configured mode and scope ($EXPECT)"
if grep -qF "$NEEDLE" "${REPORT_FILES[@]}"; then
  echo "Wrapper lifetime: suite ran under $EXPECT"
  exit 0
fi

echo "error: the suite did not report wrapper lifetime $EXPECT" >&2
FOUND=$(grep -ohE 'reports the configured mode and scope \([a-z]+/[a-z]+\)' "${REPORT_FILES[@]}" | sort -u || true)
echo "  reported: ${FOUND:-no wrapper lifetime mode spec in the reports}" >&2
exit 1
