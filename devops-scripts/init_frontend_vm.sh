#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# init_frontend_vm.sh
#
# Purpose:
#   1) Create/update a "frontend-vm" folder under ~/janus-local.
#   2) Use a config file (frontend_config) to store remote VM IP, user, password,
#      ignoring it via .gitignore so it's never committed.
#   3) Provide a "frontend_requirements.sh" for minimal system updates.
#   4) Connect via password-based SSH => create ~/scripts on remote, run
#      frontend_requirements.sh with sudo -S (non-interactive).
#   5) Commit & push changes to GitHub (credentials ignored).
#
# Usage:
#   ./init_frontend_vm.sh
#
# Notes:
#   - Must not run as root (EUID != 0).
#   - Must have a valid git repo in ~/janus-local with remote on GitHub.
#   - This script doesn't install front-end tools, only does minimal environment setup.
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

FRONTEND_DIR="$JANUS_LOCAL/frontend-vm"

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
# 2. Create/Update frontend-vm folder, .gitignore, config
###############################################################################
echo "==============================================================="
echo "Setting up 'frontend-vm' folder in $JANUS_LOCAL: $FRONTEND_DIR"
mkdir -p "$FRONTEND_DIR"

# Add a local .gitignore ignoring 'frontend_config'
GITIGNORE_FILE="$FRONTEND_DIR/.gitignore"
if [[ ! -f "$GITIGNORE_FILE" ]]; then
  echo "Creating .gitignore in $FRONTEND_DIR to exclude frontend_config..."
  echo "frontend_config" >> "$GITIGNORE_FILE"
  echo "Created .gitignore ignoring 'frontend_config'."
else
  # Ensure 'frontend_config' is in the .gitignore if not already
  if ! grep -q "^frontend_config$" "$GITIGNORE_FILE"; then
    echo "frontend_config" >> "$GITIGNORE_FILE"
    echo "Added 'frontend_config' to existing .gitignore."
  fi
fi

# The config file
FRONTEND_CONFIG="$FRONTEND_DIR/frontend_config"

USE_EXISTING_CONFIG=false
if [[ -f "$FRONTEND_CONFIG" ]]; then
  echo "Found existing config at $FRONTEND_CONFIG."
  USE_EXISTING_CONFIG=true
  # shellcheck disable=SC1090
  source "$FRONTEND_CONFIG"
  echo "Loaded Frontend VM config: host=$FRONTEND_HOST user=$FRONTEND_USER"
else
  echo "No existing frontend_config found. We'll create one."
fi

if ! $USE_EXISTING_CONFIG; then
  read -rp "Enter Frontend VM IP/hostname: " FRONTEND_HOST
  read -rp "Enter SSH username for $FRONTEND_HOST: " FRONTEND_USER
  echo -n "Enter password for $FRONTEND_USER@$FRONTEND_HOST: "
  read -rs FRONTEND_PASS
  echo

  cat <<EOCFG > "$FRONTEND_CONFIG"
# Frontend VM config for password-based SSH
FRONTEND_HOST="$FRONTEND_HOST"
FRONTEND_USER="$FRONTEND_USER"
FRONTEND_PASS="$FRONTEND_PASS"
EOCFG

  echo "Saved config to $FRONTEND_CONFIG (excluded from Git by .gitignore)."
fi

###############################################################################
# 3. Overwrite (or prompt to overwrite) frontend_requirements.sh
###############################################################################
FRONTEND_REQ_SCRIPT="$FRONTEND_DIR/frontend_requirements.sh"

OVERWRITE_REQ_SCRIPT=false
if [[ -f "$FRONTEND_REQ_SCRIPT" ]]; then
  echo "Script '$FRONTEND_REQ_SCRIPT' already exists."
  if prompt_yes_no "Do you want to overwrite 'frontend_requirements.sh'?"; then
    OVERWRITE_REQ_SCRIPT=true
  fi
else
  OVERWRITE_REQ_SCRIPT=true
fi

if $OVERWRITE_REQ_SCRIPT; then
  cat <<'EOF' > "$FRONTEND_REQ_SCRIPT"
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
EOF

  chmod +x "$FRONTEND_REQ_SCRIPT"
  echo "Overwrote $FRONTEND_REQ_SCRIPT with updated sudo -S logic."
fi

###############################################################################
# 4. (Optional) Connect to Remote & Run
###############################################################################
if prompt_yes_no "Do you want to connect to $FRONTEND_HOST now and run frontend_requirements.sh?"; then
  echo "Creating remote ~/scripts folder on $FRONTEND_HOST..."
  sshpass -p "$FRONTEND_PASS" ssh -o StrictHostKeyChecking=accept-new "$FRONTEND_USER@$FRONTEND_HOST" "mkdir -p ~/scripts"
  echo "Remote folder created successfully at ~/scripts."

  if prompt_yes_no "Copy & run 'frontend_requirements.sh' on the remote VM now?"; then
    sshpass -p "$FRONTEND_PASS" scp -o StrictHostKeyChecking=accept-new "$FRONTEND_REQ_SCRIPT" "$FRONTEND_USER@$FRONTEND_HOST:~/scripts/frontend_requirements.sh"
    echo "Running 'frontend_requirements.sh' on $FRONTEND_HOST..."

    # Export SUDO_PASS on the remote so script can run 'sudo -S'
    sshpass -p "$FRONTEND_PASS" ssh -o StrictHostKeyChecking=accept-new "$FRONTEND_USER@$FRONTEND_HOST" \
      "export SUDO_PASS='$FRONTEND_PASS'; bash ~/scripts/frontend_requirements.sh"

    echo "'frontend_requirements.sh' execution completed on $FRONTEND_HOST."
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

# We never commit 'frontend_config' because .gitignore excludes it
git add "frontend-vm"

# Check if there's anything new (except the config file)
if [[ -n "$(git status --porcelain frontend-vm)" ]]; then
  git commit -m "Update frontend-vm folder with config & sudo -S fix (config ignored)"
  echo "Committed new/updated frontend-vm scripts."
else
  echo "No new changes to commit in frontend-vm."
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
echo "All done! $FRONTEND_DIR has the config & frontend_requirements.sh."
echo "We've committed & pushed changes to your janus-local GitHub repo,"
echo "but 'frontend_config' is excluded by .gitignore."
echo "If chosen, the remote VM is updated with minimal packages (sudo -S logic)."
echo "Next time you run this script, it will reuse 'frontend_config'."
echo "================================================================="
