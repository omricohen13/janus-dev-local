#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# jenkins_install.sh
#
# Purpose:
#   A single "all-in-one" script to install Jenkins on an Ubuntu/Debian VM,
#   using password-based SSH (sshpass) and a local config file (jenkins_config).
#
# Local Steps:
#   1) Check we have ~/janus-local with a Git remote, not root, sshpass installed.
#   2) Read or prompt for jenkins_config (host, user, pass).
#   3) Copy THIS script to remote, run with --remote => actually install Jenkins.
#   4) Check if Jenkins is active; if yes, commit/push to GitHub, else warn.
#
# Remote Steps (run with --remote):
#   1) apt-get update & upgrade (keeps system fresh).
#   2) Install Java 11 (OpenJDK).
#   3) Add Jenkins apt repo & key, install Jenkins.
#   4) Enable & start Jenkins service.
#   5) If ufw is installed, allow 8080/tcp.
#   6) Return systemctl is-active jenkins to local script.
###############################################################################
###############################################################################
# If running with '--remote', we do the actual Jenkins installation on the VM
###############################################################################
if [[ "${1:-}" == "--remote" ]]; then
  if [[ -z "${SUDO_PASS:-}" ]]; then
    echo "ERROR: SUDO_PASS not set on remote. Cannot run sudo -S commands."
    exit 1
  fi

  # Helper for non-interactive sudo
  sudo_s() {
    echo "$SUDO_PASS" | sudo -S "$@"
  }

  echo "=== (REMOTE) 0) Updating & Upgrading the System ==="
  sudo_s apt-get update -y
  sudo_s apt-get upgrade -y

  echo "=== (REMOTE) 1) Installing Pre-Requisite Packages (for minimal base images) ==="
  # We ensure everything Jenkins + Java 21 needs, plus apt signing & other common tools:
  sudo_s apt-get install -y \
    gnupg2 \
    wget \
    curl \
    unzip \
    fontconfig \
    git \
    ca-certificates \
    ca-certificates-java \
    apt-transport-https \
    software-properties-common \
    lsb-release

  echo "=== (REMOTE) 1A) Adding PPA for OpenJDK 21 ==="
  # The PPA "openjdk-r/ppa" provides the latest releases of OpenJDK (21 in this case).
  # If your environment has a different PPA or your distro ships Java 21 natively, adjust here.
  sudo_s add-apt-repository -y ppa:openjdk-r/ppa
  sudo_s apt-get update -y

  echo "=== (REMOTE) 2) Installing OpenJDK 21 ==="
  sudo_s apt-get install -y openjdk-21-jdk

  echo "=== (REMOTE) 3) Adding Jenkins apt repo & GPG key (Signed-By approach) ==="
  # According to the official Jenkins docs for the LTS release on Debian/Ubuntu:
  #   1) Download the "2023" key into /usr/share/keyrings
  #   2) Reference with [signed-by=...] in apt source
  sudo_s mkdir -p /usr/share/keyrings

  sudo_s wget -O /usr/share/keyrings/jenkins-keyring.asc \
    https://pkg.jenkins.io/debian-stable/jenkins.io-2023.key

  if ! sudo_s test -s /usr/share/keyrings/jenkins-keyring.asc; then
    echo "ERROR: Jenkins 2023 GPG key is empty! Check network/firewall or key URL."
    exit 1
  fi

  # Ensure it’s world-readable so apt can read it
  sudo_s chmod a+r /usr/share/keyrings/jenkins-keyring.asc

  # Add Jenkins LTS repo referencing that key
  sudo_s sh -c 'echo "deb [signed-by=/usr/share/keyrings/jenkins-keyring.asc] https://pkg.jenkins.io/debian-stable binary/" > /etc/apt/sources.list.d/jenkins.list'

  echo "=== (REMOTE) 4) Installing Jenkins (LTS release) ==="
  sudo_s apt-get update -y
  sudo_s apt-get install -y jenkins

  # Optional: ensure Jenkins directories exist & correct ownership
  sudo_s mkdir -p /var/lib/jenkins
  sudo_s chown -R jenkins:jenkins /var/lib/jenkins
  sudo_s chmod 755 /var/lib/jenkins
  sudo_s mkdir -p /var/log/jenkins
  sudo_s chown -R jenkins:jenkins /var/log/jenkins
  sudo_s chmod 755 /var/log/jenkins

  echo "=== (REMOTE) 5) Enabling & starting Jenkins service ==="
  sudo_s systemctl daemon-reload
  sudo_s systemctl enable jenkins
  sudo_s systemctl start jenkins

  echo "=== (REMOTE) 6) Checking if ufw is installed to open 8080 ==="
  if command -v ufw &>/dev/null; then
    echo "Allowing 8080/tcp via ufw..."
    echo "$SUDO_PASS" | sudo -S ufw allow 8080/tcp || true
  else
    echo "WARNING: ufw not installed. If a firewall is active, port 8080 might be blocked externally."
  fi

  # Return Jenkins status to the local script
  systemctl is-active jenkins || true
  exit 0
fi

###############################################################################
# (LOCAL) Main Logic
###############################################################################
# 0) Basic checks
if [[ $EUID -eq 0 ]]; then
  echo "ERROR: Running as root locally is discouraged. Exiting."
  exit 1
fi

JANUS_LOCAL="$HOME/janus-local"
if [[ ! -d "$JANUS_LOCAL/.git" ]]; then
  echo "ERROR: $JANUS_LOCAL is not a Git repo or doesn't exist."
  echo "Please ensure you have a local Git repo in $JANUS_LOCAL pointing to GitHub."
  exit 1
fi

