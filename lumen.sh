#!/bin/bash
# =============================================================================
# lumen.sh — Submit code to Lumen for security analysis
#
# Standalone script. Authenticates, dispatches a SAST scan, optionally waits
# for results and downloads the SARIF report.
#
# Install / run directly:
#   curl -sSL https://raw.githubusercontent.com/ismael-iacc/lumen/main/lumen.sh | bash -s -- \
#     --repo https://github.com/user/repo --language python --wait --output report.sarif
#
# Or download and use locally:
#   curl -sSLo lumen.sh https://raw.githubusercontent.com/ismael-iacc/lumen/main/lumen.sh
#   chmod +x lumen.sh
#   ./lumen.sh --repo https://github.com/user/repo --language python --wait
#
# Environment variables (all overridable via flags):
#   SCAN_API_URL       API base URL          (default: http://localhost:8000/api/v1)
#   SCAN_API_USERNAME  API username           (default: lumen-ci)
#   SCAN_API_PASSWORD  API password
#
# Flags:
#   --api-url URL        API base URL
#   --username USER      API username
#   --password PASS      API password
#   --repo URL           Git repository to scan
#   --branch NAME        Git branch (default: main)
#   --dir PATH           Local directory to scan (base64 upload)
#   --language LANG      Source language (default: python)
#   --wait               Wait for scan to finish
#   --timeout SECONDS    Max wait time (default: 600)
#   --poll-interval SEC  Poll interval (default: 10)
#   --output FILE        Download SARIF report to file
#
# Exit codes:
#   0  Success
#   1  Fatal error
#   2  Timeout
#   3  Scan engine error
# =============================================================================
set -euo pipefail

# ── Defaults ──
API_URL="${SCAN_API_URL:-http://localhost:8000/api/v1}"
USERNAME="${SCAN_API_USERNAME:-lumen-ci}"
PASSWORD="${SCAN_API_PASSWORD:-}"
REPO_URL=""
BRANCH="main"
LOCAL_DIR=""
LANGUAGE="python"
WAIT=false
TIMEOUT=600
OUTPUT=""
POLL_INTERVAL=10

_banner() {
  echo ""
  echo "  ╦   ╦ ╦╔╦╗╔═╗╔╗╔  scan"
  echo "  ║   ║ ║║║║║╣ ║║║"
  echo "  ╩═╝╚═╝╩ ╩╚═╝╝╚╝"
  echo ""
}

_help() {
  cat <<'HELP'
Usage:
  lumen.sh --repo <git-url> [options]
  lumen.sh --dir <path>     [options]

Examples:
  # Quick scan (fire and forget)
  lumen.sh --repo https://github.com/user/repo --language python

  # Wait for results + download SARIF
  lumen.sh --repo https://github.com/user/repo --language python \
    --wait --output report.sarif

  # Scan local directory
  lumen.sh --dir ./my-project --language javascript --wait

Options:
  --api-url URL        Lumen API base URL          (env: SCAN_API_URL)
  --username USER      API username                 (env: SCAN_API_USERNAME)
  --password PASS      API password                 (env: SCAN_API_PASSWORD)
  --repo URL           Git repository URL
  --branch NAME        Branch to checkout           (default: main)
  --dir PATH           Local directory to upload
  --language LANG      Source language               (default: python)
  --wait               Block until scan completes
  --timeout SECS       Max wait time                (default: 600)
  --poll-interval SECS Polling interval             (default: 10)
  --output FILE        Save SARIF report to file

Exit codes:
  0  Success
  1  Fatal error (auth / dispatch / download)
  2  Timeout waiting for scan
  3  Scan completed with engine errors
HELP
}

