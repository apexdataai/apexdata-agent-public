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

check_production_safety() {
    log "Checking cluster environment..."

    local current_context=$(kubectl config current-context 2>/dev/null)
    local cluster_name=$(kubectl config view --minify -o jsonpath='{.clusters[0].name}' 2>/dev/null)

    echo -e "${BLUE}Current context:${NC} $current_context"
    echo -e "${BLUE}Cluster name:${NC} $cluster_name"

    # Check for production indicators in context/cluster name
    local is_production=false
    if [[ "$current_context" =~ (prod|production|prd|live) ]] || \
       [[ "$cluster_name" =~ (prod|production|prd|live) ]]; then
        is_production=true
    fi

    # Check for production taints on nodes (e.g., node-role.kubernetes.io/control-plane)
    local tainted_nodes=$(kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{": "}{.spec.taints[*].key}{"\n"}{end}' 2>/dev/null | grep -E "(production|prod|critical)" || true)
    if [[ -n "$tainted_nodes" ]]; then
        is_production=true
        warn "Found nodes with production-related taints:"
        echo "$tainted_nodes"
    fi

    # Check if namespace already exists with running pods
    local existing_pods=$(kubectl get pods -n apexdata-ai --no-headers 2>/dev/null | wc -l | tr -d ' ')
    if [[ "$existing_pods" -gt 0 ]]; then
        warn "Found $existing_pods existing pod(s) in apexdata-ai namespace"
        kubectl get pods -n apexdata-ai --no-headers 2>/dev/null
        echo
    fi

    if [[ "$is_production" == "true" ]]; then
        echo
        warn "=========================================="
        warn "  PRODUCTION CLUSTER DETECTED!"
        warn "=========================================="
        echo
        read -p "Are you sure you want to deploy to this cluster? (type 'yes' to confirm): " confirm
        if [[ "$confirm" != "yes" ]]; then
            error "Deployment cancelled"
            exit 1
        fi
    fi

    success "Cluster safety check passed"
}

verify_pods_health() {
    local timeout=${1:-120}
    local interval=5
    local elapsed=0

    log "Waiting for all pods to be ready (timeout: ${timeout}s)..."

    # Expected deployments and daemonset
    local expected_deployments=("apexdata-agent" "apexdata-agent-unscheduled-pods")
    local expected_daemonset="apexdata-agent-shard"

    while [[ $elapsed -lt $timeout ]]; do
        local all_ready=true

        # Check deployments
        for deploy in "${expected_deployments[@]}"; do
            local ready=$(kubectl get deployment "$deploy" -n apexdata-ai -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
            local desired=$(kubectl get deployment "$deploy" -n apexdata-ai -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "1")

            if [[ -z "$ready" ]] || [[ "$ready" -lt "$desired" ]]; then
                all_ready=false
                break
            fi
        done

        # Check daemonset
        if [[ "$all_ready" == "true" ]]; then
            local ds_ready=$(kubectl get daemonset "$expected_daemonset" -n apexdata-ai -o jsonpath='{.status.numberReady}' 2>/dev/null || echo "0")
            local ds_desired=$(kubectl get daemonset "$expected_daemonset" -n apexdata-ai -o jsonpath='{.status.desiredNumberScheduled}' 2>/dev/null || echo "1")

            if [[ -z "$ds_ready" ]] || [[ "$ds_ready" -lt "$ds_desired" ]]; then
                all_ready=false
            fi
        fi

        if [[ "$all_ready" == "true" ]]; then
            echo
            success "All pods are ready!"
            echo
            kubectl get pods -n apexdata-ai
            return 0
        fi

        printf "."
        sleep $interval
        elapsed=$((elapsed + interval))
    done

    echo
    error "Timeout waiting for pods to be ready"
    echo
    echo -e "${YELLOW}Current pod status:${NC}"
    kubectl get pods -n apexdata-ai
    echo
    echo -e "${YELLOW}Pods not in Running state:${NC}"
    kubectl get pods -n apexdata-ai --field-selector=status.phase!=Running 2>/dev/null || true
    echo
    echo -e "${YELLOW}Recent events:${NC}"
    kubectl get events -n apexdata-ai --sort-by='.lastTimestamp' | tail -10
    return 1
}

interactive_setup() {
    log "Interactive parameter setup..."

    echo
    echo -e "${BLUE}Enter deployment parameters:${NC}"
    echo

    read -p "Client name (e.g., oteldemo): " CLIENT_NAME
    if [[ -z "$CLIENT_NAME" ]]; then
        error "Client name cannot be empty"
        exit 1
    fi

    # Build endpoint from client name
    APEXDATA_OTEL_ENDPOINT="${CLIENT_NAME}.collector.eu.apexdata.ai"
    log "Using endpoint: ${APEXDATA_OTEL_ENDPOINT}:444"
    log "Using username: ${CLIENT_NAME}"

    read -s -p "Password for user '${CLIENT_NAME}': " password
    echo

    if [[ -z "$password" ]]; then
        error "Password cannot be empty"
        exit 1
    fi

    APEXDATA_BASE64_CREDENTIALS=$(echo -n "$CLIENT_NAME:$password" | base64)

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
        success "Deployment applied successfully"
    else
        error "Deployment failed"
        exit 1
    fi

    echo
    if verify_pods_health 120; then
        success "Deployment completed and verified!"
    else
        warn "Deployment applied but some pods are not ready"
        warn "Check pod logs for more details"
    fi

    echo
    log "To check logs use:"
    echo "  kubectl logs -n apexdata-ai deployment/apexdata-agent"
    echo "  kubectl logs -n apexdata-ai daemonset/apexdata-agent-shard"
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
    echo "  -i, --interactive    Interactive parameter setup (recommended)"
    echo "  -s, --status         Show deployment status"
    echo "  -u, --uninstall      Remove deployment"
    echo "  --verify             Verify all pods are healthy"
    echo "  -h, --help           Show this help"
    echo
    echo "Environment variables (for non-interactive mode):"
    echo "  APEXDATA_OTEL_ENDPOINT        - OpenTelemetry endpoint (e.g., clientname.collector.eu.apexdata.ai)"
    echo "  APEXDATA_BASE64_CREDENTIALS   - Base64 encoded credentials (clientname:password)"
    echo "  APEXDATA_CLUSTER_NAME         - Cluster name identifier"
    echo
    echo "Examples:"
    echo "  # Interactive deployment (recommended)"
    echo "  $0 --interactive"
    echo
    echo "  # Deployment with environment variables"
    echo "  export APEXDATA_OTEL_ENDPOINT=\"oteldemo.collector.eu.apexdata.ai\""
    echo "  export APEXDATA_BASE64_CREDENTIALS=\"\$(echo -n 'oteldemo:yourpassword' | base64)\""
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
            check_production_safety
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
        --verify)
            verify_pods_health 60
            ;;
        "")
            check_dependencies
            check_production_safety
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