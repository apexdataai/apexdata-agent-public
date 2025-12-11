#!/bin/bash

# ApexData Agent Service Manager
# Manages systemd service for apexdata-agent

set -e

SERVICE_NAME="apexdata-agent"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
BINARY_PATH="/usr/local/bin/${SERVICE_NAME}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

print_status() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        print_error "This script must be run as root (use sudo)"
        exit 1
    fi
}

check_binary() {
    if [[ ! -f "./${SERVICE_NAME}" ]]; then
        print_error "Binary './${SERVICE_NAME}' not found in current directory"
        exit 1
    fi
}

check_dependencies() {
    print_status "Checking system dependencies..."
    
    local missing_packages=()
    local all_packages=("libsystemd-dev" "gcc" "build-essential")
    
    # Check if packages are installed
    for package in "${all_packages[@]}"; do
        if ! dpkg -l | grep -q "^ii  $package"; then
            missing_packages+=("$package")
        fi
    done
    
    if [[ ${#missing_packages[@]} -eq 0 ]]; then
        print_success "All required dependencies are installed"
        return 0
    fi
    
    # Some packages are missing - exit with clear instructions
    print_error "The following required packages are missing:"
    for package in "${missing_packages[@]}"; do
        echo "  - $package"
    done
    
    echo ""
    print_warning "IMPORTANT: Dependencies must be installed manually before running this script."
    print_warning "Automatic installation is disabled to prevent unexpected system updates and service restarts."
    echo ""
    echo "Please install the missing packages manually using:"
    echo "  sudo apt update"
    echo "  sudo apt install -y --fix-missing ${missing_packages[*]}"
    echo ""
    echo "After installing dependencies, run this script again."
    echo ""
    print_error "Cannot proceed without required dependencies"
    exit 1
}

install_service() {
    print_status "Installing ApexData Agent Service..."
    
    # Warn if script path looks suspicious
    if [[ "$0" == "/bin/bash" ]] || [[ "$0" == "bash" ]]; then
        print_warning "Script may have been run incorrectly"
        print_warning "Use: sudo ./install-single-host.sh install"
        print_warning "NOT: sudo /bin/bash install-single-host.sh install"
        echo ""
    fi
    
    check_binary
    check_dependencies
    
    # Get configuration from user
    echo ""
    echo "=== Service Configuration ==="
    read -p "Enter client name (e.g., oteldemo): " CLIENT_NAME
    
    # Validate client name
    if [[ -z "$CLIENT_NAME" ]]; then
        print_error "Client name cannot be empty"
        exit 1
    fi
    
    # Build full endpoint from client name
    ENDPOINT="${CLIENT_NAME}.collector.eu.apexdata.ai:444"
    AUTH_USERNAME="$CLIENT_NAME"
    
    print_status "Using endpoint: $ENDPOINT"
    print_status "Using username: $AUTH_USERNAME"
    
    echo ""
    echo "Authentication credentials (for Basic Auth):"
    read -sp "Enter password for user '$AUTH_USERNAME': " AUTH_PASSWORD
    echo ""
    
    # Generate Base64 token from username:password
    AUTH_TOKEN=$(echo -n "${AUTH_USERNAME}:${AUTH_PASSWORD}" | base64)
    
    read -p "Enter node name [$(hostname)]: " NODE_NAME
    NODE_NAME=${NODE_NAME:-$(hostname)}
    
    # Optional monitoring endpoints
    echo ""
    echo "=== Optional Monitoring Configuration ==="
    read -p "Enter Redis address (e.g., 127.0.0.1:6379, leave empty to skip): " REDIS_ADDRESS
    read -p "Enter PHP-FPM status URL (e.g., https://example.com/fpm-status, leave empty to skip): " PHPFPM_STATUS_URL
    read -p "Enter MySQL DSN (e.g., user:password@tcp(127.0.0.1:3306), leave empty to skip): " MYSQL_DSN
    
    # Validate password
    if [[ -z "$AUTH_PASSWORD" ]]; then
        print_error "Password cannot be empty"
        exit 1
    fi
    
    # Copy binary
    cp "./${SERVICE_NAME}" "$BINARY_PATH"
    chmod +x "$BINARY_PATH"
    print_success "Binary installed to $BINARY_PATH"
    
    # Build ExecStart command with all values directly (no environment variables)
    # Note: quotes around header value to properly handle the space between "Basic" and token
    EXEC_START="$BINARY_PATH --resources=pods --node=$NODE_NAME --otel-protocol=grpc --otel-headers=\"authorization=Basic $AUTH_TOKEN\" --endpoint=$ENDPOINT"
    
    if [[ -n "$REDIS_ADDRESS" ]]; then
        EXEC_START="$EXEC_START --redis-address=$REDIS_ADDRESS"
    fi
    
    if [[ -n "$PHPFPM_STATUS_URL" ]]; then
        EXEC_START="$EXEC_START --phpfpm-status-url=$PHPFPM_STATUS_URL"
    fi
    
    if [[ -n "$MYSQL_DSN" ]]; then
        EXEC_START="$EXEC_START --mysql-dsn=$MYSQL_DSN"
    fi
    
    print_status "Configuring service parameters..."
    print_status "Node: $NODE_NAME"
    print_status "Endpoint: $ENDPOINT"
    
    # Create systemd service file
    cat > "$SERVICE_FILE" << EOF
[Unit]
Description=ApexData Agent - Kubernetes and System Metrics Collector
Documentation=https://apexdata.ai
After=network.target
Wants=network.target

[Service]
Type=simple
User=root
Group=root
ExecStart=$EXEC_START
Environment=NO_K8S=true
Environment=K8S_COLLECTOR_ENABLED=false
Restart=always
RestartSec=10
StandardOutput=journal
StandardError=journal
SyslogIdentifier=apexdata-agent

# Security settings
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=/tmp /var/log

# Resource limits
LimitNOFILE=65536
LimitNPROC=4096

[Install]
WantedBy=multi-user.target
EOF

    print_success "Service file configured at $SERVICE_FILE"
    
    # Reload systemd and enable service
    systemctl daemon-reload
    systemctl enable "$SERVICE_NAME"
    
    print_success "Service installed and enabled"
    print_status "Use 'sudo $0 start' to start the service"
}

uninstall_service() {
    print_status "Uninstalling ApexData Agent Service..."
    
    # Stop and disable service
    if systemctl is-active --quiet "$SERVICE_NAME"; then
        systemctl stop "$SERVICE_NAME"
        print_success "Service stopped"
    fi
    
    if systemctl is-enabled --quiet "$SERVICE_NAME" 2>/dev/null; then
        systemctl disable "$SERVICE_NAME"
        print_success "Service disabled"
    fi
    
    # Remove files
    [[ -f "$SERVICE_FILE" ]] && rm -f "$SERVICE_FILE" && print_success "Service file removed"
    [[ -f "$BINARY_PATH" ]] && rm -f "$BINARY_PATH" && print_success "Binary removed"
    
    # Reload systemd
    systemctl daemon-reload
    
    print_success "Service uninstalled completely"
}

start_service() {
    print_status "Starting ApexData Agent Service..."
    systemctl start "$SERVICE_NAME"
    print_success "Service started"
    show_status
}

stop_service() {
    print_status "Stopping ApexData Agent Service..."
    systemctl stop "$SERVICE_NAME"
    print_success "Service stopped"
}

restart_service() {
    print_status "Restarting ApexData Agent Service..."
    systemctl restart "$SERVICE_NAME"
    print_success "Service restarted"
    show_status
}

update_service() {
    print_status "Updating ApexData Agent Service..."
    
    # Check if service is installed
    if [[ ! -f "$SERVICE_FILE" ]]; then
        print_error "Service is not installed. Please run 'install' first."
        exit 1
    fi
    
    # Stop the service
    if systemctl is-active --quiet "$SERVICE_NAME"; then
        print_status "Stopping service..."
        systemctl stop "$SERVICE_NAME"
        print_success "Service stopped"
    else
        print_status "Service is already stopped"
    fi
    
    # Get the script directory (repository root)
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    
    # Change to repository directory and reset to origin/main
    print_status "Updating repository to origin/main..."
    cd "$SCRIPT_DIR"
    
    if ! git rev-parse --git-dir > /dev/null 2>&1; then
        print_error "Not a git repository. Cannot perform git reset."
        exit 1
    fi
    
    git fetch origin main || {
        print_error "Failed to fetch from origin/main"
        exit 1
    }
    
    git reset --hard origin/main || {
        print_error "Failed to reset to origin/main"
        exit 1
    }
    
    print_success "Repository updated to origin/main"
    
    # Check if binary exists after reset
    if [[ ! -f "./${SERVICE_NAME}" ]]; then
        print_error "Binary './${SERVICE_NAME}' not found after git reset"
        exit 1
    fi
    
    # Copy binary to the same path as used in install
    print_status "Copying binary to $BINARY_PATH..."
    cp "./${SERVICE_NAME}" "$BINARY_PATH"
    chmod +x "$BINARY_PATH"
    print_success "Binary updated at $BINARY_PATH"
    
    # Restart the service
    print_status "Restarting service..."
    systemctl start "$SERVICE_NAME"
    print_success "Service restarted"
    show_status
}

show_status() {
    echo ""
    echo "=== Service Status ==="
    systemctl status "$SERVICE_NAME" --no-pager -l
}

show_logs() {
    echo ""
    echo "=== Service Logs (last 50 lines) ==="
    journalctl -u "$SERVICE_NAME" -n 50 --no-pager
}

show_help() {
    echo "ApexData Agent Service Manager"
    echo ""
    echo "Usage: sudo ./install-single-host.sh <command>"
    echo ""
    echo "⚠️  IMPORTANT: Run the script using './' or full path, NOT '/bin/bash'"
    echo "   Correct:   sudo ./install-single-host.sh install"
    echo "   Incorrect: sudo /bin/bash install-single-host.sh install"
    echo ""
    echo "Commands:"
    echo "  install    - Install and configure the service"
    echo "  update     - Update binary from git (stop, git reset --hard origin/main, copy, restart)"
    echo "  uninstall  - Remove the service completely"
    echo "  start      - Start the service"
    echo "  stop       - Stop the service"
    echo "  restart    - Restart the service"
    echo "  status     - Show service status"
    echo "  logs       - Show service logs"
    echo "  help       - Show this help message"
    echo ""
    echo "Examples:"
    echo "  sudo ./install-single-host.sh install"
    echo "  sudo ./install-single-host.sh start"
    echo "  ./install-single-host.sh logs"
    echo ""
    echo "Note: To update configuration, run 'uninstall' then 'install' again"
}

# Main script logic
case "${1:-}" in
    install)
        check_root
        install_service
        ;;
    update)
        check_root
        update_service
        ;;
    uninstall)
        check_root
        uninstall_service
        ;;
    start)
        check_root
        start_service
        ;;
    stop)
        check_root
        stop_service
        ;;
    restart)
        check_root
        restart_service
        ;;
    status)
        show_status
        ;;
    logs)
        show_logs
        ;;
    help|--help|-h)
        show_help
        ;;
    *)
        print_error "Unknown command: ${1:-}"
        echo ""
        show_help
        exit 1
        ;;
esac
