#!/bin/bash
# =============================================================================
# Agent RBAC Setup Script
# =============================================================================
# Creates a dedicated system for running agents with controlled permissions.
# Supports RBAC via Unix groups for read-only, operator, and deploy roles.
#
# Usage:
#   ./setup-agent.sh <username> <role> [ssh_key_path]
#
# Examples:
#   ./setup-agent.sh bolotas operator
#   ./setup-agent.sh bolotas operator ~/.ssh/id_ed25519.pub
#   ./setup-agent.sh readonly-agent readonly
# =============================================================================

set -euo pipefail

# Configuration
AGENT_HOME="/opt"
SSH_DIR="${AGENT_HOME}/.ssh"
AUTHORIZED_KEYS_FILE="${SSH_DIR}/authorized_keys"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# Usage function
usage() {
    cat <<EOF
Usage: $0 <username> <role> [ssh_key_path]

Arguments:
  username      - Name of the agent user to create
  role          - Role: readonly, operator, or deploy
  ssh_key_path  - Optional: Path to SSH public key to add

Roles:
  readonly   - Read logs, configs, docker ps, curl endpoints
  operator   - + restart services, docker restart, read /srv
  deploy     - + git pull, docker compose, rebuild

Examples:
  $0 bolotas operator
  $0 bolotas operator ~/.ssh/id_ed25519.pub
  $0 readonly-agent readonly

EOF
    exit 1
}

# Check if running as root
check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "This script must be run as root (use sudo)"
        exit 1
    fi
}

# Validate role
validate_role() {
    local role="$1"
    case "$role" in
        readonly|operator|deploy)
            return 0
            ;;
        *)
            log_error "Invalid role: $role"
            usage
            ;;
    esac
}

# Create groups
create_groups() {
    log_info "Creating agent groups..."

    # Create system groups if they don't exist
    for group in agents ops-agent deploy-agent; do
        if ! getent group "$group" >/dev/null 2>&1; then
            groupadd -r "$group"
            log_info "  Created group: $group"
        else
            log_info "  Group already exists: $group"
        fi
    done
}

# Determine group based on role
get_role_group() {
    local role="$1"
    case "$role" in
        readonly) echo "agents" ;;
        operator) echo "ops-agent" ;;
        deploy)   echo "deploy-agent" ;;
    esac
}

# Create agent user
create_user() {
    local username="$1"
    local role_group="$2"

    log_info "Creating user: $username"

    # Create user with home directory if not exists
    if ! id "$username" >/dev/null 2>&1; then
        useradd -r -m -d "$AGENT_HOME" -g "$role_group" -s /bin/bash "$username"
        log_info "  Created user: $username (group: $role_group)"
    else
        log_info "  User already exists: $username"
        # Add to role group if not already member
        usermod -aG "$role_group" "$username" 2>/dev/null || true
        log_info "  Added to group: $role_group"
    fi

    # Ensure home directory exists and has correct permissions
    mkdir -p "$AGENT_HOME"
    chown "${username}:${role_group}" "$AGENT_HOME"
    chmod 755 "$AGENT_HOME"
}

# Setup SSH access
setup_ssh() {
    local username="$1"
    local ssh_key_path="$2"

    # Create .ssh directory
    mkdir -p "$SSH_DIR"
    chown "${username}:${username}" "$SSH_DIR"
    chmod 700 "$SSH_DIR"

    # Add SSH key if provided
    if [[ -n "$ssh_key_path" ]]; then
        if [[ -f "$ssh_key_path" ]]; then
            cat "$ssh_key_path" >> "$AUTHORIZED_KEYS_FILE"
            chown "${username}:${username}" "$AUTHORIZED_KEYS_FILE"
            chmod 600 "$AUTHORIZED_KEYS_FILE"
            log_info "  Added SSH key: $ssh_key_path"
        else
            log_warn "  SSH key not found: $ssh_key_path"
        fi
    fi
}

# Configure sudoers for operator/deploy roles
configure_sudoers() {
    local role="$1"

    local sudoers_file="/etc/sudoers.d/agent-${role}"

    # Only operator and deploy get sudo access
    case "$role" in
        operator)
            cat > "$sudoers_file" <<'EOF'
