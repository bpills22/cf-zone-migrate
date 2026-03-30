#!/usr/bin/env bash
#
# cf-zone-cleanup.sh
# ===================
# Cloudflare Zone Migration Cleanup Script
#
# After zones have been migrated and validated on the destination account,
# this script removes the old zones from the source account. It verifies
# each zone is Active on the destination before deleting from the source.
#
# Prerequisites:
#   - curl, jq installed
#   - Source API Token with: Zone > Zone > Read + Edit (needs Edit to delete)
#   - Destination API Token with: Zone > Zone > Read (to verify Active status)
#
# Usage:
#   export CF_SOURCE_API_TOKEN="source-account-token"
#   export CF_DEST_API_TOKEN="destination-account-token"
#
#   # Clean up a single zone
#   ./cf-zone-cleanup.sh --zone-name example.com
#
#   # Clean up from a file of zone names (one per line)
#   ./cf-zone-cleanup.sh --zone-file migrated-zones.txt
#
#   # Clean up using migration exports directory (reads zone names from folder names)
#   ./cf-zone-cleanup.sh --from-exports ./migration-exports
#
#   # Dry run — check status only, don't delete anything
#   ./cf-zone-cleanup.sh --from-exports ./migration-exports --dry-run
#
#   # Skip confirmation prompts
#   ./cf-zone-cleanup.sh --zone-file migrated-zones.txt --yes
#

set -euo pipefail

# ─── Configuration ────────────────────────────────────────────────────────────

CF_SOURCE_API_TOKEN="${CF_SOURCE_API_TOKEN:?ERROR: Set CF_SOURCE_API_TOKEN environment variable}"
CF_DEST_API_TOKEN="${CF_DEST_API_TOKEN:?ERROR: Set CF_DEST_API_TOKEN environment variable}"
CF_API_BASE="https://api.cloudflare.com/client/v4"

RATE_LIMIT_DELAY=0.3
TIMESTAMP=$(date +%Y-%m-%d-%H%M)
REPORT_FILE="./cleanup-report-${TIMESTAMP}.txt"

