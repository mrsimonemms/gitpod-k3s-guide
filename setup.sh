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

function installer() {
  docker run -it --rm \
    -v="${HOME}/.kube:${HOME}/.kube" \
    -v="${PWD}:${PWD}" \
    -w="${PWD}" \
    "eu.gcr.io/gitpod-core-dev/build/installer:${INSTALLER_VERSION}" \
    "${@}"
}

function install() {
  echo "Installing Gitpod to k3s cluster"

  mkdir -p "${HOME}/.kube"

  echo "Install k3s with k3sup"
  k3sup install \
    --ip "${IP}" \
    --local-path "${HOME}/.kube/config" \
    --k3s-extra-args="--disable traefik --node-label=gitpod.io/workload_meta=true --node-label=gitpod.io/workload_ide=true --node-label=gitpod.io/workload_workspace_services=true --node-label=gitpod.io/workload_workspace_regular=true --node-label=gitpod.io/workload_workspace_headless=true" \
    --user "${USER}"

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

  envsubst < "${DIR}/assets/certificate.yaml" | kubectl apply -f -

  local CONFIG_FILE="${DIR}/gitpod-config.yaml"

  installer init > "${CONFIG_FILE}"

  yq e -i ".domain = \"${DOMAIN}\"" "${CONFIG_FILE}"
  yq e -i '.workspace.runtime.containerdRuntimeDir = "/run/k3s/containerd/io.containerd.runtime.v2.task/k8s.io"' "${CONFIG_FILE}"
  yq e -i '.workspace.runtime.containerdSocket = "/run/k3s/containerd/containerd.sock"' "${CONFIG_FILE}"
  yq e -i '.workspace.runtime.fsShiftMethod = "fuse"' "${CONFIG_FILE}"

  installer render --config="${CONFIG_FILE}" > gitpod.yaml

  echo "Installing Gitpod"
  kubectl apply -f gitpod.yaml
}

function uninstall() {
  echo "Uninstalling Gitpod from k3s cluster"

  read -p "Are you sure you want to delete: Gitpod (y/n)?" -n 1 -r
  echo ""
  if [[ $REPLY =~ ^[Yy]$ ]]; then
    ssh "${USER}@${IP}" k3s-uninstall.sh
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
