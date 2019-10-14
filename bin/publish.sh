#!/bin/bash

# Make sure the current working dir is the same as the script that was run.
cd "$(dirname "$0")" || exit 1
CURDIR=$(pwd)
NOW=`date +%Y-%m-%d-%H%M%S`

function safe_git_pull_origin_master {
  if [ -n "$(git status --porcelain)" ]; then
    echo 'Local changes detected, aborting!'
    exit 1
  fi
  git pull origin master
}


IMAGE="gcr.io/percy-prod/hub"
echo "Building $IMAGE"
cd "$CURDIR/.." && safe_git_pull_origin_master && cd "$CURDIR/.." || exit
docker build -f Dockerfile -t "$IMAGE:$NOW" ./
docker tag "$IMAGE:$NOW" "$IMAGE:latest"
gcloud docker -- push "$IMAGE:$NOW"
gcloud docker -- push "$IMAGE:latest"

# Copy image to percy-dev registry.
docker tag "$IMAGE:latest" gcr.io/percy-dev/hub:latest
gcloud docker -- push gcr.io/percy-dev/hub:latest

echo
echo "Successfully built image $IMAGE with tags '$NOW' and 'latest'."
