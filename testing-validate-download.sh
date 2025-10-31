#! /bin/bash

# Download file and verify Git blob SHA via GitHub API (no pre-shared key)
FILE_URL="https://raw.githubusercontent.com/PostWarTacos/CryptoShred/refs/heads/main/CryptoShred.sh"
API_URL="https://api.github.com/repos/PostWarTacos/CryptoShred/contents/CryptoShred.sh?ref=main"
OUT="/tmp/remote-file"

# hardened curl options
CURL_OPTS=( --fail --silent --show-error --location --connect-timeout 10 --max-time 300 --retry 3 --retry-delay 2 )

# 1) download
curl "${CURL_OPTS[@]}" -o "$OUT" "$FILE_URL" || { echo "download failed"; exit 1; }

# 2) compute local git blob SHA (same algorithm GitHub uses)
if ! command -v git >/dev/null 2>&1; then
  echo "git required for blob-sha check"
  exit 1
fi
LOCAL_BLOB_SHA=$(git hash-object "$OUT")

# 3) get remote blob sha from GitHub API (sed extraction)
REMOTE_SHA=$(curl "${CURL_OPTS[@]}" -H "Accept: application/vnd.github.v3+json" "$API_URL" \
  | sed -n 's/.*"sha": *"\([^"]*\)".*/\1/p' || true)

if [ -z "$REMOTE_SHA" ]; then
  echo "Could not get remote API SHA; aborting"
  exit 1
fi

if [ "$LOCAL_BLOB_SHA" != "$REMOTE_SHA" ]; then
  echo "SHA mismatch: possible corruption or MITM; aborting"
  exit 1
fi

echo "OK: downloaded file matches GitHub blob SHA"
# proceed to install/use $OUT