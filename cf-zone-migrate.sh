#!/usr/bin/env bash
#
# cf-zone-migrate.sh
# ===================
# Cloudflare Zone Migration Script
#
# Migrates one or more zones from a source Cloudflare account to a destination
# account. For each zone it: exports DNS (BIND format), exports rules and
# settings, creates the zone on the destination account, imports DNS records,
# recreates rules, and applies non-default zone settings.
#
# Prerequisites:
#   - curl, jq installed
#   - Source API Token with: Zone > Zone > Read, Zone > DNS > Read,
#     Zone > SSL and Certificates > Read, Zone > Firewall Services > Read,
#     Zone > Zone Settings > Read
#   - Destination API Token with: Zone > Zone > Edit, Zone > DNS > Edit,
#     Zone > Firewall Services > Edit, Zone > Zone Settings > Edit
#
# Usage:
#   export CF_SOURCE_API_TOKEN="source-account-token"
#   export CF_DEST_API_TOKEN="destination-account-token"
#   export CF_DEST_ACCOUNT_ID="destination-account-id"
#
#   # Migrate a single zone
#   ./cf-zone-migrate.sh --zone-id abc123
#
#   # Migrate a list of zone IDs from a file (one per line)
#   ./cf-zone-migrate.sh --zone-file zones-to-migrate.txt
#
#   # Dry run — export and validate only, don't create anything on destination
#   ./cf-zone-migrate.sh --zone-id abc123 --dry-run
#
#   # Skip the confirmation prompt (for scripted/batch use)
#   ./cf-zone-migrate.sh --zone-id abc123 --yes
#
# Output:
#   - ./migration-exports/<zone_name>/          Per-zone export directory
#   - ./migration-exports/<zone_name>/dns.bind  DNS BIND export
#   - ./migration-exports/<zone_name>/rules.json     Ruleset export
#   - ./migration-exports/<zone_name>/pagerules.json Page Rules export
#   - ./migration-exports/<zone_name>/settings.json  Zone settings export
#   - ./migration-exports/<zone_name>/migration.log  Per-zone migration log
#   - ./migration-report-<timestamp>.txt        Summary report
#

set -euo pipefail

# ─── Configuration ────────────────────────────────────────────────────────────

CF_SOURCE_API_TOKEN="${CF_SOURCE_API_TOKEN:?ERROR: Set CF_SOURCE_API_TOKEN environment variable}"
CF_DEST_API_TOKEN="${CF_DEST_API_TOKEN:?ERROR: Set CF_DEST_API_TOKEN environment variable}"
CF_DEST_ACCOUNT_ID="${CF_DEST_ACCOUNT_ID:?ERROR: Set CF_DEST_ACCOUNT_ID environment variable}"
CF_API_BASE="https://api.cloudflare.com/client/v4"

RATE_LIMIT_DELAY=0.3
EXPORT_DIR="./migration-exports"
TIMESTAMP=$(date +%Y-%m-%d-%H%M)
REPORT_FILE="./migration-report-${TIMESTAMP}.txt"

