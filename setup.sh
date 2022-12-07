#!/bin/bash

###
# This file can be run locally or from a remote source:
#
# Local: ./setup.sh install
# Remote: curl https://raw.githubusercontent.com/MrSimonEmms/gitpod-k3s-guide/main/setup.sh | CMD=install bash
###

set -euo pipefail

USE_REMOTE_REPO=0
if [ -z "${BASH_SOURCE:-}" ]; then
  cmd="${CMD:-}"
  DIR="${PWD}"
  USE_REMOTE_REPO=1
else
  cmd="${1:-}"
  DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
fi

# Set default values
KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config}"
HA_CLUSTER="${HA_CLUSTER:-false}"
INSTALL_MONITORING="${INSTALL_MONITORING:-false}"
MONITORING_NAMESPACE=monitoring
GITPOD_NAMESPACE="${GITPOD_NAMESPACE:-gitpod}"
CONTEXT_NAME="${CONTEXT_NAME:-gitpod-k3s}"
K3S_CHANNEL="${K3S_CHANNEL:-stable}"
REPO_RAW_URL="${REPO_RAW_URL:-https://raw.githubusercontent.com/MrSimonEmms/gitpod-k3s-guide/main}"

# Ensure Kubernetes directory exists
mkdir -p "$(dirname "${KUBECONFIG}")"

function get_local_or_remote_file() {
  if [ "${USE_REMOTE_REPO}" -eq 1 ]; then
    echo "${REPO_RAW_URL}"
  else
    echo "${DIR}"
  fi
}

function check_dependencies() {
  if ! command -v k3sup &> /dev/null; then
    echo "k3sup not be found - please visit https://k3sup.dev for installation instructions"
    exit 1
  fi

  if ! command -v kubectl &> /dev/null; then
    echo "kubectl not be found - please visit https://kubernetes.io/docs/tasks/tools for installation instructions"
    exit 1
  fi

  if ! command -v helm &> /dev/null; then
    echo "helm not be found - please visit https://helm.sh/docs/intro/install for installation instructions"
    exit 1
  fi
}

function delete_node() {
  echo "Deleting node from cluster"

  NAME="${1}"

  if [ -z "${NAME}" ]; then
    echo "Node name must be specified"
    exit 1
  fi

  if [ "${USE_REMOTE_REPO}" -eq 1 ]; then
    REPLY="y"
  else
    read -p "Are you sure you want to delete node: ${NAME} (y/n)?" -n 1 -r
    echo ""
  fi

  if [[ $REPLY =~ ^[Yy]$ ]]; then
    if ! kubectl get nodes "${NAME}" > /dev/null 2>&1; then
      echo "Unknown node: ${NAME}"
      exit 1
    fi

    kubectl get nodes

    echo "Draining node"
    kubectl drain "${NAME}" --ignore-daemonsets --delete-local-data

    echo "Deleting node"
    kubectl delete node "${NAME}"

    kubectl get nodes

    echo "Node removed from cluster: $NAME"
  fi
}

function setup_managed_dns() {
  case "${MANAGED_DNS_PROVIDER:-}" in
    cloudflare )
      echo "Installing Cloudflare managed DNS"
      kubectl create secret generic cloudflare-api-token \
        -n cert-manager \
        --from-literal=api-token="${CLOUDFLARE_API_TOKEN}" \
        --dry-run=client -o yaml | \
        kubectl replace --force -f -

      if [ "${USE_REMOTE_REPO}" -eq 1 ]; then
        curl "$(get_local_or_remote_file)/assets/cloudflare.yaml" --output "/tmp/cloudflare.yaml"
        envsubst < "/tmp/cloudflare.yaml" | kubectl apply -f -
      else
        envsubst < "${DIR}/assets/cloudflare.yaml" | kubectl apply -f -
      fi
      ;;
    gcp )
      echo "Installing GCP managed DNS"
      kubectl create secret generic clouddns-dns01-solver \
        -n cert-manager \
        --from-file=key.json="${GCP_SERVICE_ACCOUNT_KEY}" \
        --dry-run=client -o yaml | \
        kubectl replace --force -f -

      if [ "${USE_REMOTE_REPO}" -eq 1 ]; then
        curl "$(get_local_or_remote_file)/assets/gcp.yaml" --output "/tmp/gcp.yaml"
        envsubst < "/tmp/gcp.yaml" | kubectl apply -f -
      else
        envsubst < "${DIR}/assets/gcp.yaml" | kubectl apply -f -
      fi
      ;;
    route53 )
      echo "Installing Route 53 managed DNS"
      kubectl create secret generic route53-api-secret \
        -n cert-manager \
        --from-literal=secret-access-key="${ROUTE53_SECRET_KEY}" \
        --dry-run=client -o yaml | \
        kubectl replace --force -f -

      if [ "${USE_REMOTE_REPO}" -eq 1 ]; then
        curl "$(get_local_or_remote_file)/assets/route53.yaml" --output "/tmp/route53.yaml"
        envsubst < "/tmp/route53.yaml" | kubectl apply -f -
      else
        envsubst < "${DIR}/assets/route53.yaml" | kubectl apply -f -
      fi
      ;;
    selfsigned )
      echo "A self-signed certificate will be created"
      ;;
    * )
      echo "Not installing managed DNS"
      ;;
  esac
}

