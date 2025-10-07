#!/bin/bash

# ApexData Agent Service Manager
# Manages systemd service for apexdata-agent

set -e

SERVICE_NAME="apexdata-agent"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
BINARY_PATH="/usr/local/bin/${SERVICE_NAME}"
CONFIG_FILE="/etc/apexdata-agent/config"

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

install_service() {
    print_status "Installing ApexData Agent Service..."
    
    check_binary
    
    # Get configuration from user
    echo ""
    echo "=== Service Configuration ==="
    read -p "Enter OpenTelemetry endpoint (e.g., domain:port): " ENDPOINT
    read -p "Enter Basic Auth token (base64 encoded): " AUTH_TOKEN
    read -p "Enter node name [$(hostname)]: " NODE_NAME
    NODE_NAME=${NODE_NAME:-$(hostname)}
    
    # Validate inputs
    if [[ -z "$ENDPOINT" ]]; then
        print_error "Endpoint cannot be empty"
        exit 1
    fi
    
    if [[ -z "$AUTH_TOKEN" ]]; then
        print_error "Auth token cannot be empty"
        exit 1
    fi
    
    # Create config directory
    mkdir -p /etc/apexdata-agent
    
    # Save configuration
    cat > "$CONFIG_FILE" << EOF
ENDPOINT="$ENDPOINT"
AUTH_TOKEN="$AUTH_TOKEN"
NODE_NAME="$NODE_NAME"
EOF
    
    print_success "Configuration saved to $CONFIG_FILE"
    
    # Copy binary
    cp "./${SERVICE_NAME}" "$BINARY_PATH"
    chmod +x "$BINARY_PATH"
    print_success "Binary installed to $BINARY_PATH"
    
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
ExecStart=$BINARY_PATH --resources=pods --node=%NODE_NAME% --otel-protocol=grpc --otel-headers="authorization=Basic %AUTH_TOKEN%" --endpoint=%ENDPOINT%
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

    # Replace placeholders with actual values
    sed -i "s/%NODE_NAME%/$NODE_NAME/g" "$SERVICE_FILE"
    sed -i "s/%AUTH_TOKEN%/$AUTH_TOKEN/g" "$SERVICE_FILE"
    sed -i "s/%ENDPOINT%/$ENDPOINT/g" "$SERVICE_FILE"
    
    print_success "Service file created at $SERVICE_FILE"
    
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
    [[ -f "$CONFIG_FILE" ]] && rm -f "$CONFIG_FILE" && print_success "Configuration removed"
    [[ -d "/etc/apexdata-agent" ]] && rmdir "/etc/apexdata-agent" 2>/dev/null && print_success "Config directory removed"
    
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

show_config() {
    if [[ -f "$CONFIG_FILE" ]]; then
        echo ""
        echo "=== Current Configuration ==="
        cat "$CONFIG_FILE"
    else
        print_warning "Configuration file not found"
    fi
}

update_config() {
    print_status "Updating service configuration..."
    
    if [[ ! -f "$CONFIG_FILE" ]]; then
        print_error "Service not installed. Run 'install' first."
        exit 1
    fi
    
    # Load current config
    source "$CONFIG_FILE"
    
    echo ""
    echo "=== Update Configuration ==="
    echo "Current endpoint: $ENDPOINT"
    read -p "Enter new endpoint [keep current]: " NEW_ENDPOINT
    NEW_ENDPOINT=${NEW_ENDPOINT:-$ENDPOINT}
    
    echo "Current node name: $NODE_NAME"
    read -p "Enter new node name [keep current]: " NEW_NODE_NAME
    NEW_NODE_NAME=${NEW_NODE_NAME:-$NODE_NAME}
    
    echo "Auth token: [hidden]"
    read -p "Enter new auth token [keep current]: " NEW_AUTH_TOKEN
    NEW_AUTH_TOKEN=${NEW_AUTH_TOKEN:-$AUTH_TOKEN}
    
    # Update config file
    cat > "$CONFIG_FILE" << EOF
ENDPOINT="$NEW_ENDPOINT"
AUTH_TOKEN="$NEW_AUTH_TOKEN"
NODE_NAME="$NEW_NODE_NAME"
EOF
    
    # Update service file
    sed -i "s/--node=[^ ]*/--node=$NEW_NODE_NAME/g" "$SERVICE_FILE"
    sed -i "s/authorization=Basic [^ ]*/authorization=Basic $NEW_AUTH_TOKEN/g" "$SERVICE_FILE"
    sed -i "s/--endpoint=[^ ]*/--endpoint=$NEW_ENDPOINT/g" "$SERVICE_FILE"
    
    systemctl daemon-reload
    
    print_success "Configuration updated"
    print_status "Restart the service to apply changes: sudo $0 restart"
}

show_help() {
    echo "ApexData Agent Service Manager"
    echo ""
    echo "Usage: sudo $0 <command>"
    echo ""
    echo "Commands:"
    echo "  install    - Install and configure the service"
    echo "  uninstall  - Remove the service completely"
    echo "  start      - Start the service"
    echo "  stop       - Stop the service"
    echo "  restart    - Restart the service"
    echo "  status     - Show service status"
    echo "  logs       - Show service logs"
    echo "  config     - Show current configuration"
    echo "  update     - Update service configuration"
    echo "  help       - Show this help message"
    echo ""
    echo "Examples:"
    echo "  sudo $0 install"
    echo "  sudo $0 start"
    echo "  sudo $0 logs"
}

# Main script logic
case "${1:-}" in
    install)
        check_root
        install_service
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
    config)
        show_config
        ;;
    update)
        check_root
        update_config
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
