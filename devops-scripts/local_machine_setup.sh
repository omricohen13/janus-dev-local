#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# local_machine_setup.sh
#
# Purpose:
#   1) Validate environment (non-root, install Git + GH CLI if needed).
#   2) Configure global Git user.name/email.
#   3) Generate or reuse an ED25519 SSH key, skip if "already in use".
#   4) "gh auth login" if needed, handle "key is already in use" scenario.
#   5) Create a ~/janus-local folder, initialize a local Git repo, push to GitHub.
#
# Usage:
#   chmod +x local_machine_setup.sh
#   ./local_machine_setup.sh
#
# Notes:
#   - If a GitHub repo "janus-local" already exists, it prompts for a new name.
#   - If you already have an SSH key on GitHub, you can skip re-uploading it
#     when GH CLI prompts or you can back it up as needed.
###############################################################################

###############################
# 0. Validate & Helper Functions
###############################
if [[ $EUID -eq 0 ]]; then
  echo "ERROR: Running as root is discouraged. Exiting."
  exit 1
fi

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
      sudo apt-get update && sudo apt-get install -y "$pkg"
    else
      echo "ERROR: 'sudo' not found, cannot install '$pkg'."
      exit 1
    fi
  else
    echo "Cannot proceed without '$pkg'. Exiting."
    exit 1
  fi
}

###############################
# 1. Ensure Git + GH CLI
###############################
if ! command_exists git; then
  install_command_ubuntu "git"
fi

# GH CLI is optional until we want to create/push the new GitHub repo automatically.
# We'll check again later if user chooses to do so.

###############################
# 2. Configure global Git user.name & user.email
###############################
CURRENT_GIT_NAME="$(git config --global user.name || true)"
CURRENT_GIT_EMAIL="$(git config --global user.email || true)"

if [[ -z "$CURRENT_GIT_NAME" || -z "$CURRENT_GIT_EMAIL" ]]; then
  echo "Global Git user.name/email are not fully set."
  if prompt_yes_no "Configure them now?"; then
    if [[ -z "$CURRENT_GIT_NAME" ]]; then
      read -rp "Enter global Git user.name: " NEW_NAME
      if [[ -n "$NEW_NAME" ]]; then
        git config --global user.name "$NEW_NAME"
      fi
    fi
    if [[ -z "$CURRENT_GIT_EMAIL" ]]; then
      read -rp "Enter global Git user.email: " NEW_EMAIL
      if [[ -n "$NEW_EMAIL" ]]; then
        git config --global user.email "$NEW_EMAIL"
      fi
    fi
  else
    echo "WARNING: Without Git user.name/email, commits may fail or be anonymous."
  fi
fi

# Final check
CURRENT_GIT_NAME="$(git config --global user.name || true)"
CURRENT_GIT_EMAIL="$(git config --global user.email || true)"
if [[ -z "$CURRENT_GIT_NAME" || -z "$CURRENT_GIT_EMAIL" ]]; then
  echo "Still missing user.name/email. If commits fail, please set them manually."
fi

###############################
# 3. Generate (or reuse) ED25519 SSH key
###############################
SSH_DIR="$HOME/.ssh"
KEY_PATH="$SSH_DIR/id_ed25519"
PUB_PATH="$SSH_DIR/id_ed25519.pub"

if prompt_yes_no "Generate or reuse an ED25519 SSH key for GitHub?"; then
  mkdir -p "$SSH_DIR"
  chmod 700 "$SSH_DIR"

  if [[ -f "$KEY_PATH" && -f "$PUB_PATH" ]]; then
    echo "An ED25519 key pair already exists at:"
    echo "  $KEY_PATH"
    echo "  $PUB_PATH"
    if prompt_yes_no "Create a NEW ED25519 key? (existing one will be backed up)"; then
      BKP_SUFFIX=$(date +%Y%m%d_%H%M%S)
      mv "$KEY_PATH" "$KEY_PATH.bak_$BKP_SUFFIX"
      mv "$PUB_PATH" "$PUB_PATH.bak_$BKP_SUFFIX"
      echo "Backed up existing key to: $KEY_PATH.bak_$BKP_SUFFIX / $PUB_PATH.bak_$BKP_SUFFIX"

      read -rp "Enter a Title (comment) for the new SSH key (e.g., 'my-dev-key'): " KEY_COMMENT
      [[ -z "$KEY_COMMENT" ]] && KEY_COMMENT="default_comment"
      ssh-keygen -t ed25519 -C "$KEY_COMMENT" -f "$KEY_PATH" -N ""
      chmod 600 "$KEY_PATH" || true
      chmod 644 "$PUB_PATH" || true
      echo "New ED25519 key generated at: $KEY_PATH"
    else
      echo "Keeping the existing ED25519 key pair."
    fi
  else
    # No ED25519 key present, generate new
    read -rp "Enter a Title (comment) for the new SSH key (e.g., 'my-dev-key'): " KEY_COMMENT
    [[ -z "$KEY_COMMENT" ]] && KEY_COMMENT="default_comment"
    ssh-keygen -t ed25519 -C "$KEY_COMMENT" -f "$KEY_PATH" -N ""
    chmod 600 "$KEY_PATH"
    chmod 644 "$PUB_PATH"
    echo "Key generated at: $KEY_PATH"
  fi
