#!/bin/bash

set -euo pipefail

DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
if [ ! -f "${DIR}/.env" ]; then
    echo "Missing ${DIR}/.env configuration file."
    exit 1;
fi

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
    * )
      echo "Not installing managed DNS"
      ;;
  esac
}

function install() {
  echo "Installing Gitpod to k3s cluster"

  mkdir -p "${HOME}/.kube"

  echo "Install k3s with k3sup"
  SERVER_IP=
  JOIN_NODE=0
  for IP in ${IP_LIST//,/ }; do
    if [ "${JOIN_NODE}" -eq 0 ]; then
      echo "Installing k3s to node ${IP}"

      k3sup install \
        --cluster \
        --ip "${IP}" \
        --local-path "${HOME}/.kube/config" \
        --merge \
        --k3s-extra-args="--disable traefik --node-label=gitpod.io/workload_meta=true --node-label=gitpod.io/workload_ide=true --node-label=gitpod.io/workload_workspace_services=true --node-label=gitpod.io/workload_workspace_regular=true --node-label=gitpod.io/workload_workspace_headless=true" \
        --user "${USER}"

      # Set any future nodes to join this node
      JOIN_NODE=1
      SERVER_IP="${IP}"
    else
      echo "Joining node ${IP} to ${SERVER_IP}"

      k3sup join \
        --ip "${IP}" \
        --k3s-extra-args="--disable traefik --node-label=gitpod.io/workload_meta=true --node-label=gitpod.io/workload_ide=true --node-label=gitpod.io/workload_workspace_services=true --node-label=gitpod.io/workload_workspace_regular=true --node-label=gitpod.io/workload_workspace_headless=true" \
        --server \
        --server-ip "${SERVER_IP}" \
        --server-user "${USER}" \
        --user "${USER}"
    fi

    echo "Install linux-headers"
    ssh-keyscan "${IP}" >> ~/.ssh/known_hosts
    ssh "${USER}@${IP}" "sudo apt-get update"
    # shellcheck disable=SC2029
    ssh "${USER}@${IP}" "sudo apt-get install -y linux-headers-$(uname -r) linux-headers-generic"
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
Issuer name: gitpod-issuer
Issuer type: Cluster issuer
EOF

  if [ -n "${MANAGED_DNS_PROVIDER}" ]; then
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
}

function uninstall() {
  echo "Uninstalling Gitpod from k3s cluster"

  read -p "Are you sure you want to delete: Gitpod (y/n)?" -n 1 -r
  echo ""
  if [[ $REPLY =~ ^[Yy]$ ]]; then
    for IP in ${IP_LIST//,/ }; do
      ssh "${USER}@${IP}" k3s-uninstall.sh
    done
  fi
}

############
# Commands #
############

cmd="${1:-}"
set -a
source "${DIR}/.env"
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
