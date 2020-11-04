#!/usr/bin/env bash

set -e

cd "$(dirname "$0")" || exit 1
CURDIR="$(pwd)"

CURRENT_VERSION="$(grep "VERSION" lib/percy/hub/version.rb | awk -F "'" '{print $2}')"

echo "Current gem version: $CURRENT_VERSION"

if [[ $# -lt 1 ]]; then
  echo "Usage $0 <version>"
  exit 1
fi

rm "$CURDIR/"percy-hub-*.gem >/dev/null 2>&1 || true

delete_existing_version() {
  VERSION=$1
  # Replace - with .pre. in version string for rubygems compatibility
  RUBYGEMS_GEM_VERSION="${VERSION/-/.pre.}"
  git tag -d "v$VERSION" || true
  git push origin ":v$VERSION" || true
  package_cloud yank percy/private-gems "percy-hub-$RUBYGEMS_GEM_VERSION.gem" || true
}

VERSION=$1
if [[ $1 == 'delete' ]]; then
  delete_existing_version "$VERSION"
else
  CLEAN=$(
    git diff-index --quiet HEAD --
    echo $?
  )
  if [[ "$CLEAN" == "0" ]]; then
    if [[ $1 == '--force' ]]; then
      shift
      VERSION=$1
      if [[ -n $VERSION ]]; then
        echo "Deleting version $VERSION"
        sleep 1
        delete_existing_version "$VERSION"
      else
        echo "Missing release version"
        exit 1
      fi
    fi
    sed -i "" -e "s/$CURRENT_VERSION/$VERSION/g" "lib/percy/hub/version.rb"
    git add "lib/percy/hub/version.rb"
    git commit -a -m "Release $VERSION" || true

    # Replace - with .pre. in version string for rubygems compatibility
    RUBYGEMS_GEM_VERSION="${VERSION/-/.pre.}"

    if [[ "$RUBYGEMS_GEM_VERSION" == "$VERSION" ]]; then
      echo "Releasing $VERSION"
    else
      echo "Releasing $VERSION as $RUBYGEMS_GEM_VERSION"
    fi
    sleep 1

    git tag -a "v$VERSION" -m "$1" || true
    git push origin "v$VERSION" || true

    bundle exec rake build
    bundle exec package_cloud push percy/private-gems "$CURDIR/pkg/percy-hub-$RUBYGEMS_GEM_VERSION.gem"
    open "https://github.com/percy/percy-hub/releases/new?tag=v$VERSION&title=$VERSION"
  else
    echo "Please commit your changes and try again"
    exit 1
  fi
fi

rm "$CURDIR/pkg/"percy-hub-*.gem >/dev/null 2>&1 || true
echo "Done"