else
  echo "Skipping SSH key creation step."
fi

###############################
# 4. (Optional) GH CLI Auth Flow
###############################
if prompt_yes_no "Do you want to create/push a new local Git repo to GitHub now?"; then
  # Ensure GH is installed if user wants to do a new repo
  if ! command_exists gh; then
    echo "GitHub CLI 'gh' is not installed."
    if prompt_yes_no "Install 'gh' now (Ubuntu/Debian)?"; then
      if command_exists sudo; then
        sudo apt-get update && sudo apt-get install -y gh
      else
        echo "ERROR: 'sudo' not found, cannot install 'gh'."
        exit 1
      fi
      if ! command_exists gh; then
        echo "ERROR: 'gh' still not found after install attempt. Aborting GH creation."
        exit 1
      fi
    else
      echo "Skipping 'gh' install. Aborting creation of new GitHub repo."
      exit 0
    fi
  fi

  # Check GH auth
  if ! gh auth status --hostname github.com &>/dev/null; then
    echo "You are not authenticated with GitHub CLI."
    if prompt_yes_no "Run 'gh auth login' now?"; then
      echo "Starting interactive GitHub CLI authentication..."
      # The user can skip uploading an existing key if GH says "key is already in use"
      # or they can choose to overwrite; that's part of 'gh auth login' flow.
      if ! gh auth login; then
        echo "ERROR: 'gh auth login' failed or was canceled."
        exit 1
      fi
    else
      echo "Skipping 'gh auth login'. Aborting GH repo creation."
      exit 0
    fi
    # re-check
    if ! gh auth status --hostname github.com &>/dev/null; then
      echo "ERROR: Still not authenticated. Aborting GH repo creation."
      exit 1
    fi
  fi

###############################
# 5. Create ~/janus-local & Push to GitHub
###############################
JANUS_DIR="$HOME/janus-local"
echo "Creating or verifying directory: $JANUS_DIR"
mkdir -p "$JANUS_DIR"
cd "$JANUS_DIR"

# If no .git, init repo
if [[ ! -d ".git" ]]; then
  echo "Initializing a local Git repo in $JANUS_DIR..."
  git init .
fi

# Ensure we have a main branch
CURRENT_BRANCH=$(git branch --show-current || true)
if [[ -z "$CURRENT_BRANCH" ]]; then
  git checkout -b main
elif [[ "$CURRENT_BRANCH" == "master" ]]; then
  git branch -m master main
fi

# Create minimal README if missing
if [[ ! -f "README.md" ]]; then
  cat <<EOF > README.md
# Janus Local

This is a local environment folder for development.
EOF
  git add README.md
  git commit -m "Initial commit with README" || true
fi

# If no commits exist, create an empty commit
if ! git show-ref --quiet --heads; then
  git commit --allow-empty -m "chore: empty commit for janus-local"
fi

###############################################################################
# Copy the current script into a "devops-scripts" folder before pushing
###############################################################################
mkdir -p devops-scripts

SCRIPT_BASENAME="$(basename "$0")"
TARGET_SCRIPT="devops-scripts/$SCRIPT_BASENAME"

# Copy this script if not already present (or always overwrite if you prefer)
if [[ -f "$TARGET_SCRIPT" ]]; then
  echo "Script '$SCRIPT_BASENAME' already exists in devops-scripts/. Overwriting..."
fi
cp "$0" "$TARGET_SCRIPT"

# Stage and commit if there's a change
if [[ -n "$(git status --porcelain devops-scripts)" ]]; then
  git add devops-scripts
  git commit -m "Add/Update local_machine_setup script in devops-scripts"
fi

###############################################################################
# Attempt GH repo creation
###############################################################################
REPO_NAME="janus-local"
while true; do
  echo "Creating a new GitHub repo '$REPO_NAME' from $JANUS_DIR..."
  # --public => you can change to --private if desired
  if gh repo create "$REPO_NAME" --public --source="." --remote="origin" --push; then
    echo "Successfully created & pushed to GitHub repo '$REPO_NAME'."
    break
  else
    echo "ERROR: Possibly the repo name '$REPO_NAME' already exists, or creation failed."
    read -rp "Enter a NEW GitHub repo name or press ENTER to cancel: " NEW_REPO
    if [[ -z "$NEW_REPO" ]]; then
      echo "Aborting GitHub repo creation."
      break
    else
      REPO_NAME="$NEW_REPO"
    fi
  fi
done

echo
echo "==========================================================="
echo "Local machine setup is complete!"
echo "You have SSH keys (if generated) and global Git config set."
echo "If you created a ~/janus-local repo, it's now on GitHub too."
echo "==========================================================="
