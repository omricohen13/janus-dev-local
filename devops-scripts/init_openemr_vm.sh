#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# init_openemr_vm.sh
#
# Purpose:
#   1) Create/update an "openemr-vm" folder under ~/janus-local.
#   2) Store remote VM credentials in openemr_config (excluded from Git).
#   3) Provide a minimal openemr_requirements.sh (system updates, basic packages).
#   4) Connect via password-based SSH => create ~/scripts on remote, run openemr_requirements.sh.
#   5) Commit & push changes to your GitHub repo (credentials ignored).
#
# Usage:
#   ./init_openemr_vm.sh
#
# Notes:
#   - Must not run as root (EUID != 0).
#   - Must have a valid git repo in ~/janus-local with remote on GitHub.
#   - This script doesn't install OpenEMR, only prepares the OS environment.
###############################################################################

###############################################################################
# 0. Preliminary Checks
###############################################################################
if [[ $EUID -eq 0 ]]; then
  echo "ERROR: Running as root is discouraged. Exiting."
  exit 1
fi

JANUS_LOCAL="$HOME/janus-local"
if [[ ! -d "$JANUS_LOCAL/.git" ]]; then
  echo "ERROR: $JANUS_LOCAL is not a Git repo or does not exist."
  echo "Please ensure you have a local Git repo in $JANUS_LOCAL pointing to GitHub."
  exit 1
fi

OPENEMR_DIR="$JANUS_LOCAL/openemr-vm"

###############################################################################
# Helper Functions
###############################################################################
prompt_yes_no() {
  local message="$1"
  read -rp "$message [y/N]: " ans
  if [[ "$ans" =~ ^[Yy]$ ]]; then
    return 0
  else
    return 1
  fi
}

command_exists() {
  command -v "$1" &>/dev/null
}

install_command_ubuntu() {
  local pkg="$1"
  echo "Command '$pkg' not found."
  if prompt_yes_no "Install '$pkg' now (Ubuntu/Debian)?"; then
    if command_exists sudo; then
      sudo apt-get update -y && sudo apt-get install -y "$pkg"
    else
      echo "ERROR: 'sudo' not available. Cannot install '$pkg'."
      exit 1
    fi
  else
    echo "Cannot proceed without '$pkg'. Exiting."
    exit 1
  fi
}

###############################################################################
# 1. Ensure 'sshpass' for password-based SSH
###############################################################################
if ! command_exists sshpass; then
  install_command_ubuntu "sshpass"
fi

###############################################################################
# 2. Create/Update openemr-vm folder, .gitignore, config
###############################################################################
echo "==============================================================="
echo "Setting up 'openemr-vm' folder in $JANUS_LOCAL: $OPENEMR_DIR"
mkdir -p "$OPENEMR_DIR"

# Add a local .gitignore ignoring 'openemr_config'
GITIGNORE_FILE="$OPENEMR_DIR/.gitignore"
if [[ ! -f "$GITIGNORE_FILE" ]]; then
  echo "Creating .gitignore in $OPENEMR_DIR to exclude openemr_config..."
  echo "openemr_config" >> "$GITIGNORE_FILE"
  echo "Created .gitignore ignoring 'openemr_config'."
else
  # Ensure 'openemr_config' is in the .gitignore if not already
  if ! grep -q "^openemr_config$" "$GITIGNORE_FILE"; then
    echo "openemr_config" >> "$GITIGNORE_FILE"
    echo "Added 'openemr_config' to existing .gitignore."
  fi
fi

# The config file
OPENEMR_CONFIG="$OPENEMR_DIR/openemr_config"

USE_EXISTING_CONFIG=false
if [[ -f "$OPENEMR_CONFIG" ]]; then
  echo "Found existing config at $OPENEMR_CONFIG."
  USE_EXISTING_CONFIG=true
  # shellcheck disable=SC1090
  source "$OPENEMR_CONFIG"
  echo "Loaded OpenEMR VM config: host=$OPENEMR_HOST user=$OPENEMR_USER"
else
  echo "No existing openemr_config found. We'll create one."
fi

if ! $USE_EXISTING_CONFIG; then
  read -rp "Enter OpenEMR VM IP/hostname: " OPENEMR_HOST
  read -rp "Enter SSH username for $OPENEMR_HOST: " OPENEMR_USER
  echo -n "Enter password for $OPENEMR_USER@$OPENEMR_HOST: "
  read -rs OPENEMR_PASS
  echo

  cat <<EOCFG > "$OPENEMR_CONFIG"
