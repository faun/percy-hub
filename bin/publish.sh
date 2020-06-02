#!/bin/bash

# Make sure the current working dir is the same as the script that was run.
cd "$(dirname "$0")" || exit 1
CURDIR=$(pwd)

# Use the first argument as the image tag. If an argument wasn't provided,
# use $BUILDKITE_COMMIT environment variable as the image tag.
TAG="${1:-$BUILDKITE_COMMIT}"
[ -z "$TAG" ] && echo "Usage: $0 <commit>" && exit 1

function safe_git_pull_origin_master() {
  if [ -n "$(git status --porcelain)" ]; then
    echo 'Local changes detected, aborting!'
    exit 1
  fi
  git pull origin master
}

IMAGE="gcr.io/percy-prod/hub"
cd "$CURDIR/.." && safe_git_pull_origin_master && cd "$CURDIR/.." || exit
gcloud auth configure-docker

echo "Building: $IMAGE:$TAG"

docker build \
  -f Dockerfile \
  --cache-from "$IMAGE:$TAG" \
  --build-arg "SOURCE_COMMIT_SHA=$TAG" \
  -t "$IMAGE:$TAG" \
  ./

docker tag "$IMAGE:$TAG" "$IMAGE:latest"
docker push "$IMAGE:$TAG"
docker push "$IMAGE:latest"

# Copy image to percy-dev registry.
docker tag "$IMAGE:latest" gcr.io/percy-dev/hub:latest
docker push gcr.io/percy-dev/hub:latest

echo
echo "Successfully built image $IMAGE with tags '$TAG' and 'latest'."
