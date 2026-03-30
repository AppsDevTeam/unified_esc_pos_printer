#!/bin/bash

# Usage: ./scripts/release.sh v3.1.0

set -e

TAG="$1"

if [ -z "$TAG" ]; then
    echo "Usage: ./scripts/release.sh <version-tag>"
    echo "Example: ./scripts/release.sh v3.1.0"
    exit 1
fi

if ! echo "$TAG" | grep -qE '^v[0-9]+\.[0-9]+\.[0-9]+$'; then
    echo "ERROR: Tag must be in format vX.Y.Z (e.g. v3.1.0)"
    exit 1
fi

if git tag -l | grep -q "^${TAG}$"; then
    echo "ERROR: Tag $TAG already exists"
    exit 1
fi

# Strip 'v' prefix for pubspec version (v3.1.0 -> 3.1.0)
VERSION="${TAG#v}"

# Update version in pubspec.yaml
sed -i '' "s/^version: .*/version: $VERSION/" pubspec.yaml

# Update version in README.md dependency example
sed -i '' "s/unified_esc_pos_printer: .*/unified_esc_pos_printer: ^$VERSION/" README.md

echo "Updated pubspec.yaml version to $VERSION and README.md dependency to ^$VERSION"

# Commit and tag
git add pubspec.yaml README.md
git commit -m "Release $TAG"
git tag "$TAG"

# Push commit and tag
git push
git push origin "$TAG"

echo ""
echo "Done! Released $TAG (commit and tag pushed)."
