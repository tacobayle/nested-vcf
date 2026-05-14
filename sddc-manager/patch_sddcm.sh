#!/usr/bin/env bash
# ssh_su_run.sh
# SSH into a host as a non-root user, su to a target user, then run commands.
# Requires: expect (brew install expect  /  apt install expect)

set -euo pipefail

# ---------------------------------------------------------------------------
# Defaults (can be overridden via env vars or flags)
# ---------------------------------------------------------------------------
SSH_USER="${SSH_USER:-}"        # non-root user for the SSH connection
SSH_PASSWORD="${SSH_PASSWORD:-}" # password for the SSH connection (leave empty to use key-based auth)
SSH_HOST="${SSH_HOST:-}"
SSH_PORT="${SSH_PORT:-22}"
SSH_KEY="${SSH_KEY:-}"          # optional path to private key (alternative to SSH_PASSWORD)
SU_USER="${SU_USER:-root}"      # user to su into (default: root)
SU_PASSWORD="${SU_PASSWORD:-}"  # password for SU_USER
TIMEOUT="${TIMEOUT:-240}"        # expect timeout in seconds

# Commands to run as SU_USER - edit this array or pass them via -c flags
ROOT_COMMANDS=(
    "echo 'feature.vcf.vgl-41078.alb.single.node.cluster=true' | tee /home/vcf/feature.properties"
    "printf 'y' | /opt/vmware/vcf/operationsmanager/scripts/cli/sddcmanager_restart_services.sh"
)

# ---------------------------------------------------------------------------
# Usage
# ---------------------------------------------------------------------------
usage() {
    cat <<EOF
Usage: $(basename "$0") -u SSH_USER -H HOST [OPTIONS]

SSH as SSH_USER to HOST, su to SU_USER (default: root), and run commands.

Options:
  -u SSH_USER   Non-root username for the SSH connection
  -P SSH_PASS   Password for the SSH connection (use -k for key-based auth instead)
  -s SU_USER    Username to su into (default: root)
  -r SU_PASS    Password for SU_USER (prompted securely if omitted)
  -H HOST       Target hostname or IP address
  -p PORT       SSH port (default: 22)
  -k KEY        Path to SSH private key (alternative to -P)
  -c CMD        Command to run as SU_USER (repeatable; overrides built-in list)
  -t TIMEOUT    Expect timeout in seconds (default: 30)
  -h            Show this help

Environment variables (alternative to flags):
  SSH_USER      Non-root username for SSH
  SSH_PASSWORD  Password for the SSH login (prompted if neither -P nor -k are set)
  SU_USER       Username to su into (default: root)
  SSH_HOST      Target host
  SSH_PORT      SSH port (default: 22)
  SSH_KEY       Path to SSH private key
  SU_PASSWORD   Password for SU_USER (prompted securely if not set)

Examples:
  # All credentials as flags:
  $(basename "$0") -u alice -P alicepass -r rootpass -H 192.168.1.10

  # Key-based SSH login, su to a specific user:
  $(basename "$0") -u alice -k ~/.ssh/id_ed25519 -s bob -r bobpass -H 192.168.1.10

  # All passwords from env vars, custom commands:
  SSH_PASSWORD=alicepass SU_PASSWORD=rootpass \\
    $(basename "$0") -u alice -H myserver -c "df -h" -c "free -m"
EOF
    exit 0
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
CUSTOM_CMDS=()

while getopts ":u:P:s:r:H:p:k:c:t:h" opt; do
    case $opt in
        u) SSH_USER="$OPTARG" ;;
        P) SSH_PASSWORD="$OPTARG" ;;
        s) SU_USER="$OPTARG" ;;
        r) SU_PASSWORD="$OPTARG" ;;
        H) SSH_HOST="$OPTARG" ;;
        p) SSH_PORT="$OPTARG" ;;
        k) SSH_KEY="$OPTARG" ;;
        c) CUSTOM_CMDS+=("$OPTARG") ;;
        t) TIMEOUT="$OPTARG" ;;
        h) usage ;;
        :) echo "ERROR: Option -$OPTARG requires an argument." >&2; exit 1 ;;
        \?) echo "ERROR: Unknown option -$OPTARG." >&2; exit 1 ;;
    esac
done