function setup_monitoring() {
  if [ "${INSTALL_MONITORING}" = "true" ]; then
    echo "Install monitoring"

    kubectl create namespace "${GITPOD_NAMESPACE}" || true

    helm upgrade \
      --atomic \
      --cleanup-on-fail \
      --create-namespace \
      --install \
      --namespace="${MONITORING_NAMESPACE}" \
      --repo=https://helm.simonemms.com \
      --reset-values \
      --set gitpodNamespace="${GITPOD_NAMESPACE}" \
      --wait \
      monitoring \
      gitpod-monitoring
  else
    helm un -n "${MONITORING_NAMESPACE}" monitoring || true
    kubectl delete namespace "${MONITORING_NAMESPACE}" || true
  fi
}

function get_credentials() {
  JOIN_NODE=0
  for IP in ${IP_LIST//,/ }; do
    if [ "${JOIN_NODE}" -eq 0 ]; then
      echo "Downloading Kubernetes credentials from ${IP}"

      k3sup install \
        --merge \
        --local-path "${KUBECONFIG}" \
        --context="${CONTEXT_NAME}" \
        --ip "${IP}" \
        --skip-install \
        --user "${SERVER_USER}"

      kubectl config use-context "${CONTEXT_NAME}"
    fi

    # Increment the JOIN_NODE
    ((JOIN_NODE=JOIN_NODE+1))
  done

  kubectl get nodes -o wide
}

function install() {
  echo "Installing Gitpod to k3s cluster"

  echo "Install k3s with k3sup"
  SERVER_IP=
  JOIN_NODE=0
  USE_LOCAL=false
  for IP in ${IP_LIST//,/ }; do
    if [ "${IP}" = "127.0.0.1" ]; then
      echo "Using local node"
      USE_LOCAL=true
    else
      echo "Set the k3s config template"
      ssh-keyscan "${IP}" >> ~/.ssh/known_hosts
    fi

    if [ "${MANAGED_DNS_PROVIDER:-}" == "selfsigned" ]; then
      cat << EOF > ./registries.yaml
configs:
  "reg.${DOMAIN}:20000":
    tls:
      insecure_skip_verify: true
EOF
      if [ "${IP}" = "127.0.0.1" ]; then
        sudo mkdir -p /etc/rancher/k3s
        sudo cp ./registries.yaml /etc/rancher/k3s/registries.yaml
      else
        scp ./registries.yaml "${SERVER_USER}@${IP}:/tmp/registries.yaml"
        ssh "${SERVER_USER}@${IP}" "sudo mkdir -p /etc/rancher/k3s"
        ssh "${SERVER_USER}@${IP}" "sudo mv /tmp/registries.yaml /etc/rancher/k3s/registries.yaml"
      fi
    fi

    EXTRA_ARGS="--node-label=gitpod.io/workload_meta=true --node-label=gitpod.io/workload_ide=true --node-label=gitpod.io/workload_workspace_services=true --node-label=gitpod.io/workload_workspace_regular=true --node-label=gitpod.io/workload_workspace_headless=true"

    if [ "${JOIN_NODE}" -eq 0 ]; then
      echo "Installing k3s to node ${IP}"

      k3sup install \
        --cluster="${HA_CLUSTER}" \
        --context="${CONTEXT_NAME}" \
        --ip "${IP}" \
        --local="${USE_LOCAL}" \
        --local-path "${KUBECONFIG}" \
        --merge \
        --k3s-channel="${K3S_CHANNEL}" \
        --k3s-extra-args="--disable traefik ${EXTRA_ARGS}" \
        --user "${SERVER_USER}"

      kubectl config use-context "${CONTEXT_NAME}"

      # Set any future nodes to join this node
      SERVER_IP="${IP}"
    else
      echo "Joining node ${IP} to ${SERVER_IP} - node ${JOIN_NODE}"

      USE_SERVER=false
      NODE_EXTRA_ARGS="${EXTRA_ARGS}"
      if [ "${HA_CLUSTER}" = "true" ]; then
        # If HA, require two control planes

        if [ "${JOIN_NODE}" -eq 1 ]; then
          echo "Setting as server"
          USE_SERVER=true
          NODE_EXTRA_ARGS="--disable traefik ${NODE_EXTRA_ARGS}"
        fi
      fi

      k3sup join \
        --ip "${IP}" \
        --k3s-channel="${K3S_CHANNEL}" \
        --k3s-extra-args="${NODE_EXTRA_ARGS}" \
        --server="${USE_SERVER}" \
        --server-ip "${SERVER_IP}" \
        --server-user "${SERVER_USER}" \
        --user "${SERVER_USER}"
    fi

    # Increment the JOIN_NODE
    ((JOIN_NODE=JOIN_NODE+1))

    echo "Install linux-headers"
    if [ "${IP}" = "127.0.0.1" ]; then
      sudo apt-get update
      # shellcheck disable=SC2029
      sudo apt-get install -y linux-headers-$(uname -r) linux-headers-generic
    else
      ssh "${SERVER_USER}@${IP}" "sudo apt-get update"
      # shellcheck disable=SC2029
      ssh "${SERVER_USER}@${IP}" 'sudo apt-get install -y linux-headers-$(uname -r) linux-headers-generic'
    fi
  done

  kubectl get nodes -o wide

  echo "Installing cert-manager..."
  helm upgrade \
    --atomic \
    --cleanup-on-fail \
    --create-namespace \
    --install \
    --namespace cert-manager \
    --repo https://charts.jetstack.io \
    --reset-values \
    --set installCRDs=true \
    --wait \
    cert-manager \
    cert-manager

  setup_managed_dns
  setup_monitoring

  cat << EOF


==========================
🎉🥳🔥🧡🚀

Your cloud infrastructure is ready to install Gitpod. Please visit
https://www.gitpod.io/docs/self-hosted/latest/getting-started#step-4-install-gitpod
for your next steps.

=================
Config Parameters
=================

Domain Name: ${DOMAIN}

Registry
========
In cluster: true

Database
========
In cluster: true

Storage
=======
In cluster: true

TLS Certificates
================
EOF

case "${MANAGED_DNS_PROVIDER:-}" in
  cloudflare )
    cat << EOF
Service: Cloudflare
Issuer name: gitpod-issuer
Issuer type: Cluster issuer
EOF
    ;;
  gcp )
    cat << EOF
Service: GCP
Issuer name: gitpod-issuer
Issuer type: Cluster issuer
EOF
    ;;
  route53 )
    cat << EOF