# Parse arguments
DRY_RUN=false
AUTO_YES=false
ZONE_IDS=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        --zone-id)
            ZONE_IDS+=("${2:?ERROR: --zone-id requires an argument}")
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
                [[ -n "$line" && "$line" != \#* ]] && ZONE_IDS+=("$line")
            done < "$ZONE_FILE"
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
            head -40 "$0" | tail -36
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

if [[ ${#ZONE_IDS[@]} -eq 0 ]]; then
    echo "ERROR: No zones specified. Use --zone-id <id> or --zone-file <file>"
    exit 1
fi

mkdir -p "$EXPORT_DIR"

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

cf_api_form() {
    local token="$1"
    local endpoint="$2"
    local file_path="$3"

    local response
    response=$(curl -s -w "\n%{http_code}" \
        -X POST \
        -H "Authorization: Bearer ${token}" \
        --form "file=@${file_path}" \
        "${CF_API_BASE}${endpoint}")

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

# Paginated fetch
cf_api_paginated() {
    local token="$1"
    local endpoint="$2"
    local all_results="[]"
    local page=1
    local per_page=50
    local total_pages=1

    while [[ $page -le $total_pages ]]; do
        local sep="?"
        [[ "$endpoint" == *"?"* ]] && sep="&"

        local response
        response=$(cf_api "$token" "GET" "${endpoint}${sep}page=${page}&per_page=${per_page}") || return 1

        local page_results
        page_results=$(echo "$response" | jq -r '.result // []')
        all_results=$(echo "$all_results" "$page_results" | jq -s 'add')

        total_pages=$(echo "$response" | jq -r '.result_info.total_pages // 1')
        page=$((page + 1))
    done

    echo "$all_results"
}

log() {
    local zone_dir="$1"
    local msg="$2"
    local ts
    ts=$(date '+%H:%M:%S')
    echo "[${ts}] ${msg}" | tee -a "${zone_dir}/migration.log"
}

report() {
    echo "$1" | tee -a "$REPORT_FILE"
}

# ─── Banner ───────────────────────────────────────────────────────────────────

echo "=============================================="
echo " Cloudflare Zone Migration Tool"
echo " Timestamp:   ${TIMESTAMP}"
echo " Zones:       ${#ZONE_IDS[@]}"
echo " Dry run:     ${DRY_RUN}"
echo " Destination: ${CF_DEST_ACCOUNT_ID}"
echo "=============================================="
echo ""

report "=============================================="
report " MIGRATION REPORT — ${TIMESTAMP}"
report "=============================================="

# ─── Validate API Tokens ─────────────────────────────────────────────────────

echo "Validating API tokens..."

src_verify=$(cf_api "$CF_SOURCE_API_TOKEN" "GET" "/user/tokens/verify") || {
    echo "ERROR: Source API token is invalid."
    exit 1
}
src_status=$(echo "$src_verify" | jq -r '.result.status // "unknown"')
if [[ "$src_status" != "active" ]]; then
    echo "ERROR: Source API token status: ${src_status} (expected: active)"
    exit 1
fi
echo "  ✅ Source token valid"

dest_verify=$(cf_api "$CF_DEST_API_TOKEN" "GET" "/user/tokens/verify") || {
    echo "ERROR: Destination API token is invalid."
    exit 1
}
dest_status=$(echo "$dest_verify" | jq -r '.result.status // "unknown"')
if [[ "$dest_status" != "active" ]]; then
    echo "ERROR: Destination API token status: ${dest_status} (expected: active)"
    exit 1
fi
echo "  ✅ Destination token valid"
echo ""

# ─── Pre-flight: Fetch Zone Info for All Zones ───────────────────────────────

echo "Running pre-flight checks..."
echo ""

# Use temp directory for zone metadata (bash 3 compatible, no associative arrays)
ZONE_META_DIR=$(mktemp -d)
trap 'rm -rf "$ZONE_META_DIR"' EXIT

preflight_ok=true

for zone_id in "${ZONE_IDS[@]}"; do
    zone_response=$(cf_api "$CF_SOURCE_API_TOKEN" "GET" "/zones/${zone_id}") || {
        echo "  ❌ Failed to fetch zone ${zone_id} — skipping"
        preflight_ok=false
        continue
    }

    zone_name=$(echo "$zone_response" | jq -r '.result.name')
    zone_status=$(echo "$zone_response" | jq -r '.result.status')
    zone_plan=$(echo "$zone_response" | jq -r '.result.plan.name // .result.plan.legacy_id')
    echo "$zone_name" > "${ZONE_META_DIR}/${zone_id}.name"

    # Check DNSSEC
    dnssec_response=$(cf_api "$CF_SOURCE_API_TOKEN" "GET" "/zones/${zone_id}/dnssec") || true
    dnssec_status=$(echo "$dnssec_response" | jq -r '.result.status // "unknown"' 2>/dev/null || echo "unknown")
    [[ -z "$dnssec_status" ]] && dnssec_status="unknown"
    echo "$dnssec_status" > "${ZONE_META_DIR}/${zone_id}.dnssec"

    echo "  Zone: ${zone_name} (${zone_id})"
    echo "    Plan: ${zone_plan} | Status: ${zone_status} | DNSSEC: ${dnssec_status}"

    if [[ "$dnssec_status" == "active" ]]; then
        echo "    ⚠️  WARNING: DNSSEC is active! Must be disabled before migration."
        preflight_ok=false
    fi

    if [[ "$zone_status" != "active" ]]; then
        echo "    ⚠️  WARNING: Zone is not active (status: ${zone_status})"
    fi
done

echo ""

if [[ "$preflight_ok" == false ]]; then
    echo "⚠️  Pre-flight warnings detected. Review above."
    if [[ "$AUTO_YES" == false ]]; then
        read -r -p "Continue anyway? (y/N): " confirm
        [[ "$confirm" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 1; }
    fi
fi

if [[ "$DRY_RUN" == false && "$AUTO_YES" == false ]]; then
    echo "Ready to migrate ${#ZONE_IDS[@]} zone(s) to account ${CF_DEST_ACCOUNT_ID}."
    read -r -p "Proceed? (y/N): " confirm
    [[ "$confirm" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 1; }
    echo ""
fi

# ─── Migration Loop ──────────────────────────────────────────────────────────

success_count=0
fail_count=0
skip_count=0

for zone_id in "${ZONE_IDS[@]}"; do
    zone_name="unknown"
    [[ -f "${ZONE_META_DIR}/${zone_id}.name" ]] && zone_name=$(cat "${ZONE_META_DIR}/${zone_id}.name")
    zone_dir="${EXPORT_DIR}/${zone_name}"
    mkdir -p "$zone_dir"

    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "MIGRATING: ${zone_name} (${zone_id})"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    log "$zone_dir" "Starting migration for ${zone_name} (${zone_id})"

    # ── Step 1: Export DNS ────────────────────────────────────────────────

    log "$zone_dir" "STEP 1: Exporting DNS records (BIND format)..."

    dns_export=$(curl -s -w "\n%{http_code}" \
        -X GET \
        -H "Authorization: Bearer ${CF_SOURCE_API_TOKEN}" \
        "${CF_API_BASE}/zones/${zone_id}/dns_records/export")

    dns_http_code=$(echo "$dns_export" | tail -1)
    dns_body=$(echo "$dns_export" | sed '$d')

    if [[ "$dns_http_code" -ge 400 ]]; then
        log "$zone_dir" "ERROR: DNS export failed (HTTP ${dns_http_code})"
        report "  ❌ ${zone_name}: DNS export failed"
        fail_count=$((fail_count + 1))
        continue
    fi

    echo "$dns_body" > "${zone_dir}/dns.bind"
    dns_record_count=$(grep -c "^[^;]" "${zone_dir}/dns.bind" | head -1 || echo "0")
    log "$zone_dir" "  Exported DNS to ${zone_dir}/dns.bind (${dns_record_count} records)"

    # ── Step 2: Export Page Rules ─────────────────────────────────────────

    log "$zone_dir" "STEP 2: Exporting Page Rules..."

    pagerules_response=$(cf_api "$CF_SOURCE_API_TOKEN" "GET" "/zones/${zone_id}/pagerules" 2>/dev/null) \
        || pagerules_response='{"result":[]}'
    pagerules=$(echo "$pagerules_response" | jq -r '.result // []')
    pagerule_count=$(echo "$pagerules" | jq 'length' 2>/dev/null || echo "0")
    echo "$pagerules" | jq '.' > "${zone_dir}/pagerules.json"
    log "$zone_dir" "  Found ${pagerule_count} Page Rule(s)"

    # ── Step 3: Export Rulesets ───────────────────────────────────────────

    log "$zone_dir" "STEP 3: Exporting Rulesets (all Ruleset Engine phases)..."

    rulesets_response=$(cf_api "$CF_SOURCE_API_TOKEN" "GET" "/zones/${zone_id}/rulesets") || rulesets_response='{"result":[]}'
    rulesets=$(echo "$rulesets_response" | jq -r '.result // []')

    # Fetch full ruleset details for customer-defined rulesets
    all_rules='[]'
    total_rule_count=0

    while IFS= read -r rs_line; do
        rs_id=$(echo "$rs_line" | jq -r '.id')
        rs_phase=$(echo "$rs_line" | jq -r '.phase')
        rs_kind=$(echo "$rs_line" | jq -r '.kind')

        # Only export zone-level customer rulesets with relevant phases
        [[ "$rs_kind" != "zone" ]] && continue

        rs_detail=$(cf_api "$CF_SOURCE_API_TOKEN" "GET" "/zones/${zone_id}/rulesets/${rs_id}" 2>/dev/null) || continue
        rs_rules=$(echo "$rs_detail" | jq -r '.result.rules // []')
        rs_rule_count=$(echo "$rs_rules" | jq 'length')

        if [[ "$rs_rule_count" -gt 0 ]]; then
            total_rule_count=$((total_rule_count + rs_rule_count))
            # Store phase + rules together for recreation
            ruleset_export=$(echo "$rs_detail" | jq '{phase: .result.phase, name: .result.name, rules: .result.rules}')
            all_rules=$(echo "$all_rules" "[$ruleset_export]" | jq -s 'add')
        fi
    done < <(echo "$rulesets" | jq -c '.[]')

    echo "$all_rules" | jq '.' > "${zone_dir}/rules.json"
    log "$zone_dir" "  Found ${total_rule_count} rule(s) across Ruleset Engine phases"

    # ── Step 4: Export Zone Settings ──────────────────────────────────────

    log "$zone_dir" "STEP 4: Exporting zone settings..."

    settings_response=$(cf_api "$CF_SOURCE_API_TOKEN" "GET" "/zones/${zone_id}/settings") || settings_response='{"result":[]}'
    settings=$(echo "$settings_response" | jq -r '.result // []')
    echo "$settings" | jq '.' > "${zone_dir}/settings.json"

    # Identify non-default settings worth replicating
    # We'll capture the key ones that customers commonly customize
    settings_to_apply='[]'

    for setting_id in ssl min_tls_version always_use_https security_level \
                      browser_cache_ttl challenge_ttl rocket_loader \
                      automatic_https_rewrites opportunistic_encryption \
                      min_tls_version http3 zero_rtt early_hints \
                      always_online browser_check email_obfuscation \
                      hotlink_protection ip_geolocation websockets; do

        val=$(echo "$settings" | jq -r --arg sid "$setting_id" \
            '.[] | select(.id == $sid) | {id: .id, value: .value}' 2>/dev/null)
        if [[ -n "$val" && "$val" != "null" ]]; then
            settings_to_apply=$(echo "$settings_to_apply" "[$val]" | jq -s 'add')
        fi
    done

    echo "$settings_to_apply" | jq '.' > "${zone_dir}/settings-to-apply.json"
    settings_count=$(echo "$settings_to_apply" | jq 'length')
    log "$zone_dir" "  Captured ${settings_count} zone settings"

    # ── Step 5: Export SSL/TLS info ───────────────────────────────────────

    log "$zone_dir" "STEP 5: Checking SSL/TLS configuration..."

    ssl_mode=$(echo "$settings" | jq -r '.[] | select(.id == "ssl") | .value // "off"')
    edge_certs=$(cf_api "$CF_SOURCE_API_TOKEN" "GET" "/zones/${zone_id}/ssl/certificate_packs?status=active" 2>/dev/null) || edge_certs='{"result":[]}'
    has_acm=$(echo "$edge_certs" | jq '[.result[] | select(.type == "advanced")] | length' 2>/dev/null || echo "0")

    log "$zone_dir" "  SSL mode: ${ssl_mode} | ACM certs: ${has_acm}"

    if [[ "$has_acm" -gt 0 ]]; then
        log "$zone_dir" "  ⚠️  Zone uses ACM — ensure ACM is purchased on destination account"
    fi

    # ── DRY RUN STOPS HERE ────────────────────────────────────────────────

    if [[ "$DRY_RUN" == true ]]; then
        log "$zone_dir" "DRY RUN: Skipping destination operations."
        log "$zone_dir" "  Exports saved to ${zone_dir}/"
        report "  📋 ${zone_name}: Export complete (dry run) — ${dns_record_count} DNS, ${pagerule_count} PageRules, ${total_rule_count} rules"
        skip_count=$((skip_count + 1))
        echo ""
        continue
    fi

    # ── Step 6: Create Zone on Destination Account ────────────────────────

    log "$zone_dir" "STEP 6: Creating zone on destination account..."

    create_response=$(cf_api "$CF_DEST_API_TOKEN" "POST" "/zones" \
        "{\"name\":\"${zone_name}\",\"account\":{\"id\":\"${CF_DEST_ACCOUNT_ID}\"},\"type\":\"full\"}" || true)

    if [[ "$create_response" == API_ERROR* ]]; then
        error_msg=$(echo "$create_response" | cut -d: -f3-)
        log "$zone_dir" "ERROR: Failed to create zone: ${error_msg}"

        # Check if zone already exists on destination
        if echo "$error_msg" | grep -qi "already exists"; then
            log "$zone_dir" "  Zone may already exist on destination. Attempting to find it..."
            existing=$(cf_api "$CF_DEST_API_TOKEN" "GET" "/zones?name=${zone_name}&account.id=${CF_DEST_ACCOUNT_ID}") || true
            existing_id=$(echo "$existing" | jq -r '.result[0].id // empty' 2>/dev/null)
            if [[ -n "$existing_id" ]]; then
                log "$zone_dir" "  Found existing zone: ${existing_id}. Will import into it."
                new_zone_id="$existing_id"
                new_ns=$(echo "$existing" | jq -r '.result[0].name_servers | join(", ")' 2>/dev/null || echo "check dashboard")
            else
                report "  ❌ ${zone_name}: Zone creation failed — ${error_msg}"
                fail_count=$((fail_count + 1))
                continue
            fi
        else
            report "  ❌ ${zone_name}: Zone creation failed — ${error_msg}"
            fail_count=$((fail_count + 1))
            continue
        fi
    else
        new_zone_id=$(echo "$create_response" | jq -r '.result.id')
        new_ns=$(echo "$create_response" | jq -r '.result.name_servers | join(", ")')
        new_status=$(echo "$create_response" | jq -r '.result.status')
        log "$zone_dir" "  ✅ Zone created: ${new_zone_id} (status: ${new_status})"
        log "$zone_dir" "  New nameservers: ${new_ns}"
    fi

    # Save new zone info for reference
    echo "${new_zone_id}" > "${zone_dir}/new-zone-id.txt"
    echo "${new_ns}" > "${zone_dir}/new-nameservers.txt"

    # ── Step 7: Import DNS Records ────────────────────────────────────────

    log "$zone_dir" "STEP 7: Importing DNS records into new zone..."

    import_response=$(cf_api_form "$CF_DEST_API_TOKEN" \
        "/zones/${new_zone_id}/dns_records/import" \
        "${zone_dir}/dns.bind" || true)

    if [[ "$import_response" == API_ERROR* ]]; then
        error_msg=$(echo "$import_response" | cut -d: -f3-)
        log "$zone_dir" "ERROR: DNS import failed: ${error_msg}"
        report "  ❌ ${zone_name}: DNS import failed — ${error_msg}"
        fail_count=$((fail_count + 1))
        continue
    fi

    records_added=$(echo "$import_response" | jq -r '.result.recs_added // 0')
    log "$zone_dir" "  ✅ Imported ${records_added} DNS records"

    # ── Step 8: Apply Zone Settings ───────────────────────────────────────

    log "$zone_dir" "STEP 8: Applying zone settings..."

    settings_applied=0
    settings_failed=0

    while IFS= read -r setting; do
        sid=$(echo "$setting" | jq -r '.id')
        # Use jq (without -r) to preserve JSON typing: strings stay quoted,
        # booleans stay true/false, numbers stay numeric
        sval=$(echo "$setting" | jq '.value')

        # Skip ssl setting — we'll handle this explicitly
        [[ "$sid" == "ssl" ]] && continue

        # Build payload with jq to guarantee valid JSON
        payload=$(jq -n --arg id "$sid" --argjson val "$sval" '{"value": $val}')

        patch_response=$(cf_api "$CF_DEST_API_TOKEN" "PATCH" \
            "/zones/${new_zone_id}/settings/${sid}" \
            "$payload" 2>/dev/null) || {
            log "$zone_dir" "  ⚠️  Failed to set ${sid}"
            settings_failed=$((settings_failed + 1))
            continue
        }

        if [[ "$patch_response" == API_ERROR* ]]; then
            log "$zone_dir" "  ⚠️  Failed to set ${sid}: $(echo "$patch_response" | cut -d: -f3-)"
            settings_failed=$((settings_failed + 1))
        else
            settings_applied=$((settings_applied + 1))
        fi
    done < <(echo "$settings_to_apply" | jq -c '.[]')

    # Apply SSL mode separately (important to get right)
    if [[ -n "$ssl_mode" && "$ssl_mode" != "null" ]]; then
        ssl_payload=$(jq -n --arg val "$ssl_mode" '{"value": $val}')
        ssl_patch=$(cf_api "$CF_DEST_API_TOKEN" "PATCH" \
            "/zones/${new_zone_id}/settings/ssl" \
            "$ssl_payload" 2>/dev/null) || true
        if [[ "$ssl_patch" == API_ERROR* ]]; then
            log "$zone_dir" "  ⚠️  Failed to set SSL mode to ${ssl_mode}"
        else
            log "$zone_dir" "  SSL mode set to: ${ssl_mode}"
            settings_applied=$((settings_applied + 1))
        fi
    fi

    log "$zone_dir" "  Applied ${settings_applied} settings (${settings_failed} failed)"

    # ── Step 9: Recreate Rulesets ─────────────────────────────────────────

    log "$zone_dir" "STEP 9: Recreating rules on new zone..."

    rules_created=0
    rules_failed=0

    while IFS= read -r ruleset_export; do
        rs_phase=$(echo "$ruleset_export" | jq -r '.phase')
        rs_rules=$(echo "$ruleset_export" | jq -r '.rules')
        rs_rule_count=$(echo "$rs_rules" | jq 'length')

        [[ "$rs_rule_count" -eq 0 ]] && continue

        # Clean the rules for import: remove IDs and version info that are
        # source-specific. Keep expression, action, description, enabled.
        cleaned_rules=$(echo "$rs_rules" | jq '[.[] | {
            expression: .expression,
            action: .action,
            action_parameters: .action_parameters,
            description: .description,
            enabled: .enabled
        } | with_entries(select(.value != null))]')

        # Create ruleset on destination zone
        create_rs_payload=$(jq -n \
            --arg phase "$rs_phase" \
            --arg name "Migrated rules (${rs_phase})" \
            --argjson rules "$cleaned_rules" \
            '{
                kind: "zone",
                name: $name,
                phase: $phase,
                rules: $rules
            }')

        rs_create=$(cf_api "$CF_DEST_API_TOKEN" "PUT" \
            "/zones/${new_zone_id}/rulesets/phases/${rs_phase}/entrypoint" \
            "$create_rs_payload" 2>/dev/null) || {
            log "$zone_dir" "  ⚠️  Failed to create ruleset for phase ${rs_phase}"
            rules_failed=$((rules_failed + rs_rule_count))
            continue
        }

        if [[ "$rs_create" == API_ERROR* ]]; then
            error_msg=$(echo "$rs_create" | cut -d: -f3-)
            log "$zone_dir" "  ⚠️  Failed to create ruleset for ${rs_phase}: ${error_msg}"
            rules_failed=$((rules_failed + rs_rule_count))
        else
            log "$zone_dir" "  ✅ Created ${rs_rule_count} rule(s) in phase ${rs_phase}"
            rules_created=$((rules_created + rs_rule_count))
        fi
    done < <(echo "$all_rules" | jq -c '.[]')

    # Recreate Page Rules (if any)
    if [[ "$pagerule_count" -gt 0 ]]; then
        log "$zone_dir" "  Recreating ${pagerule_count} Page Rule(s)..."

        while IFS= read -r pagerule; do
            pr_targets=$(echo "$pagerule" | jq '.targets')
            pr_actions=$(echo "$pagerule" | jq '.actions')
            pr_priority=$(echo "$pagerule" | jq '.priority // 1')
            pr_status=$(echo "$pagerule" | jq -r '.status // "active"')

            pr_payload=$(jq -n \
                --argjson targets "$pr_targets" \
                --argjson actions "$pr_actions" \
                --argjson priority "$pr_priority" \
                --arg status "$pr_status" \
                '{targets: $targets, actions: $actions, priority: $priority, status: $status}')

            pr_create=$(cf_api "$CF_DEST_API_TOKEN" "POST" \
                "/zones/${new_zone_id}/pagerules" \
                "$pr_payload" 2>/dev/null) || {
                log "$zone_dir" "  ⚠️  Failed to create a Page Rule"
                rules_failed=$((rules_failed + 1))
                continue
            }

            if [[ "$pr_create" == API_ERROR* ]]; then
                log "$zone_dir" "  ⚠️  Page Rule failed: $(echo "$pr_create" | cut -d: -f3-)"
                rules_failed=$((rules_failed + 1))
            else
                rules_created=$((rules_created + 1))
            fi
        done < <(echo "$pagerules" | jq -c '.[]')
    fi

    log "$zone_dir" "  Rules created: ${rules_created} | Rules failed: ${rules_failed}"

    # ── Step 10: Summary for This Zone ────────────────────────────────────

    echo ""
    log "$zone_dir" "════════════════════════════════════════════"
    log "$zone_dir" "MIGRATION COMPLETE: ${zone_name}"
    log "$zone_dir" "════════════════════════════════════════════"
    log "$zone_dir" "  New zone ID:      ${new_zone_id}"
    log "$zone_dir" "  New nameservers:  ${new_ns}"
    log "$zone_dir" "  DNS records:      ${records_added} imported"
    log "$zone_dir" "  Rules:            ${rules_created} created, ${rules_failed} failed"
    log "$zone_dir" "  Settings:         ${settings_applied} applied, ${settings_failed} failed"
    log "$zone_dir" ""
    log "$zone_dir" "  ⏳ NEXT STEP: Update nameservers at your registrar to:"
    log "$zone_dir" "     ${new_ns}"
    log "$zone_dir" ""
    log "$zone_dir" "  Then trigger activation check via dashboard or:"
    log "$zone_dir" "     curl -X POST \"${CF_API_BASE}/zones/${new_zone_id}/activation_check\" \\"
    log "$zone_dir" "       -H \"Authorization: Bearer \$CF_DEST_API_TOKEN\""
    log "$zone_dir" "════════════════════════════════════════════"

    report ""
    report "  ✅ ${zone_name}"
    report "     New zone: ${new_zone_id}"
    report "     NS: ${new_ns}"
    report "     DNS: ${records_added} | Rules: ${rules_created}/${rules_failed} | Settings: ${settings_applied}/${settings_failed}"

    success_count=$((success_count + 1))
    echo ""
done

# ─── Final Report ─────────────────────────────────────────────────────────────

echo ""
echo "=============================================="
echo " MIGRATION COMPLETE"
echo "=============================================="
echo " Successful:  ${success_count}"
echo " Failed:      ${fail_count}"
echo " Skipped:     ${skip_count} (dry run)"
echo ""
echo " Report:      ${REPORT_FILE}"
echo " Exports:     ${EXPORT_DIR}/"
echo "=============================================="
echo ""

report ""
report "=============================================="
report " TOTALS: ${success_count} success | ${fail_count} failed | ${skip_count} skipped"
report "=============================================="

if [[ "$success_count" -gt 0 && "$DRY_RUN" == false ]]; then
    echo "╔══════════════════════════════════════════════╗"
    echo "║  IMPORTANT: NEXT STEPS                      ║"
    echo "╠══════════════════════════════════════════════╣"
    echo "║                                             ║"
    echo "║  1. Update nameservers at your registrar    ║"
    echo "║     for each migrated zone. The new NS      ║"
    echo "║     pairs are listed above and saved in     ║"
    echo "║     each zone's export directory.           ║"
    echo "║                                             ║"
    echo "║  2. Trigger 'Re-check now' in the dashboard ║"
    echo "║     or use the activation_check API.        ║"
    echo "║                                             ║"
    echo "║  3. Once zones go Active, verify:           ║"
    echo "║     - DNS resolution is correct             ║"
    echo "║     - SSL certificate has provisioned       ║"
    echo "║     - Rules are firing as expected          ║"
    echo "║                                             ║"
    echo "║  4. After validation, clean up the old      ║"
    echo "║     zones from the source account.          ║"
    echo "║                                             ║"
    echo "╚══════════════════════════════════════════════╝"
fi
