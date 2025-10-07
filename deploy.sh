#!/bin/bash

# ApexData Universal Deployment Script
# 
# This script simplifies deployment of ApexData Agent and OpenTelemetry Collector
# in your Kubernetes cluster.

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' 

log() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

check_dependencies() {
    log "Checking dependencies..."
    
    if ! command -v kubectl &> /dev/null; then
        error "kubectl not found. Please install kubectl."
        exit 1
    fi
    
    if ! command -v envsubst &> /dev/null; then
        error "envsubst not found. Please install gettext."
        exit 1
    fi
    
    if ! kubectl cluster-info &> /dev/null; then
        error "Unable to connect to Kubernetes cluster."
        exit 1
    fi
    
    success "All dependencies are OK"
}

interactive_setup() {
    log "Interactive parameter setup..."
    
    echo
    echo -e "${BLUE}Enter deployment parameters:${NC}"
    echo
    
    read -p "OpenTelemetry endpoint (without port, example: ec88v4-otel.app.apexdata.ai): " APEXDATA_OTEL_ENDPOINT
    if [[ -z "$APEXDATA_OTEL_ENDPOINT" ]]; then
        error "OTEL endpoint cannot be empty"
        exit 1
    fi
    
    read -p "Username: " username
    read -s -p "Password: " password
    echo
    
    if [[ -z "$username" || -z "$password" ]]; then
        error "Username and password cannot be empty"
        exit 1
    fi
    
    APEXDATA_BASE64_CREDENTIALS=$(echo -n "$username:$password" | base64)
    
    read -p "Cluster name (example: production-cluster): " APEXDATA_CLUSTER_NAME
    if [[ -z "$APEXDATA_CLUSTER_NAME" ]]; then
        error "Cluster name cannot be empty"
        exit 1
    fi
    
    export APEXDATA_OTEL_ENDPOINT
    export APEXDATA_BASE64_CREDENTIALS
    export APEXDATA_CLUSTER_NAME
    
    success "Parameters configured"
}

check_env_vars() {
    local missing_vars=()
    
    if [[ -z "$APEXDATA_OTEL_ENDPOINT" ]]; then
        missing_vars+=("APEXDATA_OTEL_ENDPOINT")
    fi
    
    if [[ -z "$APEXDATA_BASE64_CREDENTIALS" ]]; then
        missing_vars+=("APEXDATA_BASE64_CREDENTIALS")
    fi
    
    if [[ -z "$APEXDATA_CLUSTER_NAME" ]]; then
        missing_vars+=("APEXDATA_CLUSTER_NAME")
    fi
    
    if [[ ${#missing_vars[@]} -gt 0 ]]; then
        error "Missing environment variables: ${missing_vars[*]}"
        echo
        echo "Set them or run script in interactive mode:"
        echo "  $0 --interactive"
        echo
        echo "Or set the variables:"
        echo "  export APEXDATA_OTEL_ENDPOINT=\"ec88v4-otel.app.apexdata.ai\""
        echo "  export APEXDATA_BASE64_CREDENTIALS=\"\$(echo -n 'user:pass' | base64)\""
        echo "  export APEXDATA_CLUSTER_NAME=\"production-cluster\""
        exit 1
    fi
}

deploy() {
    log "Deploying ApexData Agent..."
    
    if [[ ! -f "universal-deployment.yml" ]]; then
        error "File universal-deployment.yml not found in current directory"
        exit 1
    fi
    
    if envsubst < universal-deployment.yml | kubectl apply -f -; then
        success "Deployment completed successfully"
    else
        error "Deployment failed"
        exit 1
    fi
    
    echo
    log "Checking pod status..."
    kubectl get pods -n apexdata-ai
    
    echo
    log "To check logs use:"
    echo "  kubectl logs -n apexdata-ai deployment/otel-collector"
    echo "  kubectl logs -n apexdata-ai deployment/apexdata-agent"
}

status() {
    log "ApexData Agent deployment status:"
    echo
    
    echo -e "${BLUE}Namespace:${NC}"
    kubectl get namespace apexdata-ai 2>/dev/null || echo "Namespace 'apexdata-ai' not found"
    
    echo
    echo -e "${BLUE}Pods:${NC}"
    kubectl get pods -n apexdata-ai 2>/dev/null || echo "Pods not found in namespace 'apexdata-ai'"
    
    echo
    echo -e "${BLUE}Services:${NC}"
    kubectl get services -n apexdata-ai 2>/dev/null || echo "Services not found in namespace 'apexdata-ai'"
}

uninstall() {
    warn "Removing ApexData Agent..."
    read -p "Are you sure? (y/N): " confirm
    
    if [[ $confirm =~ ^[Yy]$ ]]; then
        if [[ -f "universal-deployment.yml" ]]; then
            envsubst < universal-deployment.yml | kubectl delete -f - || true
        else
            kubectl delete namespace apexdata-ai || true
        fi
        success "ApexData Agent removed"
    else
        log "Removal cancelled"
    fi
}

show_help() {
    echo "ApexData Universal Deployment Script"
    echo
    echo "Usage:"
    echo "  $0 [OPTIONS]"
    echo
    echo "Options:"
    echo "  -i, --interactive    Interactive parameter setup"
    echo "  -s, --status         Show deployment status"
    echo "  -u, --uninstall      Remove deployment"
    echo "  -h, --help           Show this help"
    echo
    echo "Environment variables:"
    echo "  APEXDATA_OTEL_ENDPOINT        - OpenTelemetry endpoint (without port)"
    echo "  APEXDATA_BASE64_CREDENTIALS   - Base64 credentials"
    echo "  APEXDATA_CLUSTER_NAME         - Cluster name"
    echo
    echo "Examples:"
    echo "  # Interactive deployment"
    echo "  $0 --interactive"
    echo
    echo "  # Deployment with environment variables"
    echo "  export APEXDATA_OTEL_ENDPOINT=\"ec88v4-otel.app.apexdata.ai\""
    echo "  export APEXDATA_BASE64_CREDENTIALS=\"\$(echo -n 'user:pass' | base64)\""
    echo "  export APEXDATA_CLUSTER_NAME=\"production-cluster\""
    echo "  $0"
    echo
    echo "  # Check status"
    echo "  $0 --status"
}

main() {
    case "${1:-}" in
        -i|--interactive)
            check_dependencies
            interactive_setup
            deploy
            ;;
        -s|--status)
            status
            ;;
        -u|--uninstall)
            uninstall
            ;;
        -h|--help)
            show_help
            ;;
        "")
            check_dependencies
            check_env_vars
            deploy
            ;;
        *)
            error "Unknown option: $1"
            echo
            show_help
            exit 1
            ;;
    esac
}

main "$@"