# ── Parse args ──
while [[ $# -gt 0 ]]; do
  case "$1" in
    --api-url)       API_URL="$2"; shift 2 ;;
    --username)      USERNAME="$2"; shift 2 ;;
    --password)      PASSWORD="$2"; shift 2 ;;
    --repo)          REPO_URL="$2"; shift 2 ;;
    --branch)        BRANCH="$2"; shift 2 ;;
    --dir)           LOCAL_DIR="$2"; shift 2 ;;
    --language)      LANGUAGE="$2"; shift 2 ;;
    --wait)          WAIT=true; shift ;;
    --timeout)       TIMEOUT="$2"; shift 2 ;;
    --output)        OUTPUT="$2"; shift 2 ;;
    --poll-interval) POLL_INTERVAL="$2"; shift 2 ;;
    --help|-h)       _banner; _help; exit 0 ;;
    *)               echo "[ERROR] Unknown option: $1"; exit 1 ;;
  esac
done

_banner

# ── Validate ──
if [[ -z "$REPO_URL" && -z "$LOCAL_DIR" ]]; then
  echo "[ERROR] Specify --repo <url> or --dir <path>"
  echo "        Run with --help for usage."
  exit 1
fi

if [[ -z "$PASSWORD" ]]; then
  echo "[ERROR] API password is required."
  echo "        Set SCAN_API_PASSWORD or use --password <pass>"
  exit 1
fi

for cmd in curl jq; do
  if ! command -v "$cmd" &>/dev/null; then
    echo "[ERROR] '$cmd' is required but not found."
    exit 1
  fi
done

# ── 1. Authenticate ──
echo "[1/4] Authenticating as '${USERNAME}'..."
AUTH_RESPONSE=$(curl -sf -X POST "${API_URL}/auth/token" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "username=${USERNAME}&password=${PASSWORD}") || {
  echo "[ERROR] Authentication failed. Is Lumen running at ${API_URL}?"
  exit 1
}

TOKEN=$(echo "$AUTH_RESPONSE" | jq -r '.data.access_token')
if [[ -z "$TOKEN" || "$TOKEN" == "null" ]]; then
  echo "[ERROR] Could not extract access token."
  exit 1
fi
echo "  OK"

# ── 2. Build payload ──
if [[ -n "$REPO_URL" ]]; then
  PAYLOAD=$(jq -n \
    --arg scan_type "sast" \
    --arg type "git" \
    --arg source_url "$REPO_URL" \
    --arg branch "$BRANCH" \
    --arg language "$LANGUAGE" \
    '{
      scan_type: $scan_type,
      target: { type: $type, source_url: $source_url },
      meta: { branch: $branch, language: $language }
    }')
  echo "[2/4] Target: git ${REPO_URL} (${BRANCH}, ${LANGUAGE})"

elif [[ -n "$LOCAL_DIR" ]]; then
  if [[ ! -d "$LOCAL_DIR" ]]; then
    echo "[ERROR] Directory not found: $LOCAL_DIR"
    exit 1
  fi

  FILES_JSON="[]"
  while IFS= read -r -d '' filepath; do
    rel_path="${filepath#$LOCAL_DIR/}"
    b64=$(base64 -w0 "$filepath" 2>/dev/null || base64 "$filepath" 2>/dev/null)
    FILES_JSON=$(echo "$FILES_JSON" | jq \
      --arg f "$rel_path" --arg c "$b64" \
      '. + [{"filename":$f,"content":$c,"encoding":"base64"}]')
  done < <(find "$LOCAL_DIR" -type f \
    -not -path '*/.git/*' \
    -not -path '*/node_modules/*' \
    -not -path '*/__pycache__/*' \
    -not -path '*/.venv/*' \
    -not -name '*.pyc' \
    -print0)

  FILE_COUNT=$(echo "$FILES_JSON" | jq 'length')
  if [[ "$FILE_COUNT" -eq 0 ]]; then
    echo "[ERROR] No files found in $LOCAL_DIR"
    exit 1
  fi

  PAYLOAD=$(jq -n \
    --arg scan_type "sast" \
    --arg language "$LANGUAGE" \
    --argjson files "$FILES_JSON" \
    '{
      scan_type: $scan_type,
      target: { type: "raw", files: $files },
      meta: { language: $language }
    }')
  echo "[2/4] Target: ${FILE_COUNT} files from ${LOCAL_DIR} (${LANGUAGE})"
fi

