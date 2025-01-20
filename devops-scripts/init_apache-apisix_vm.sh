#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# init_apache-apisix_vm.sh
#
# Purpose:
#   1) Create/update an "apisix-vm" folder under ~/janus-local.
#   2) Store remote VM credentials in apisix_config (excluded from Git).
#   3) Provide a minimal apisix_requirements.sh (system updates, basic packages).
#   4) Connect via password-based SSH => create ~/scripts on remote,
#      run apisix_requirements.sh with sudo -S logic.
#   5) Commit & push changes to your GitHub repo (credentials ignored).
#
# Usage:
#   ./init_apache-apisix_vm.sh
#
# Notes:
#   - Must NOT run as root (EUID != 0).
#   - Must have a valid git repo in ~/janus-local with remote on GitHub.
#   - Does not install Apache APISIX—only minimal OS readiness.
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

APISIX_DIR="$JANUS_LOCAL/apisix-vm"

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
# 2. Create/Update apisix-vm folder, .gitignore, config
###############################################################################
echo "==============================================================="
echo "Setting up 'apisix-vm' folder in $JANUS_LOCAL: $APISIX_DIR"
mkdir -p "$APISIX_DIR"

# Add a local .gitignore ignoring 'apisix_config'
GITIGNORE_FILE="$APISIX_DIR/.gitignore"
if [[ ! -f "$GITIGNORE_FILE" ]]; then
  echo "Creating .gitignore in $APISIX_DIR to exclude apisix_config..."
  echo "apisix_config" >> "$GITIGNORE_FILE"
  echo "Created .gitignore ignoring 'apisix_config'."
else
  # Ensure 'apisix_config' is in the .gitignore if not already
  if ! grep -q "^apisix_config$" "$GITIGNORE_FILE"; then
    echo "apisix_config" >> "$GITIGNORE_FILE"
    echo "Added 'apisix_config' to existing .gitignore."
  fi
fi

# The config file
APISIX_CONFIG="$APISIX_DIR/apisix_config"

USE_EXISTING_CONFIG=false
if [[ -f "$APISIX_CONFIG" ]]; then
  echo "Found existing config at $APISIX_CONFIG."
  USE_EXISTING_CONFIG=true
  # shellcheck disable=SC1090
  source "$APISIX_CONFIG"
  echo "Loaded Apache APISIX VM config: host=$APISIX_HOST user=$APISIX_USER"
else
  echo "No existing apisix_config found. We'll create one."
fi

if ! $USE_EXISTING_CONFIG; then
  read -rp "Enter Apache APISIX VM IP/hostname: " APISIX_HOST
  read -rp "Enter SSH username for $APISIX_HOST: " APISIX_USER
  echo -n "Enter password for $APISIX_USER@$APISIX_HOST: "
  read -rs APISIX_PASS
  echo

  cat <<EOCFG > "$APISIX_CONFIG"
# Apache APISIX VM config for password-based SSH
APISIX_HOST="$APISIX_HOST"
APISIX_USER="$APISIX_USER"
APISIX_PASS="$APISIX_PASS"
EOCFG

  echo "Saved config to $APISIX_CONFIG (excluded from Git by .gitignore)."
fi

###############################################################################
# 3. Overwrite (or prompt to overwrite) apisix_requirements.sh
###############################################################################
APISIX_REQ_SCRIPT="$APISIX_DIR/apisix_requirements.sh"

OVERWRITE_REQ_SCRIPT=false
if [[ -f "$APISIX_REQ_SCRIPT" ]]; then
  echo "Script '$APISIX_REQ_SCRIPT' already exists."
  if prompt_yes_no "Do you want to overwrite 'apisix_requirements.sh'?"; then
    OVERWRITE_REQ_SCRIPT=true
  fi
else
  OVERWRITE_REQ_SCRIPT=true
fi

if $OVERWRITE_REQ_SCRIPT; then
  cat <<'EOF' > "$APISIX_REQ_SCRIPT"
#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# apisix_requirements.sh
#
# Purpose:
#   - Minimal system update & readiness for an Ubuntu VM (for Apache APISIX usage).
#   - DOES NOT install APISIX. Just ensures a standard environment.
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

echo "VM is now prepared for Apache APISIX usage (but APISIX not installed)."
EOF

  chmod +x "$APISIX_REQ_SCRIPT"
  echo "Overwrote $APISIX_REQ_SCRIPT with updated sudo -S logic."
fi

###############################################################################
# 4. (Optional) Connect to Remote & Run
###############################################################################
if prompt_yes_no "Do you want to connect to $APISIX_HOST now and run apisix_requirements.sh?"; then
  echo "Creating remote ~/scripts folder on $APISIX_HOST..."
  sshpass -p "$APISIX_PASS" ssh -o StrictHostKeyChecking=accept-new "$APISIX_USER@$APISIX_HOST" "mkdir -p ~/scripts"
  echo "Remote folder created successfully at ~/scripts."

  if prompt_yes_no "Copy & run 'apisix_requirements.sh' on the remote VM now?"; then
    sshpass -p "$APISIX_PASS" scp -o StrictHostKeyChecking=accept-new "$APISIX_REQ_SCRIPT" "$APISIX_USER@$APISIX_HOST:~/scripts/apisix_requirements.sh"
    echo "Running 'apisix_requirements.sh' on $APISIX_HOST..."

    # Export SUDO_PASS on the remote so script can run 'sudo -S'
    sshpass -p "$APISIX_PASS" ssh -o StrictHostKeyChecking=accept-new "$APISIX_USER@$APISIX_HOST" \
      "export SUDO_PASS='$APISIX_PASS'; bash ~/scripts/apisix_requirements.sh"

    echo "'apisix_requirements.sh' execution completed on $APISIX_HOST."
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

# We never commit 'apisix_config' because .gitignore excludes it
git add "apisix-vm"

# Check if there's anything new (except the config file)
if [[ -n "$(git status --porcelain apisix-vm)" ]]; then
  git commit -m "Update apisix-vm folder with config & sudo -S fix (config ignored)"
  echo "Committed new/updated apisix-vm scripts."
else
  echo "No new changes to commit in apisix-vm."
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
echo "All done! $APISIX_DIR has the config & apisix_requirements.sh."
echo "We've committed & pushed changes to your janus-local GitHub repo,"
echo "but 'apisix_config' is excluded by .gitignore."
echo "If chosen, the remote VM is updated with minimal packages (sudo -S logic)."
echo "Next time you run this script, it will reuse 'apisix_config'."
echo "================================================================="
