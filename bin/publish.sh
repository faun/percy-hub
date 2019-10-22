#!/bin/bash

# Make sure the current working dir is the same as the script that was run.
cd "$(dirname "$0")" || exit 1
CURDIR=$(pwd)

[ -z "$BUILDKITE_COMMIT" ] && echo "[ERROR] Need to set BUILDKITE_COMMIT environment variable." && exit 1

TAG="$BUILDKITE_COMMIT"
echo "Building: $IMAGE:$TAG"

function safe_git_pull_origin_master {
  if [ -n "$(git status --porcelain)" ]; then
    echo 'Local changes detected, aborting!'
    exit 1
  fi
  git pull origin master
}


IMAGE="gcr.io/percy-prod/hub"
cd "$CURDIR/.." && safe_git_pull_origin_master && cd "$CURDIR/.." || exit
gcloud auth configure-docker
docker build -f Dockerfile -t "$IMAGE:$TAG" ./
docker tag "$IMAGE:$TAG" "$IMAGE:latest"
docker push "$IMAGE:$TAG"
docker push "$IMAGE:latest"

# Copy image to percy-dev registry.
docker tag "$IMAGE:latest" gcr.io/percy-dev/hub:latest
docker push gcr.io/percy-dev/hub:latest

echo
echo "Successfully built image $IMAGE with tags '$TAG' and 'latest'."