# Use custom commands if provided, otherwise fall back to built-in list
if [[ ${#CUSTOM_CMDS[@]} -gt 0 ]]; then
    ROOT_COMMANDS=("${CUSTOM_CMDS[@]}")
fi

# ---------------------------------------------------------------------------
# Validation
# ---------------------------------------------------------------------------
[[ -z "$SSH_USER" ]] && { echo "ERROR: SSH username is required (-u SSH_USER or SSH_USER=...)." >&2; exit 1; }
[[ -z "$SSH_HOST" ]] && { echo "ERROR: SSH host is required (-H HOST or SSH_HOST=...)." >&2; exit 1; }
[[ "$SSH_USER" == "$SU_USER" ]] && { echo "ERROR: SSH user and SU user must be different." >&2; exit 1; }
[[ -n "$SSH_KEY" && -n "$SSH_PASSWORD" ]] && { echo "ERROR: Use either -k (key) or -P (password) for SSH auth, not both." >&2; exit 1; }

if ! command -v expect &>/dev/null; then
    echo "ERROR: 'expect' is not installed." >&2
    echo "  macOS:  brew install expect" >&2
    echo "  Debian: sudo apt install expect" >&2
    echo "  RHEL:   sudo yum install expect" >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Prompt for SSH password if not using key-based auth
# ---------------------------------------------------------------------------
if [[ -z "$SSH_KEY" && -z "$SSH_PASSWORD" ]]; then
    echo -n "Enter SSH password for '${SSH_USER}' on ${SSH_HOST}: "
    read -rs SSH_PASSWORD
    echo
fi

# ---------------------------------------------------------------------------
# Prompt for SU_USER password if not already set
# ---------------------------------------------------------------------------
if [[ -z "$SU_PASSWORD" ]]; then
    echo -n "Enter password for '${SU_USER}' on ${SSH_HOST}: "
    read -rs SU_PASSWORD
    echo
fi

# ---------------------------------------------------------------------------
# Build SSH options
# ---------------------------------------------------------------------------
SSH_OPTS=(-p "$SSH_PORT" -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10)
[[ -n "$SSH_KEY" ]] && SSH_OPTS+=(-i "$SSH_KEY")

# ---------------------------------------------------------------------------
# Build the chain of commands to run as SU_USER
# ---------------------------------------------------------------------------
# Each command is separated by " && " so execution stops on the first failure.
COMMAND_CHAIN=""
for cmd in "${ROOT_COMMANDS[@]}"; do
    if [[ -z "$COMMAND_CHAIN" ]]; then
        COMMAND_CHAIN="$cmd"
    else
        COMMAND_CHAIN="$COMMAND_CHAIN && $cmd"
    fi
done
# Append exit so the su shell closes cleanly
COMMAND_CHAIN="$COMMAND_CHAIN; exit"

# ---------------------------------------------------------------------------
# Run via expect
# ---------------------------------------------------------------------------
echo "Connecting to ${SSH_USER}@${SSH_HOST}:${SSH_PORT} (will su to '${SU_USER}') ..."

expect -f - <<EXPECT_SCRIPT
set timeout $TIMEOUT

# Spawn SSH
spawn ssh ${SSH_OPTS[*]} ${SSH_USER}@${SSH_HOST}

# Handle host-key confirmation, SSH password prompt, and common SSH errors.
# Use a loose prompt match here - we normalize PS1 right after to get a
# predictable anchor (handles VMware VCF and other non-standard prompts).
expect {
    "yes/no"                  { send "yes\r"; exp_continue }
    "assword:"                { send "${SSH_PASSWORD}\r"; exp_continue }
    "denied"                  { puts stderr "ERROR: SSH authentication denied for '${SSH_USER}' (wrong password or key?)."; exit 1 }
    "No route to host"        { puts stderr "ERROR: No route to host '${SSH_HOST}' - check the IP address and network connectivity."; exit 1 }
    "Connection refused"      { puts stderr "ERROR: Connection refused on ${SSH_HOST}:${SSH_PORT} - is SSH running on that host?"; exit 1 }
    "Connection timed out"    { puts stderr "ERROR: Connection to ${SSH_HOST}:${SSH_PORT} timed out - host may be down or firewalled."; exit 1 }
    "Could not resolve"       { puts stderr "ERROR: Cannot resolve hostname '${SSH_HOST}' - check DNS or the hostname spelling."; exit 1 }
    "Host key verification"   { puts stderr "ERROR: Host key mismatch for '${SSH_HOST}' - run: ssh-keygen -R ${SSH_HOST}"; exit 1 }
    -re {[\$#>]}              { }
    timeout                   { puts stderr "ERROR: Timed out waiting for shell prompt (${TIMEOUT}s)."; exit 1 }
    eof                       { puts stderr "ERROR: SSH connection closed unexpectedly."; exit 1 }
}

# Replace the shell prompt with a known marker so subsequent matches are reliable
# regardless of the host's default PS1 (e.g. VMware VCF, custom bash configs).
send "export PS1='SSH_READY> '\r"
expect {
    "SSH_READY> "  { }
    timeout        { puts stderr "ERROR: Could not normalize shell prompt after SSH login."; exit 1 }
    eof            { puts stderr "ERROR: Connection closed while normalizing shell prompt."; exit 1 }
}

# Switch to SU_USER
send "su - ${SU_USER}\r"

expect {
    "Password:"   { send "${SU_PASSWORD}\r" }
    "assword:"    { send "${SU_PASSWORD}\r" }
    timeout       { puts stderr "ERROR: Timed out waiting for su password prompt."; exit 1 }
    eof           { puts stderr "ERROR: Connection closed before su prompt."; exit 1 }
}

# Wait for SU_USER shell - use a loose match first, then normalize PS1
expect {
    -re {[\$#>]}  { }
    "incorrect"   { puts stderr "ERROR: Incorrect password for '${SU_USER}'."; exit 1 }
    "failure"     { puts stderr "ERROR: su authentication failure."; exit 1 }
    timeout       { puts stderr "ERROR: Timed out waiting for '${SU_USER}' shell."; exit 1 }
    eof           { puts stderr "ERROR: Connection closed after su."; exit 1 }
}

# Normalize SU_USER prompt as well
send "export PS1='SU_READY> '\r"
expect {
    "SU_READY> "  { }
    timeout       { puts stderr "ERROR: Could not normalize shell prompt after su."; exit 1 }
    eof           { puts stderr "ERROR: Connection closed while normalizing su shell prompt."; exit 1 }
}

# Run commands (chain ends with '; exit' so the su shell closes cleanly)
send "${COMMAND_CHAIN}\r"

# After su exits we land back at the SSH shell (SSH_READY> prompt).
# Send exit there too so the SSH connection closes and we get eof.
expect {
    "SU_READY> "  { }
    "SSH_READY> " { send "exit\r"; expect eof; return }
    eof           { return }
    timeout       { puts stderr "ERROR: Timed out waiting for commands to finish."; exit 1 }
}

# su shell closed - now exit the SSH shell and wait for the connection to drop
send "exit\r"
expect {
    eof     { }
    timeout { puts stderr "ERROR: Timed out waiting for SSH session to close."; exit 1 }
}
EXPECT_SCRIPT

echo ""
echo "Done."