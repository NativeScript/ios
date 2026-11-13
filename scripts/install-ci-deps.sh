#!/bin/bash
# CI-only: install the dependencies shared by the workflow build/test jobs.
# Invoked by the setup-build-env composite action (.github/actions/setup-build-env).
set -e

usage() {
  echo "Usage: ./scripts/install-ci-deps.sh [--test-tools] [--ccache]"
  echo ""
  echo "  --test-tools  also install the JUnit report tools used by the test jobs"
  echo "  --ccache      also install ccache"
  echo "  -h, --help    show this help"
}

TEST_TOOLS=0
CCACHE=0
while [ $# -gt 0 ]; do
  case "$1" in
    --test-tools)
      TEST_TOOLS=1
      shift
      ;;
    --ccache)
      CCACHE=1
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
  npm install -g junit-cli-report-viewer@2.8.1 verify-junit-xml
fi

if [ "$CCACHE" = "1" ]; then
  HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_INSTALL_CLEANUP=1 brew install ccache
fi
