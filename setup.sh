#!/bin/bash

set -euo pipefail

DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)

# Set default values
HA_CLUSTER="${HA_CLUSTER:-false}"
INSTALL_MONITORING="${INSTALL_MONITORING:-false}"
MONITORING_NAMESPACE=monitoring
GITPOD_NAMESPACE="${GITPOD_NAMESPACE:-gitpod}"
CONTEXT_NAME="${CONTEXT_NAME:-gitpod-k3s}"
K3S_CHANNEL="${K3S_CHANNEL:-stable}"

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

function setup_managed_dns() {
  case "${MANAGED_DNS_PROVIDER:-}" in
    cloudflare )
      echo "Installing Cloudflare managed DNS"
      kubectl create secret generic cloudflare-api-token \
        -n cert-manager \
        --from-literal=api-token="${CLOUDFLARE_API_KEY}" \
        --dry-run=client -o yaml | \
        kubectl replace --force -f -

      envsubst < "${DIR}/assets/cloudflare.yaml" | kubectl apply -f -
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

function install() {
  echo "Installing Gitpod to k3s cluster"

  mkdir -p "${HOME}/.kube"

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
        --local-path "${HOME}/.kube/config" \
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

  read -p "Are you sure you want to delete: Gitpod (y/n)?" -n 1 -r
  echo ""
  if [[ $REPLY =~ ^[Yy]$ ]]; then
    for IP in ${IP_LIST//,/ }; do
      if [ "${IP}" = "127.0.0.1" ]; then
        k3s-uninstall.sh || true
      else
        ssh "${SERVER_USER}@${IP}" k3s-uninstall.sh || true
      fi
    done
  fi
}

############
# Commands #
############

cmd="${1:-}"
set -a
if [ -f "${DIR}/.env" ]; then
  echo "Loading configuration from ${DIR}/.env."
  source "${DIR}/.env"
fi
set -a

case "${cmd}" in
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