# Agent operator role - can restart services and docker
%ops-agent ALL=(root) NOPASSWD: /bin/systemctl restart *
%ops-agent ALL=(root) NOPASSWD: /bin/systemctl stop *
%ops-agent ALL=(root) NOPASSWD: /bin/systemctl status *
%ops-agent ALL=(root) NOPASSWD: /bin/systemctl logs *
%ops-agent ALL=(root) NOPASSWD: /usr/bin/docker restart *
%ops-agent ALL=(root) NOPASSWD: /usr/bin/docker stop *
%ops-agent ALL=(root) NOPASSWD: /usr/bin/docker ps *
%ops-agent ALL=(root) NOPASSWD: /usr/bin/docker logs *
EOF
            chmod 440 "$sudoers_file"
            log_info "  Configured sudoers for operator role"
            ;;

        deploy)
            cat > "$sudoers_file" <<'EOF'
# Agent deploy role - can restart services, docker, and deploy
%deploy-agent ALL=(root) NOPASSWD: /bin/systemctl restart *
%deploy-agent ALL=(root) NOPASSWD: /bin/systemctl stop *
%deploy-agent ALL=(root) NOPASSWD: /bin/systemctl status *
%deploy-agent ALL=(root) NOPASSWD: /bin/systemctl logs *
%deploy-agent ALL=(root) NOPASSWD: /usr/bin/docker restart *
%deploy-agent ALL=(root) NOPASSWD: /usr/bin/docker stop *
%deploy-agent ALL=(root) NOPASSWD: /usr/bin/docker ps *
%deploy-agent ALL=(root) NOPASSWD: /usr/bin/docker logs *
%deploy-agent ALL=(root) NOPASSWD: /usr/bin/docker compose *
%deploy-agent ALL=(root) NOPASSWD: /usr/bin/docker build *
%deploy-agent ALL=(root) NOPASSWD: /usr/bin/git -C /srv/*
%deploy-agent ALL=(root) NOPASSWD: /usr/bin/git -C /opt/*
EOF
            chmod 440 "$sudoers_file"
            log_info "  Configured sudoers for deploy role"
            ;;
    esac
}

# Set filesystem permissions
setup_permissions() {
    local role="$1"

    log_info "Setting up filesystem permissions..."

    # Read-only areas (all agents can read)
    chgrp -R agents /srv/selfhost 2>/dev/null || true
    chmod -R 750 /srv/selfhost 2>/dev/null || true

    chgrp -R agents /var/log 2>/dev/null || true
    chmod -R 750 /var/log 2>/dev/null || true

    # Operator areas
    if [[ "$role" == "operator" ]] || [[ "$role" == "deploy" ]]; then
        chgrp -R ops-agent /etc/systemd 2>/dev/null || true
        chmod -R 640 /etc/systemd 2>/dev/null || true
    fi

    log_info "  Filesystem permissions configured"
}

# Main function
main() {
    # Check arguments
    if [[ $# -lt 2 ]]; then
        usage
    fi

    local username="$1"
    local role="$2"
    local ssh_key_path="${3:-}"

    # Validate inputs
    validate_role "$role"
    check_root

    log_info "Setting up agent user: $username with role: $role"
    echo ""

    # Create groups
    create_groups
    echo ""

    # Get the group for this role
    local role_group
    role_group=$(get_role_group "$role")

    # Create user
    create_user "$username" "$role_group"
    echo ""

    # Setup SSH
    if [[ -n "$ssh_key_path" ]]; then
        setup_ssh "$username" "$ssh_key_path"
        echo ""
    fi

    # Configure sudoers
    if [[ "$role" != "readonly" ]]; then
        configure_sudoers "$role"
        echo ""
    fi

    # Setup filesystem permissions
    setup_permissions "$role"
    echo ""

    log_info "Agent setup complete!"
    log_info ""
    log_info "User details:"
    log_info "  Username: $username"
    log_info "  Role: $role"
    log_info "  Group: $role_group"
    log_info "  Home: $AGENT_HOME"
    log_info ""
    log_info "SSH access: $([[ -n "$ssh_key_path" ]] && echo "Enabled" || echo "Not configured")"
    log_info "Sudo access: $([[ "$role" != "readonly" ]] && echo "Enabled for $role tasks" || echo "None (readonly)")"

    # Show SSH command
    if [[ -n "$ssh_key_path" ]]; then
        log_info ""
        log_info "To login: ssh ${username}@$(hostname -I | awk '{print $1}')"
    fi
}

# Run main
main "$@"
