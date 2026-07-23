#!/bin/bash
# CI-only: install the dependencies shared by the workflow build/test jobs.
# Invoked by the setup-build-env composite action (.github/actions/setup-build-env).
set -e

usage() {
  echo "Usage: ./scripts/install-ci-deps.sh [--test-tools]"
  echo ""
  echo "  --test-tools  also install xcparse and the JUnit report tools used by the"
  echo "                test jobs"
  echo "  -h, --help    show this help"
}

TEST_TOOLS=0
while [ $# -gt 0 ]; do
  case "$1" in
    --test-tools)
      TEST_TOOLS=1
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

npm install
python3 -m pip install --upgrade pip six

# Ensure CMake is available without conflicting with pinned Homebrew formula
if ! command -v cmake >/dev/null; then
  brew list cmake || brew install cmake
fi
# Some scripts expect cmake at /usr/local/bin; create a shim if needed
if [ ! -x /usr/local/bin/cmake ]; then
  sudo mkdir -p /usr/local/bin
  sudo ln -sf "$(command -v cmake)" /usr/local/bin/cmake
fi

if [ "$TEST_TOOLS" = "1" ]; then
  brew install chargepoint/xcparse/xcparse
  npm install -g @edusperoni/junit-cli-report-viewer verify-junit-xml
fi
