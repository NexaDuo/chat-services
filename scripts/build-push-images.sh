#!/usr/bin/env bash
# scripts/build-push-images.sh
#
# Builds the NexaDuo service images locally and pushes them to Artifact
# Registry. Use this for the first deploy (before any git tag exists) or
# whenever you need to publish an image out-of-band from CI.
#
# Authentication: requires `gcloud auth login` + application-default creds
# already set up on the operator's workstation. The script configures
# docker to use `gcloud` as a credential helper for the AR host.
#
# Environment overrides:
#   GCP_PROJECT_ID   (default: nexaduo-492818)
#   GCP_REGION       (default: us-central1)
#   AR_REPOSITORY    (default: nexaduo)
#   IMAGE_TAG        (default: 0.1.0)
#
# Usage:
#   ./scripts/build-push-images.sh
#   IMAGE_TAG=0.1.1 ./scripts/build-push-images.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

PROJECT_ID="${GCP_PROJECT_ID:-nexaduo-492818}"
REGION="${GCP_REGION:-us-central1}"
REPO="${AR_REPOSITORY:-nexaduo}"
TAG="${IMAGE_TAG:-0.1.0}"

REGISTRY="${REGION}-docker.pkg.dev"
BASE="${REGISTRY}/${PROJECT_ID}/${REPO}"

echo "=== Configuring docker auth for ${REGISTRY} ==="
gcloud auth configure-docker "${REGISTRY}" --quiet

build_and_push() {
  local name=$1
  local context=$2
  local image="${BASE}/${name}"
  echo "=== Building ${name} from ${context} ==="
  docker build --platform linux/amd64 -t "${image}:${TAG}" -t "${image}:latest" "${context}"
  echo "=== Pushing ${image}:${TAG} and :latest ==="
  docker push "${image}:${TAG}"
  docker push "${image}:latest"
}

build_and_push middleware "${PROJECT_ROOT}/middleware"
build_and_push self-healing-agent "${PROJECT_ROOT}/agents/self-healing"

echo "Done. Images published:"
echo "  ${BASE}/middleware:${TAG}"
echo "  ${BASE}/self-healing-agent:${TAG}"
