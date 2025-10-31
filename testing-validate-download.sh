// ...existing code...
# ═══════════════════════════════════════════════════════════════════════════════════════════════════════════
# UPDATE CHECKING
# ═══════════════════════════════════════════════════════════════════════════════════════════════════════════

# GitHub repo info for self-update
GITHUB_OWNER="PostWarTacos"
GITHUB_REPO="CryptoShred"
REMOTE_PATH="BuildCryptoShred.sh"
REF="main"

# API and raw URLs
API_URL="https://api.github.com/repos/${GITHUB_OWNER}/${GITHUB_REPO}/contents/${REMOTE_PATH}?ref=${REF}"
RAW_URL="https://raw.githubusercontent.com/${GITHUB_OWNER}/${GITHUB_REPO}/${REF}/${REMOTE_PATH}"

# Hardened curl options
CURL_OPTS=( --fail --silent --show-error --location --connect-timeout 10 --max-time 300 --retry 3 --retry-delay 2 )

# Allow token via environment to avoid rate limits / access private repos
AUTH_HDR=()
if [ -n "${GITHUB_TOKEN:-}" ]; then
  AUTH_HDR=( -H "Authorization: token ${GITHUB_TOKEN}" )
fi

# Resolve the path to this script (attempt a few strategies)
resolve_self_path() {
  local path
  # If $0 is absolute and exists, use it
  if [[ "$0" == /* ]] && [ -f "$0" ]; then
    printf '%s' "$0"
    return 0
  fi
  # Prefer BASH_SOURCE if it is absolute
  if [ -n "${BASH_SOURCE[0]:-}" ] && [[ "${BASH_SOURCE[0]}" == /* ]] && [ -f "${BASH_SOURCE[0]}" ]; then
    printf '%s' "${BASH_SOURCE[0]}"
    return 0
  fi
  # Try realpath/readlink if available
  if command -v realpath >/dev/null 2>&1; then
    realpath "${BASH_SOURCE[0]:-$0}" 2>/dev/null && return 0
  fi
  if command -v readlink >/dev/null 2>&1; then
    readlink -f "${BASH_SOURCE[0]:-$0}" 2>/dev/null && return 0
  fi
  # Fallback: construct from pwd + basename
  printf '%s' "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null || pwd)/$(basename "${BASH_SOURCE[0]:-$0}")"
}

SCRIPT_PATH="$(resolve_self_path)"
# Fallback: if resolution failed, use $0 as-is
if [ -z "$SCRIPT_PATH" ] || [ ! -f "$SCRIPT_PATH" ]; then
  SCRIPT_PATH="$0"
fi

# Compute local hashes
LOCAL_BLOB_SHA=""
if command -v git >/dev/null 2>&1 && [ -f "$SCRIPT_PATH" ]; then
  LOCAL_BLOB_SHA=$(git hash-object "$SCRIPT_PATH" 2>/dev/null || true)
fi
LOCAL_SHA256=$([ -f "$SCRIPT_PATH" ] && sha256sum "$SCRIPT_PATH" | cut -d' ' -f1 || echo "")

echo
echo -e "${YELLOW}[*] Checking for BuildCryptoShred.sh updates using GitHub API blob SHA...${NC}"

# Fetch remote blob SHA from GitHub API
REMOTE_SHA="$(curl "${CURL_OPTS[@]}" "${AUTH_HDR[@]}" -H "Accept: application/vnd.github.v3+json" "$API_URL" 2>/dev/null | sed -n 's/.*"sha": *"\([^"]*\)".*/\1/p' || true)"

# If we have a git blob SHA locally and remotely, compare directly
if [ -n "$LOCAL_BLOB_SHA" ] && [ -n "$REMOTE_SHA" ]; then
  if [ "$LOCAL_BLOB_SHA" = "$REMOTE_SHA" ]; then
    echo -e "${GREEN}[+] BuildCryptoShred.sh is up to date (git blob sha match: ${LOCAL_BLOB_SHA:0:16}...)${NC}"
  else
    echo
    echo -e "${RED}[!] Local script blob SHA differs from GitHub API blob SHA.${NC}"
    echo "    Local blob SHA:  ${LOCAL_BLOB_SHA}"
    echo "    Remote blob SHA: ${REMOTE_SHA}"
    echo "    Downloading and verifying remote script..."

    TMP_REMOTE="$(mktemp)" || { echo -e "${RED}[!] Failed to create temp file.${NC}"; exit 1; }
    if ! curl "${CURL_OPTS[@]}" -o "$TMP_REMOTE" "$RAW_URL"; then
      echo -e "${RED}[!] Failed to download remote script from $RAW_URL. Aborting update.${NC}"
      rm -f "$TMP_REMOTE"
    else
      # Compute blob SHA of downloaded file and verify matches API
      DOWNLOADED_BLOB_SHA=$(git hash-object "$TMP_REMOTE" 2>/dev/null || true)
      if [ -n "$DOWNLOADED_BLOB_SHA" ] && [ "$DOWNLOADED_BLOB_SHA" = "$REMOTE_SHA" ]; then
        echo -e "${GREEN}[+] Download verified against GitHub API blob SHA.${NC}"
        # Replace current script atomically, preserving original permissions
        ORIG_PERMS=$(stat -c %a "$SCRIPT_PATH" 2>/dev/null || echo 0755)
        chmod +x "$TMP_REMOTE" || true
        if command -v install >/dev/null 2>&1; then
          install -m "$ORIG_PERMS" "$TMP_REMOTE" "$SCRIPT_PATH" || {
            echo -e "${RED}[!] Install failed. Exiting.${NC}"
            rm -f "$TMP_REMOTE"
            exit 1
          }
        else
          mkdir -p "$(dirname "$SCRIPT_PATH")"
          cp -- "$TMP_REMOTE" "$SCRIPT_PATH" || {
            echo -e "${RED}[!] Copy failed. Exiting.${NC}"
            rm -f "$TMP_REMOTE"
            exit 1
          }
          chmod "$ORIG_PERMS" "$SCRIPT_PATH" || true
        fi
        sync "$SCRIPT_PATH" || true
        echo
        echo -e "${GREEN}[+] Script updated from GitHub (verified). Please re-run BuildCryptoShred.sh.${NC}"
        rm -f "$TMP_REMOTE"
        exit 0
      else
        echo -e "${RED}[!] Downloaded file failed verification (blob sha mismatch). Not updating.${NC}"
        echo "    Downloaded blob SHA: ${DOWNLOADED_BLOB_SHA:-<missing>}"
        echo "    Expected remote API blob SHA: ${REMOTE_SHA:-<missing>}"
        rm -f "$TMP_REMOTE"
      fi
    fi
  fi

# If we couldn't compute local blob SHA or couldn't fetch REMOTE_SHA, fall back to sha256-based check
else
  echo -e "${YELLOW}[*] Falling back to sha256-based check (git blob sha unavailable or API failed).${NC}"
  TMP_REMOTE="$(mktemp)" || { echo -e "${RED}[!] Failed to create temp file.${NC}"; exit 1; }
  if curl "${CURL_OPTS[@]}" -o "$TMP_REMOTE" "$RAW_URL"; then
    REMOTE_HASH=$(sha256sum "$TMP_REMOTE" | cut -d' ' -f1)
    LOCAL_HASH=$([ -f "$SCRIPT_PATH" ] && sha256sum "$SCRIPT_PATH" | cut -d' ' -f1 || echo "")
    if [ -z "$REMOTE_HASH" ]; then
      echo -e "${RED}[!] Could not compute remote sha256. Skipping update.${NC}"
      rm -f "$TMP_REMOTE"
    elif [ "$LOCAL_HASH" != "$REMOTE_HASH" ]; then
      echo
      echo -e "${RED}[!] Local script sha256 differs from remote version.${NC}"
      echo "    Local:  ${LOCAL_HASH:-<missing>}"
      echo "    Remote: ${REMOTE_HASH:-<unknown>}"
      echo "    Updating local script with the latest version..."
      ORIG_PERMS=$(stat -c %a "$SCRIPT_PATH" 2>/dev/null || echo 0755)
      chmod +x "$TMP_REMOTE" || true
      if command -v install >/dev/null 2>&1; then
        install -m "$ORIG_PERMS" "$TMP_REMOTE" "$SCRIPT_PATH" || {
          echo -e "${RED}[!] Install failed. Exiting script.${NC}"
          rm -f "$TMP_REMOTE"
          exit 1
        }
      else
        mkdir -p "$(dirname "$SCRIPT_PATH")"
        cp -- "$TMP_REMOTE" "$SCRIPT_PATH" || {
          echo -e "${RED}[!] Copy failed. Exiting script.${NC}"
          rm -f "$TMP_REMOTE"
          exit 1
        }
        chmod "$ORIG_PERMS" "$SCRIPT_PATH" || true
      fi
      sync "$SCRIPT_PATH" || true
      echo
      echo -e "${GREEN}[+] Script updated. Please re-run BuildCryptoShred.sh.${NC}"
      rm -f "$TMP_REMOTE"
      exit 0
    else
      echo -e "${GREEN}[+] BuildCryptoShred.sh is up to date (sha256 match: ${LOCAL_HASH:0:16}...)${NC}"
      rm -f "$TMP_REMOTE"
    fi
  else
    echo -e "${RED}[!] Could not download remote script for comparison. Continuing with local version.${NC}"
    rm -f "$TMP_REMOTE"
  fi
fi
// ...existing code...