Service: Route 53
Issuer name: gitpod-issuer
Issuer type: Cluster issuer
EOF
    ;;
  selfsigned )
    echo "Service: Self-signed"
    ;;
  * )
    echo "-- Not configured --"
    ;;
esac

  if [ -n "${MANAGED_DNS_PROVIDER:-}" ]; then
  cat << EOF

===========
DNS Records
===========

Domain Name: ${DOMAIN}
A Records:
  ${DOMAIN} - ${SERVER_IP}
  *.${DOMAIN} - ${SERVER_IP}
  *.ws.${DOMAIN} - ${SERVER_IP}
EOF
  fi

  cat << EOF

==========
Monitoring
==========

EOF

  if [ "${INSTALL_MONITORING}" = "true" ]; then
    echo "Prometheus endpoint: http://monitoring-prometheus-prometheus.${MONITORING_NAMESPACE}.svc.cluster.local:9090"
  else
    echo "Monitoring disabled"
  fi
}

function uninstall() {
  echo "Uninstalling Gitpod from k3s cluster"

  if [ "${USE_REMOTE_REPO}" -eq 1 ]; then
    REPLY="y"
  else
    read -p "Are you sure you want to delete: Gitpod (y/N)?" -n 1 -r
    echo ""
  fi

  if [[ $REPLY =~ ^[Yy]$ ]]; then
    for IP in ${IP_LIST//,/ }; do
      if [ "${IP}" = "127.0.0.1" ]; then
        # Local installations are always single node setups
        k3s-uninstall.sh || true
      else
        # Remote installations may be server or agent
        ssh "${SERVER_USER}@${IP}" "k3s-uninstall.sh || k3s-agent-uninstall.sh || true"
      fi
    done
  fi
}

############
# Commands #
############

set -a

if [ -f "${DIR}/.env" ]; then
  echo "Loading configuration from ${DIR}/.env."
  source "${DIR}/.env"
fi
set -a

case "${cmd}" in
  credentials )
    get_credentials
    ;;
  delete-node )
    delete_node "${2:-}"
    ;;
  install )
    install
    ;;
  uninstall )
    uninstall
    ;;
  * )
    echo "Unknown command: ${cmd}"
    exit 1
    ;;
esac