# OpenEMR VM config for password-based SSH
OPENEMR_HOST="$OPENEMR_HOST"
OPENEMR_USER="$OPENEMR_USER"
OPENEMR_PASS="$OPENEMR_PASS"
EOCFG

  echo "Saved config to $OPENEMR_CONFIG (excluded from Git by .gitignore)."
fi

###############################################################################
# 3. Overwrite (or prompt to overwrite) openemr_requirements.sh
###############################################################################
OPENEMR_REQ_SCRIPT="$OPENEMR_DIR/openemr_requirements.sh"

OVERWRITE_REQ_SCRIPT=false
if [[ -f "$OPENEMR_REQ_SCRIPT" ]]; then
  echo "Script '$OPENEMR_REQ_SCRIPT' already exists."
  if prompt_yes_no "Do you want to overwrite 'openemr_requirements.sh'?"; then
    OVERWRITE_REQ_SCRIPT=true
  fi
else
  OVERWRITE_REQ_SCRIPT=true
fi

if $OVERWRITE_REQ_SCRIPT; then
  cat <<'EOF' > "$OPENEMR_REQ_SCRIPT"
#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# openemr_requirements.sh
#
# Purpose:
#   - Minimal system update & readiness for an Ubuntu VM (for OpenEMR usage).
#   - DOES NOT install OpenEMR. Just ensures a standard environment.
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

echo "VM is now prepared for OpenEMR usage (but OpenEMR not installed)."
EOF

  chmod +x "$OPENEMR_REQ_SCRIPT"
  echo "Overwrote $OPENEMR_REQ_SCRIPT with updated sudo -S logic."
fi

###############################################################################
# 4. (Optional) Connect to Remote & Run
###############################################################################
if prompt_yes_no "Do you want to connect to $OPENEMR_HOST now and run openemr_requirements.sh?"; then
  echo "Creating remote ~/scripts folder on $OPENEMR_HOST..."
  sshpass -p "$OPENEMR_PASS" ssh -o StrictHostKeyChecking=accept-new "$OPENEMR_USER@$OPENEMR_HOST" "mkdir -p ~/scripts"
  echo "Remote folder created successfully at ~/scripts."

  if prompt_yes_no "Copy & run 'openemr_requirements.sh' on the remote VM now?"; then
    sshpass -p "$OPENEMR_PASS" scp -o StrictHostKeyChecking=accept-new "$OPENEMR_REQ_SCRIPT" "$OPENEMR_USER@$OPENEMR_HOST:~/scripts/openemr_requirements.sh"
    echo "Running 'openemr_requirements.sh' on $OPENEMR_HOST..."

    # Export SUDO_PASS on the remote so script can run 'sudo -S'
    sshpass -p "$OPENEMR_PASS" ssh -o StrictHostKeyChecking=accept-new "$OPENEMR_USER@$OPENEMR_HOST" \
      "export SUDO_PASS='$OPENEMR_PASS'; bash ~/scripts/openemr_requirements.sh"

    echo "'openemr_requirements.sh' execution completed on $OPENEMR_HOST."
  fi
else
  echo "Skipping remote provisioning step."
fi

###############################################################################
# 5. Commit & Push Changes to GitHub (Ignoring the config file)
###############################################################################
echo
echo "=== Committing & pushing changes to your janus-local GitHub repo ==="
cd "$JANUS_LOCAL"

# We never commit 'openemr_config' because .gitignore excludes it
git add "openemr-vm"

# Check if there's anything new (except the config file)
if [[ -n "$(git status --porcelain openemr-vm)" ]]; then
  git commit -m "Update openemr-vm folder with config & sudo -S fix (config ignored)"
  echo "Committed new/updated openemr-vm scripts."
else
  echo "No new changes to commit in openemr-vm."
fi

echo "Pushing to origin main..."
if ! git push origin main; then
  echo "Push to 'main' failed; trying 'master'..."
  if ! git push origin master; then
    echo "ERROR: push failed entirely. Check your branch/remote config."
    exit 1
  fi
fi

###############################################################################
# Done
###############################################################################
echo
echo "================================================================="
echo "All done! $OPENEMR_DIR has the config & openemr_requirements.sh."
echo "We've committed & pushed changes to your janus-local GitHub repo,"
echo "but 'openemr_config' is excluded by .gitignore."
echo "If chosen, the remote VM is updated with minimal packages (sudo -S logic)."
echo "Next time you run this script, it will reuse 'openemr_config'."
echo "================================================================="

