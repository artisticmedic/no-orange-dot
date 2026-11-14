#!/bin/zsh
# Unit tests for the audio chain and the settings model, then the CLI against a throwaway settings folder.
set -euo pipefail
cd "${0:A:h}/.."
swift test "$@"
