#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# frontend_requirements.sh
#
# Purpose:
#   - Minimal system update & readiness for an Ubuntu VM (for front-end usage).
#   - DOES NOT install Node.js or any framework. Just ensures a standard environment.
#   - Expects SUDO_PASS in the environment for non-interactive sudo.
###############################################################################

if [[ -z "${SUDO_PASS:-}" ]]; then
  echo "ERROR: SUDO_PASS not set. Cannot run sudo -S commands."
  exit 1
fi

echo "Running system update & upgrade..."
echo "$SUDO_PASS" | sudo -S apt-get update -y
echo "$SUDO_PASS" | sudo -S apt-get upgrade -y

echo "Installing basic packages (curl, wget, git, etc.)..."
echo "$SUDO_PASS" | sudo -S apt-get install -y curl wget git

echo "VM is now prepared for front-end usage (but no front-end tools installed)."
