#!/bin/zsh

set -euo pipefail

SCRIPT_DIR="${0:A:h}"
ROOT_DIR="${SCRIPT_DIR:h:h}"
SUBMODULE_PATH="engine/firefox"
FIREFOX_URL="https://github.com/mozilla-firefox/firefox"

cd "$ROOT_DIR"

if [[ ! -f "engine/release.txt" ]]; then
	echo "Cannot get Firefox release tag: Missing engine/release.txt."
	exit 1
fi

RELEASE_TAG="$(tr -d '\000\r' < "engine/release.txt" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"

if [[ -z "$RELEASE_TAG" ]]; then
	echo "Cannot get Firefox release tag: engine/release.txt is empty."
	exit 1
fi

if ! git ls-remote --exit-code --tags "$FIREFOX_URL" "refs/tags/$RELEASE_TAG" >/dev/null 2>&1; then
	echo "Release tag $RELEASE_TAG does not exist in $FIREFOX_URL."
	exit 1
fi

TAG_REF="refs/tags/$RELEASE_TAG"

echo "Updating Gecko checkout at $SUBMODULE_PATH"
if git rev-parse --verify HEAD:"$SUBMODULE_PATH" >/dev/null 2>&1; then
	git submodule set-url -- "$SUBMODULE_PATH" "$FIREFOX_URL"
	git submodule sync -- "$SUBMODULE_PATH"
	git submodule update --init --depth 1 -- "$SUBMODULE_PATH"
else
	if ! git -C "$SUBMODULE_PATH" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
		echo "Submodule path $SUBMODULE_PATH is missing or not a git repo. Cloning from $FIREFOX_URL."
		rm -rf "$SUBMODULE_PATH"
		git clone --depth 1 --filter=blob:none "$FIREFOX_URL" "$SUBMODULE_PATH"
	fi
	git -C "$SUBMODULE_PATH" remote set-url origin "$FIREFOX_URL"
fi

echo "Fetching and checking out tag $RELEASE_TAG..."
git -C "$SUBMODULE_PATH" fetch --depth 1 origin tag "$RELEASE_TAG"
git -C "$SUBMODULE_PATH" checkout --detach "$TAG_REF^{commit}"

EXPECTED_COMMIT="$(git -C "$SUBMODULE_PATH" rev-parse "$TAG_REF^{commit}")"
HEAD_COMMIT="$(git -C "$SUBMODULE_PATH" rev-parse HEAD)"

if [[ "$HEAD_COMMIT" != "$EXPECTED_COMMIT" ]]; then
	echo "Failed to checkout the expected commit for $RELEASE_TAG."
	echo "Expected: $EXPECTED_COMMIT"
	echo "Actual:   $HEAD_COMMIT"
	exit 1
fi
