#!/usr/bin/env bash
# Bump to the latest docling-serve vX.Y.Z tag: version strings, pinned rev, flake input lock.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
repo=docling-project/docling-serve
tag=$(git ls-remote --tags --refs "https://github.com/$repo" | awk '{sub("refs/tags/","",$2); print $2}' | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' | sort -V | tail -n1)
new=${tag#v}
old=$(grep -oE '^      version = "[^"]+"' flake.nix | sed -E 's/.*"([^"]+)"/\1/')
[ "$new" != "$old" ] || { echo "up to date: $old"; exit 0; }
rev=$(git ls-remote "https://github.com/$repo" "refs/tags/$tag^{}" | awk '{print $1}')
[ -n "$rev" ] || rev=$(git ls-remote "https://github.com/$repo" "refs/tags/$tag" | awk '{print $1}')
oldrev=$(grep -oE '^      revision = "[0-9a-f]{40}"' flake.nix | sed -E 's/.*"([^"]+)"/\1/')
sed -i -e "s/$oldrev/$rev/g" -e "s/\"$old\"/\"$new\"/g" flake.nix
nix flake update docling-serve-src
echo "bumped $old -> $new ($rev)"
