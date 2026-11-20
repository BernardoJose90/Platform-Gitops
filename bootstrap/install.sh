#!/usr/bin/env bash
# One-time Argo CD bootstrap for a new (or rebuilt) cluster.
#
# Installs Argo CD with Helm, then applies the AppProjects and the root
# Application. After this, Argo CD manages itself from platform/argocd/ and
# everything else from git. Do not use this script for day-to-day changes.
#
# Usage:
#   ./bootstrap/install.sh <expected-kube-context>
#
# Requirements: kubectl and helm, a kube context with cluster-admin on the
# target cluster, and network access to the EKS API (the IP allowlist).

set -euo pipefail

# Keep these in sync with the Argo CD Application in platform/argocd/,
# otherwise the first self-managed sync will upgrade/downgrade Argo CD.
CHART_VERSION="${ARGOCD_CHART_VERSION:-10.17.0}" # Argo CD v3.6.1
RELEASE_NAME="argocd"
NAMESPACE="argocd"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VALUES_FILE="${REPO_ROOT}/platform/argocd/values.yaml"

expected_context="${1:-}"
if [[ -z "${expected_context}" ]]; then
  echo "Usage: $0 <expected-kube-context>" >&2
  exit 1
fi

for bin in kubectl helm; do
  command -v "${bin}" >/dev/null || { echo "Missing required tool: ${bin}" >&2; exit 1; }
done

# Guard against installing into the wrong cluster.
current_context="$(kubectl config current-context)"
if [[ "${current_context}" != "${expected_context}" ]]; then
  echo "Current kube context is '${current_context}', expected '${expected_context}'. Aborting." >&2
  exit 1
fi
kubectl cluster-info >/dev/null

echo "==> Installing Argo CD chart ${CHART_VERSION} into ${NAMESPACE} (context: ${current_context})"
helm repo add argo https://argoproj.github.io/argo-helm --force-update >/dev/null
helm repo update argo >/dev/null

values_args=()
if [[ -f "${VALUES_FILE}" ]]; then
  values_args=(--values "${VALUES_FILE}")
else
  echo "    (no ${VALUES_FILE#"${REPO_ROOT}"/} yet, using chart defaults)"
fi

helm upgrade --install "${RELEASE_NAME}" argo/argo-cd \
  --namespace "${NAMESPACE}" --create-namespace \
  --version "${CHART_VERSION}" \
  ${values_args[@]+"${values_args[@]}"} \
  --wait --timeout 10m

# The root Application uses project "platform", so projects must exist first.
echo "==> Applying AppProjects"
kubectl apply -f "${REPO_ROOT}/argocd/projects/"

echo "==> Applying root Application"
kubectl apply -f "${REPO_ROOT}/bootstrap/root-app.yaml"

cat <<EOF

Done. Argo CD now syncs from git.

Initial admin password (rotate it, then delete the secret once SSO is set up):
  kubectl -n ${NAMESPACE} get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d; echo

UI:
  kubectl -n ${NAMESPACE} port-forward svc/${RELEASE_NAME}-server 8080:443
EOF
