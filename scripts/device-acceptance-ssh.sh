#!/bin/bash
# ACCEPT-002: bounded host-driven observer; use --help for SSH and evidence options.
set -euo pipefail
cd "$(dirname "$0")/.."
exec python3 tools/device_acceptance_ssh.py "$@"