# Parse arguments
DRY_RUN=false
AUTO_YES=false
ZONE_NAMES=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        --zone-name)
            ZONE_NAMES+=("${2:?ERROR: --zone-name requires an argument}")
            shift 2
            ;;
        --zone-file)
            ZONE_FILE="${2:?ERROR: --zone-file requires a filename}"
            if [[ ! -f "$ZONE_FILE" ]]; then
                echo "ERROR: Zone file not found: $ZONE_FILE"
                exit 1
            fi
            while IFS= read -r line; do
                line=$(echo "$line" | tr -d '[:space:]')
                [[ -n "$line" && "$line" != \#* ]] && ZONE_NAMES+=("$line")
            done < "$ZONE_FILE"
            shift 2
            ;;
        --from-exports)
            EXPORT_DIR="${2:?ERROR: --from-exports requires a directory}"
            if [[ ! -d "$EXPORT_DIR" ]]; then
                echo "ERROR: Export directory not found: $EXPORT_DIR"
                exit 1
            fi
            for dir in "$EXPORT_DIR"/*/; do
                dirname=$(basename "$dir")
                [[ -n "$dirname" && "$dirname" != "*" ]] && ZONE_NAMES+=("$dirname")
            done
            shift 2
            ;;
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        --yes|-y)
            AUTO_YES=true
            shift
            ;;
        -h|--help)
            head -37 "$0" | tail -33
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

if [[ ${#ZONE_NAMES[@]} -eq 0 ]]; then
    echo "ERROR: No zones specified. Use --zone-name, --zone-file, or --from-exports"
    exit 1
fi

# ─── Helpers ──────────────────────────────────────────────────────────────────

cf_api() {
    local token="$1"
    local method="$2"
    local endpoint="$3"
    local data="${4:-}"

    local args=(
        -s -w "\n%{http_code}"
        -X "$method"
        -H "Authorization: Bearer ${token}"
        -H "Content-Type: application/json"
    )
    [[ -n "$data" ]] && args+=(-d "$data")

    local response
    response=$(curl "${args[@]}" "${CF_API_BASE}${endpoint}")

    local http_code
    http_code=$(echo "$response" | tail -1)
    local body
    body=$(echo "$response" | sed '$d')

    if [[ "$http_code" -ge 400 ]]; then
        echo "API_ERROR:${http_code}:$(echo "$body" | jq -r '.errors[0].message // "Unknown error"' 2>/dev/null)"
        return 1
    fi

    echo "$body"
    sleep "$RATE_LIMIT_DELAY"
}

report() {
    echo "$1" | tee -a "$REPORT_FILE"
}

# ─── Banner ───────────────────────────────────────────────────────────────────

echo "=============================================="
echo " Cloudflare Zone Migration Cleanup"
echo " Timestamp: ${TIMESTAMP}"
echo " Zones:     ${#ZONE_NAMES[@]}"
echo " Dry run:   ${DRY_RUN}"
echo "=============================================="
echo ""

report "=============================================="
report " CLEANUP REPORT — ${TIMESTAMP}"
report "=============================================="

# ─── Validate Tokens ─────────────────────────────────────────────────────────

echo "Validating API tokens..."

src_verify=$(cf_api "$CF_SOURCE_API_TOKEN" "GET" "/user/tokens/verify" || true)
src_status=$(echo "$src_verify" | jq -r '.result.status // "unknown"' 2>/dev/null || echo "unknown")
if [[ "$src_status" != "active" ]]; then
    echo "ERROR: Source API token is invalid."
    exit 1
fi
echo "  ✅ Source token valid"

dest_verify=$(cf_api "$CF_DEST_API_TOKEN" "GET" "/user/tokens/verify" || true)
dest_status=$(echo "$dest_verify" | jq -r '.result.status // "unknown"' 2>/dev/null || echo "unknown")
if [[ "$dest_status" != "active" ]]; then
    echo "ERROR: Destination API token is invalid."
    exit 1
fi
echo "  ✅ Destination token valid"
echo ""

# ─── Pre-Check: Verify Each Zone ─────────────────────────────────────────────

echo "Checking zone status on both accounts..."
echo ""

printf "%-35s %-15s %-15s %s\n" "ZONE" "SOURCE" "DESTINATION" "ACTION"
printf "%-35s %-15s %-15s %s\n" "----" "------" "-----------" "------"

zones_ready=0
zones_not_ready=0

# Store zone IDs for deletion
ZONE_META_DIR=$(mktemp -d)
trap 'rm -rf "$ZONE_META_DIR"' EXIT

for zone_name in "${ZONE_NAMES[@]}"; do

    # Look up zone on source account
    src_response=$(cf_api "$CF_SOURCE_API_TOKEN" "GET" "/zones?name=${zone_name}" || true)
    src_zone_id=$(echo "$src_response" | jq -r '.result[0].id // empty' 2>/dev/null || echo "")
    src_status="not_found"
    if [[ -n "$src_zone_id" ]]; then
        src_status=$(echo "$src_response" | jq -r '.result[0].status // "unknown"' 2>/dev/null || echo "unknown")
        echo "$src_zone_id" > "${ZONE_META_DIR}/${zone_name}.src_id"
    fi

    # Look up zone on destination account
    dest_response=$(cf_api "$CF_DEST_API_TOKEN" "GET" "/zones?name=${zone_name}" || true)
    dest_zone_id=$(echo "$dest_response" | jq -r '.result[0].id // empty' 2>/dev/null || echo "")
    dest_status="not_found"
    if [[ -n "$dest_zone_id" ]]; then
        dest_status=$(echo "$dest_response" | jq -r '.result[0].status // "unknown"' 2>/dev/null || echo "unknown")
    fi

    # Determine action
    action="—"
    if [[ "$src_status" == "not_found" ]]; then
        action="SKIP (not on source)"
        zones_not_ready=$((zones_not_ready + 1))
    elif [[ "$dest_status" == "active" ]]; then
        action="✅ READY to delete from source"
        zones_ready=$((zones_ready + 1))
    elif [[ "$dest_status" == "pending" ]]; then
        action="⏳ WAIT (dest still pending)"
        zones_not_ready=$((zones_not_ready + 1))
    elif [[ "$dest_status" == "not_found" ]]; then
        action="⚠️  NOT on dest — do not delete!"
        zones_not_ready=$((zones_not_ready + 1))
    else
        action="⚠️  Dest status: ${dest_status}"
        zones_not_ready=$((zones_not_ready + 1))
    fi

    printf "%-35s %-15s %-15s %s\n" "$zone_name" "$src_status" "$dest_status" "$action"

done

echo ""
echo "${zones_ready} zone(s) ready for cleanup, ${zones_not_ready} not ready."
echo ""

if [[ "$zones_ready" -eq 0 ]]; then
    echo "No zones are ready for cleanup. Exiting."
    exit 0
fi

# ─── Confirmation ─────────────────────────────────────────────────────────────

if [[ "$DRY_RUN" == true ]]; then
    echo "DRY RUN: No zones will be deleted."
    report ""
    report "DRY RUN — no deletions performed."
    report "Ready:     ${zones_ready}"
    report "Not ready: ${zones_not_ready}"
    exit 0
fi

if [[ "$AUTO_YES" == false ]]; then
    echo "⚠️  This will DELETE ${zones_ready} zone(s) from the source account."
    echo "   This action cannot be undone."
    echo ""
    read -r -p "Type 'DELETE' to confirm: " confirm
    if [[ "$confirm" != "DELETE" ]]; then
        echo "Aborted."
        exit 1
    fi
    echo ""
fi

# ─── Delete Zones ────────────────────────────────────────────────────────────

deleted=0
failed=0

for zone_name in "${ZONE_NAMES[@]}"; do

    # Only delete if destination is active
    dest_check=$(cf_api "$CF_DEST_API_TOKEN" "GET" "/zones?name=${zone_name}" || true)
    dest_status=$(echo "$dest_check" | jq -r '.result[0].status // "not_found"' 2>/dev/null || echo "not_found")

    if [[ "$dest_status" != "active" ]]; then
        report "  ⏭️  ${zone_name}: Skipped (dest not active: ${dest_status})"
        continue
    fi

    # Get source zone ID
    src_id=""
    [[ -f "${ZONE_META_DIR}/${zone_name}.src_id" ]] && src_id=$(cat "${ZONE_META_DIR}/${zone_name}.src_id")

    if [[ -z "$src_id" ]]; then
        report "  ⏭️  ${zone_name}: Skipped (not found on source)"
        continue
    fi

    echo "Deleting ${zone_name} (${src_id}) from source account..."

    delete_response=$(cf_api "$CF_SOURCE_API_TOKEN" "DELETE" "/zones/${src_id}" || true)

    if [[ "$delete_response" == API_ERROR* ]]; then
        error_msg=$(echo "$delete_response" | cut -d: -f3-)
        echo "  ❌ Failed: ${error_msg}"
        report "  ❌ ${zone_name}: Delete failed — ${error_msg}"
        failed=$((failed + 1))
    else
        echo "  ✅ Deleted"
        report "  ✅ ${zone_name}: Deleted from source (was ${src_id})"
        deleted=$((deleted + 1))
    fi

done

# ─── Final Report ─────────────────────────────────────────────────────────────

echo ""
echo "=============================================="
echo " CLEANUP COMPLETE"
echo "=============================================="
echo " Deleted:  ${deleted}"
echo " Failed:   ${failed}"
echo " Report:   ${REPORT_FILE}"
echo "=============================================="

report ""
report "=============================================="
report " TOTALS: ${deleted} deleted | ${failed} failed"
report "=============================================="