# ── 3. Dispatch ──
echo "[3/4] Dispatching scan..."
DISPATCH_RESPONSE=$(curl -sf -X POST "${API_URL}/scan/dispatch" \
  -H "Authorization: Bearer ${TOKEN}" \
  -H "Content-Type: application/json" \
  -d "$PAYLOAD") || {
  echo "[ERROR] Scan dispatch failed."
  exit 1
}

TASK_ID=$(echo "$DISPATCH_RESPONSE" | jq -r '.data.task_ids[0]' 2>/dev/null)
AGENTS=$(echo "$DISPATCH_RESPONSE" | jq -r '.data.agent_ids | join(", ")' 2>/dev/null)

if [[ -z "$TASK_ID" || "$TASK_ID" == "null" ]]; then
  echo "[ERROR] No task ID returned."
  echo "$DISPATCH_RESPONSE"
  exit 1
fi

echo "  Task:   ${TASK_ID}"
echo "  Agents: ${AGENTS}"

# ── 4. Wait + report (optional) ──
if [[ "$WAIT" != true ]]; then
  echo ""
  echo "[OK] Scan dispatched. Use --wait to block until completion."
  echo ""
  echo "TASK_ID=${TASK_ID}"
  exit 0
fi

echo "[4/4] Waiting for results (timeout: ${TIMEOUT}s)..."

ELAPSED=0
FINAL_STATUS=""
FINDINGS_COUNT=0
while [[ $ELAPSED -lt $TIMEOUT ]]; do
  RESP=$(curl -sf "${API_URL}/scan/status/${TASK_ID}" \
    -H "Authorization: Bearer ${TOKEN}" 2>/dev/null) || true

  if [[ -n "$RESP" ]]; then
    ST=$(echo "$RESP" | jq -r '.data.status' 2>/dev/null)
    if [[ "$ST" == "completed" || "$ST" == "error" ]]; then
      FINAL_STATUS="$ST"
      FINDINGS_COUNT=$(echo "$RESP" | jq -r '.data.findings_count // 0' 2>/dev/null)
      break
    fi
  fi

  sleep "$POLL_INTERVAL"
  ELAPSED=$((ELAPSED + POLL_INTERVAL))
  printf "  %ds / %ds  (%s)\n" "$ELAPSED" "$TIMEOUT" "${ST:-dispatched}"
done

if [[ -z "$FINAL_STATUS" ]]; then
  echo ""
  echo "[ERROR] Scan did not complete within ${TIMEOUT}s"
  exit 2
fi

echo ""
echo "  Status:   ${FINAL_STATUS}"
echo "  Findings: ${FINDINGS_COUNT}"

if [[ "$FINAL_STATUS" == "error" ]]; then
  echo ""
  echo "[WARN] Scan finished with engine errors."
  exit 3
fi

# ── Download SARIF ──
if [[ -n "$OUTPUT" ]]; then
  echo ""
  echo "[*] Downloading SARIF report..."
  HTTP_CODE=$(curl -sf -o "$OUTPUT" -w "%{http_code}" \
    "${API_URL}/results/report/${TASK_ID}" \
    -H "Authorization: Bearer ${TOKEN}")

  if [[ "$HTTP_CODE" == "200" ]]; then
    echo "[OK] Report saved: ${OUTPUT}"
  elif [[ "$HTTP_CODE" == "404" ]]; then
    cat > "$OUTPUT" <<'SARIF_EMPTY'
{"$schema":"https://raw.githubusercontent.com/oasis-tcs/sarif-spec/main/sarif-2.1/schema/sarif-schema-2.1.0.json","version":"2.1.0","runs":[{"tool":{"driver":{"name":"lumen","rules":[]}},"results":[]}]}
SARIF_EMPTY
    echo "[OK] No findings — empty SARIF written: ${OUTPUT}"
  else
    echo "[ERROR] Download failed (HTTP ${HTTP_CODE})."
    exit 1
  fi
fi

# ── Machine-readable output (last 3 lines) ──
echo ""
echo "TASK_ID=${TASK_ID}"
echo "FINDINGS_COUNT=${FINDINGS_COUNT}"
echo "STATUS=${FINAL_STATUS}"