# We'll assume this script is in ~/janus-local/jenkins-vm, but it can be anywhere
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT_NAME="$(basename "$0")"

cd "$SCRIPT_DIR"

###############################################################################
# Helper for yes/no + ensuring sshpass
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

# Ensure sshpass is installed
if ! command_exists sshpass; then
  install_command_ubuntu "sshpass"
fi

###############################################################################
# 1) jenkins_config local usage
###############################################################################
JENKINS_CONFIG="$SCRIPT_DIR/jenkins_config"
USE_EXISTING_CONFIG=false

if [[ -f "$JENKINS_CONFIG" ]]; then
  echo "Found existing config: $JENKINS_CONFIG"
  USE_EXISTING_CONFIG=true
  # shellcheck disable=SC1090
  source "$JENKINS_CONFIG"
  echo "Loaded Jenkins VM => Host: $JENKINS_HOST, User: $JENKINS_USER"
else
  echo "No existing jenkins_config. We'll create one."
fi

if ! $USE_EXISTING_CONFIG; then
  read -rp "Enter Jenkins VM IP/hostname: " JENKINS_HOST
  read -rp "Enter SSH username for $JENKINS_HOST: " JENKINS_USER
  echo -n "Enter password for $JENKINS_USER@$JENKINS_HOST: "
  read -rs JENKINS_PASS
  echo

  cat <<EOCFG > "$JENKINS_CONFIG"
# Jenkins VM config (password-based SSH), ignored by Git
JENKINS_HOST="$JENKINS_HOST"
JENKINS_USER="$JENKINS_USER"
JENKINS_PASS="$JENKINS_PASS"
EOCFG

  echo "Saved config to $JENKINS_CONFIG"
  echo "Add 'jenkins_config' to .gitignore if not already."
fi

# Ensure .gitignore excludes jenkins_config
GITIGNORE_FILE="$SCRIPT_DIR/.gitignore"
if [[ ! -f "$GITIGNORE_FILE" ]]; then
  echo "Creating .gitignore in $SCRIPT_DIR ignoring jenkins_config..."
  echo "jenkins_config" > "$GITIGNORE_FILE"
else
  if ! grep -q "^jenkins_config$" "$GITIGNORE_FILE"; then
    echo "jenkins_config" >> "$GITIGNORE_FILE"
    echo "Added 'jenkins_config' to existing .gitignore."
  fi
fi


###############################################################################
# 2) Prompt to do Jenkins install
###############################################################################
if ! prompt_yes_no "Proceed with Jenkins installation on ${JENKINS_HOST:-<unset>}?"; then
  echo "User canceled Jenkins installation."
  exit 0
fi

if [[ -z "${JENKINS_PASS:-}" || -z "${JENKINS_USER:-}" || -z "${JENKINS_HOST:-}" ]]; then
  echo "ERROR: Jenkins config incomplete. Exiting."
  exit 1
fi

###############################################################################
# 3) Copy this script to remote & run with --remote
###############################################################################
echo "=== Copying this script ($SCRIPT_NAME) to remote for Jenkins install... ==="
sshpass -p "$JENKINS_PASS" scp -o StrictHostKeyChecking=accept-new "$SCRIPT_NAME" \
    "$JENKINS_USER@$JENKINS_HOST:~/jenkins_install_remote.sh"

echo "=== Running jenkins_install_remote.sh on $JENKINS_HOST with --remote flag ==="
sshpass -p "$JENKINS_PASS" ssh -o StrictHostKeyChecking=accept-new "$JENKINS_USER@$JENKINS_HOST" \
  "export SUDO_PASS='$JENKINS_PASS'; bash ~/jenkins_install_remote.sh --remote"

remote_exit=$?
if [[ $remote_exit -ne 0 ]]; then
  echo "ERROR: Remote install script failed with exit code $remote_exit"
  exit $remote_exit
fi

###############################################################################
# 4) Check Jenkins status on remote
###############################################################################
echo "=== Checking Jenkins status on $JENKINS_HOST... ==="
JENKINS_STATUS="$(sshpass -p "$JENKINS_PASS" ssh -o StrictHostKeyChecking=accept-new "$JENKINS_USER@$JENKINS_HOST" 'systemctl is-active jenkins || true')"

if [[ "$JENKINS_STATUS" == "active" ]]; then
  echo "Jenkins is active! We'll commit & push changes to GitHub."

  # Stage & push
  echo "=== Committing & pushing changes locally... ==="
  cd "$JANUS_LOCAL"
  # If this script is in jenkins-vm folder:
  if [[ "$SCRIPT_DIR" == "$JANUS_LOCAL"/jenkins-vm ]]; then
    git add "jenkins-vm"
  else
    # fallback, stage everything
    git add .
  fi

  if [[ -n "$(git status --porcelain)" ]]; then
    git commit -m "Jenkins installed successfully on $JENKINS_HOST (port 8080 allowed via ufw if available)"
    echo "Committed changes. Pushing..."
    if ! git push origin main; then
      echo "Push to 'main' failed; trying 'master'..."
      if ! git push origin master; then
        echo "ERROR: push failed entirely. Check your branch/remote."
        exit 1
      fi
    fi
    echo "Successfully pushed to GitHub!"
  else
    echo "No new changes to commit."
  fi

  echo
  echo "Jenkins installation complete & changes pushed!"
  echo "Access Jenkins at: http://${JENKINS_HOST}:8080"
  echo "Initial admin password in /var/lib/jenkins/secrets/initialAdminPassword"
else
  echo "WARNING: Jenkins not 'active' on $JENKINS_HOST. Check logs on the remote VM."
  echo "We won't push changes since Jenkins isn't running."
fi

echo "=== All done! ==="
