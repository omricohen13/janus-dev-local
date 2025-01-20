#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# init_jenkins_vm.sh
#
# Purpose:
#   1) Create/update a "jenkins-vm" folder under ~/janus-local (NOT in devops-scripts).
#   2) Use a config file (jenkins_config) to store Jenkins VM IP, user, password,
#      ignoring it via .gitignore so it's never committed.
#   3) Provide a jenkins_requirements.sh that uses SUDO_PASS for non-interactive sudo.
#   4) Connect via password-based SSH => create ~/scripts on remote, run jenkins_requirements.sh.
#   5) Commit & push changes to your GitHub repo, EXCEPT the config file.
#
# Usage:
#   ./init_jenkins_vm.sh
#
# Notes:
#   - Must not run as root (EUID != 0).
#   - Must have a valid Git repo in ~/janus-local with remote on GitHub.
#   - We add 'jenkins_config' to .gitignore so it won't be committed.
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

# We'll place jenkins-vm directly under janus-local:
JENKINS_DIR="$JANUS_LOCAL/jenkins-vm"

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
# 2. Create/Update jenkins-vm folder, .gitignore, config
###############################################################################
echo "==============================================================="
echo "Setting up 'jenkins-vm' folder in $JANUS_LOCAL: $JENKINS_DIR"
mkdir -p "$JENKINS_DIR"

# Add a local .gitignore ignoring 'jenkins_config'
GITIGNORE_FILE="$JENKINS_DIR/.gitignore"
if [[ ! -f "$GITIGNORE_FILE" ]]; then
  echo "Creating .gitignore in $JENKINS_DIR to exclude jenkins_config..."
  echo "jenkins_config" >> "$GITIGNORE_FILE"
  echo "Created .gitignore ignoring 'jenkins_config'."
else
  # Ensure 'jenkins_config' is in the .gitignore if not already
  if ! grep -q "^jenkins_config$" "$GITIGNORE_FILE"; then
    echo "jenkins_config" >> "$GITIGNORE_FILE"
    echo "Added 'jenkins_config' to existing .gitignore."
  fi
fi

# The config file
JENKINS_CONFIG="$JENKINS_DIR/jenkins_config"

USE_EXISTING_CONFIG=false
if [[ -f "$JENKINS_CONFIG" ]]; then
  echo "Found existing config at $JENKINS_CONFIG."
  USE_EXISTING_CONFIG=true
  # shellcheck disable=SC1090
  source "$JENKINS_CONFIG"
  echo "Loaded Jenkins VM config: host=$JENKINS_HOST user=$JENKINS_USER"
else
  echo "No existing jenkins_config found. We'll create one."
fi

if ! $USE_EXISTING_CONFIG; then
  read -rp "Enter Jenkins VM IP/hostname: " JENKINS_HOST
  read -rp "Enter SSH username for $JENKINS_HOST: " JENKINS_USER
  echo -n "Enter password for $JENKINS_USER@$JENKINS_HOST: "
  read -rs JENKINS_PASS
  echo

  cat <<EOCFG > "$JENKINS_CONFIG"
# Jenkins VM config for password-based SSH
JENKINS_HOST="$JENKINS_HOST"
JENKINS_USER="$JENKINS_USER"
JENKINS_PASS="$JENKINS_PASS"
EOCFG

  echo "Saved config to $JENKINS_CONFIG (excluded from Git by .gitignore)."
fi

###############################################################################
# 3. Overwrite (or prompt to overwrite) jenkins_requirements.sh
###############################################################################
JENKINS_REQ_SCRIPT="$JENKINS_DIR/jenkins_requirements.sh"

OVERWRITE_REQ_SCRIPT=false
if [[ -f "$JENKINS_REQ_SCRIPT" ]]; then
  echo "Script '$JENKINS_REQ_SCRIPT' already exists."
  if prompt_yes_no "Do you want to overwrite 'jenkins_requirements.sh'?"; then
    OVERWRITE_REQ_SCRIPT=true
  fi
else
  OVERWRITE_REQ_SCRIPT=true
fi

if $OVERWRITE_REQ_SCRIPT; then
  cat <<'EOF' > "$JENKINS_REQ_SCRIPT"
#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# jenkins_requirements.sh
#
# Purpose:
#   - Minimal system update & readiness for an Ubuntu VM (for Jenkins usage).
#   - DOES NOT install Jenkins. Just ensures a standard environment.
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

echo "VM is now prepared for Jenkins usage (but Jenkins not installed)."
EOF

  chmod +x "$JENKINS_REQ_SCRIPT"
  echo "Overwrote $JENKINS_REQ_SCRIPT with updated sudo -S logic."
fi

###############################################################################
# 4. (Optional) Connect to Remote & Run
###############################################################################
if prompt_yes_no "Do you want to connect to $JENKINS_HOST now and run jenkins_requirements.sh?"; then
  echo "Creating remote ~/scripts folder on $JENKINS_HOST..."
  sshpass -p "$JENKINS_PASS" ssh -o StrictHostKeyChecking=accept-new "$JENKINS_USER@$JENKINS_HOST" "mkdir -p ~/scripts"
  echo "Remote folder created successfully at ~/scripts."

  if prompt_yes_no "Copy & run 'jenkins_requirements.sh' on the remote VM now?"; then
    sshpass -p "$JENKINS_PASS" scp -o StrictHostKeyChecking=accept-new "$JENKINS_REQ_SCRIPT" "$JENKINS_USER@$JENKINS_HOST:~/scripts/jenkins_requirements.sh"
    echo "Running 'jenkins_requirements.sh' on $JENKINS_HOST..."

    # Export SUDO_PASS on the remote so script can run 'sudo -S'
    sshpass -p "$JENKINS_PASS" ssh -o StrictHostKeyChecking=accept-new "$JENKINS_USER@$JENKINS_HOST" \
      "export SUDO_PASS='$JENKINS_PASS'; bash ~/scripts/jenkins_requirements.sh"

    echo "'jenkins_requirements.sh' execution completed on $JENKINS_HOST."
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

# We never commit 'jenkins_config' because .gitignore excludes it
git add "jenkins-vm"

# Check if there's anything new (except the config file)
if [[ -n "$(git status --porcelain jenkins-vm)" ]]; then
  git commit -m "Update jenkins-vm folder with config & sudo -S fix (config ignored)"
  echo "Committed new/updated jenkins-vm scripts."
else
  echo "No new changes to commit in jenkins-vm."
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
echo "All done! $JENKINS_DIR has the config & jenkins_requirements.sh."
echo "We've committed & pushed changes to your janus-local GitHub repo,"
echo "but 'jenkins_config' is excluded by .gitignore."
echo "If chosen, the remote VM is updated with minimal packages (sudo -S logic)."
echo "Next time you run this script, it will reuse 'jenkins_config'."
echo "================================================================="
