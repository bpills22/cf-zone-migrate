#!/usr/bin/env bash
#
# cf-zone-audit.sh
# ================
# Cloudflare Zone Migration Audit Script
#
# Inventories all zones (or only Free zones) in a Cloudflare account and
# produces a CSV report covering DNS records, DNSSEC, SSL/TLS, Page Rules,
# Rulesets, CNAME-at-apex usage, and non-default zone settings.
#
# Prerequisites:
#   - curl, jq installed
#   - Cloudflare API Token with these permissions (scoped to the target account):
#       Zone > Zone > Read
#       Zone > DNS > Read
#       Zone > SSL and Certificates > Read
#       Zone > Firewall Services > Read
#       Zone > Zone Settings > Read
#
# Usage:
#   export CF_API_TOKEN="your-api-token-here"
#   export CF_ACCOUNT_ID="your-account-id-here"
#   ./cf-zone-audit.sh                  # Audit only Free zones (default)
#   ./cf-zone-audit.sh --all            # Audit ALL zones in the account
#   ./cf-zone-audit.sh --zone-id abc123 # Audit a single zone by ID
#
# Output:
#   - cf-zone-audit-YYYY-MM-DD.csv      (machine-readable report)
#   - Terminal summary with key findings
#

set -euo pipefail

# ─── Configuration ────────────────────────────────────────────────────────────

CF_API_TOKEN="${CF_API_TOKEN:?ERROR: Set CF_API_TOKEN environment variable}"
CF_ACCOUNT_ID="${CF_ACCOUNT_ID:?ERROR: Set CF_ACCOUNT_ID environment variable}"
CF_API_BASE="https://api.cloudflare.com/client/v4"

# Parse arguments
FILTER_MODE="free"  # default: only Free zones
SINGLE_ZONE_ID=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --all)
            FILTER_MODE="all"
            shift
            ;;
        --zone-id)
            FILTER_MODE="single"
            SINGLE_ZONE_ID="${2:?ERROR: --zone-id requires a zone ID argument}"
            shift 2
            ;;
        -h|--help)
            head -28 "$0" | tail -24
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

DATE_STAMP=$(date +%Y-%m-%d)
TIME_STAMP=$(date +%H%M)
CSV_FILE="cf-zone-audit-${DATE_STAMP}-${TIME_STAMP}.csv"
RATE_LIMIT_DELAY=0.25  # seconds between API calls (be gentle)

# ─── Helpers ──────────────────────────────────────────────────────────────────

cf_api() {
    local endpoint="$1"
    local response
    response=$(curl -s -w "\n%{http_code}" \
        -H "Authorization: Bearer ${CF_API_TOKEN}" \
        -H "Content-Type: application/json" \
        "${CF_API_BASE}${endpoint}")
    
    local http_code
    http_code=$(echo "$response" | tail -1)
    local body
    body=$(echo "$response" | sed '$d')
    
    if [[ "$http_code" -ge 400 ]]; then
        echo "API Error (HTTP ${http_code}) on ${endpoint}" >&2
        echo "$body" | jq -r '.errors[]?.message // "Unknown error"' 2>/dev/null >&2
        echo "{}"
        return 1
    fi
    
    echo "$body"
    sleep "$RATE_LIMIT_DELAY"
}

# Paginated fetch for list endpoints - collects all results
cf_api_paginated() {
    local endpoint="$1"
    local all_results="[]"
    local page=1
    local per_page=50
    local total_pages=1

    while [[ $page -le $total_pages ]]; do
        local sep="?"
        [[ "$endpoint" == *"?"* ]] && sep="&"
        
        local response
        response=$(cf_api "${endpoint}${sep}page=${page}&per_page=${per_page}") || return 1
        
        local page_results
        page_results=$(echo "$response" | jq -r '.result // []')
        all_results=$(echo "$all_results" "$page_results" | jq -s 'add')
        
        total_pages=$(echo "$response" | jq -r '.result_info.total_pages // 1')
        page=$((page + 1))
    done

    echo "$all_results"
}

escape_csv() {
    local val="$1"
    # If value contains comma, quote, or newline, wrap in quotes and escape internal quotes
    if [[ "$val" == *","* || "$val" == *'"'* || "$val" == *$'\n'* ]]; then
        val="${val//\"/\"\"}"
        val="\"${val}\""
    fi
    echo -n "$val"
}

# ─── Fetch Zone List ─────────────────────────────────────────────────────────

echo "=============================================="
echo " Cloudflare Zone Migration Audit"
echo " Account: ${CF_ACCOUNT_ID}"
echo " Date:    ${DATE_STAMP}"
echo " Filter:  ${FILTER_MODE}"
echo "=============================================="
echo ""

if [[ "$FILTER_MODE" == "single" ]]; then
    echo "Fetching single zone ${SINGLE_ZONE_ID}..."
    zone_response=$(cf_api "/zones/${SINGLE_ZONE_ID}")
    ZONES=$(echo "$zone_response" | jq '[.result]')
else
    echo "Fetching zone list from account..."
    ZONES=$(cf_api_paginated "/zones?account.id=${CF_ACCOUNT_ID}&status=active")
    
    if [[ "$FILTER_MODE" == "free" ]]; then
        ZONES=$(echo "$ZONES" | jq '[.[] | select(.plan.name == "Free Website" or .plan.legacy_id == "free")]')
    fi
fi

ZONE_COUNT=$(echo "$ZONES" | jq 'length')
echo "Found ${ZONE_COUNT} zone(s) to audit."
echo ""

if [[ "$ZONE_COUNT" -eq 0 ]]; then
    echo "No zones found matching criteria. Exiting."
    exit 0
fi

# ─── CSV Header ───────────────────────────────────────────────────────────────

cat > "$CSV_FILE" << 'HEADER'
zone_name,zone_id,plan,status,dns_record_count,cname_at_apex,cname_apex_targets,dnssec_status,ssl_mode,universal_ssl_enabled,edge_cert_type,edge_cert_status,page_rule_count,page_rule_summary,ruleset_count,ruleset_summary,non_default_settings,notes
HEADER

# ─── Counters for Summary ────────────────────────────────────────────────────

total_dns_records=0
zones_with_cname_apex=0
zones_with_dnssec=0
zones_with_pagerules=0
zones_with_rulesets=0
zones_with_acm=0
zones_with_custom_ssl=0
zones_with_nondefault_settings=0
zone_errors=0

# ─── Audit Each Zone ─────────────────────────────────────────────────────────

zone_index=0
while IFS= read -r zone; do
    zone_index=$((zone_index + 1))
    
    zone_name=$(echo "$zone" | jq -r '.name')
    zone_id=$(echo "$zone" | jq -r '.id')
    plan_name=$(echo "$zone" | jq -r '.plan.name // .plan.legacy_id')
    zone_status=$(echo "$zone" | jq -r '.status')
    
    echo "[${zone_index}/${ZONE_COUNT}] Auditing: ${zone_name} (${zone_id})"
    
    notes=""
    
    # ── DNS Records ───────────────────────────────────────────────────────
    dns_records=$(cf_api_paginated "/zones/${zone_id}/dns_records") || dns_records="[]"
    dns_count=$(echo "$dns_records" | jq 'length')
    total_dns_records=$((total_dns_records + dns_count))
    
    # Check for CNAME at apex (CNAME flattening)
    cname_at_apex="No"
    cname_apex_targets=""
    apex_cnames=$(echo "$dns_records" | jq -r --arg zn "$zone_name" \
        '[.[] | select(.type == "CNAME" and (.name == $zn or .name == ("@")))] | length')
    if [[ "$apex_cnames" -gt 0 ]]; then
        cname_at_apex="Yes"
        zones_with_cname_apex=$((zones_with_cname_apex + 1))
        cname_apex_targets=$(echo "$dns_records" | jq -r --arg zn "$zone_name" \
            '[.[] | select(.type == "CNAME" and (.name == $zn or .name == ("@"))) | .content] | join("; ")')
    fi
    
    # ── DNSSEC ────────────────────────────────────────────────────────────
    dnssec_response=$(cf_api "/zones/${zone_id}/dnssec") || dnssec_response="{}"
    dnssec_status=$(echo "$dnssec_response" | jq -r '.result.status // "unknown"')
    if [[ "$dnssec_status" == "active" ]]; then
        zones_with_dnssec=$((zones_with_dnssec + 1))
        notes="${notes}DNSSEC_ACTIVE; "
    fi
    
    # ── SSL/TLS ───────────────────────────────────────────────────────────
    ssl_setting=$(cf_api "/zones/${zone_id}/settings/ssl") || ssl_setting="{}"
    ssl_mode=$(echo "$ssl_setting" | jq -r '.result.value // "unknown"')
    
    # Check Universal SSL status
    ussl_response=$(cf_api "/zones/${zone_id}/ssl/universal/settings") || ussl_response="{}"
    universal_ssl=$(echo "$ussl_response" | jq -r '.result.enabled // "unknown"')
    
    # Check edge certificates
    edge_certs=$(cf_api_paginated "/zones/${zone_id}/ssl/certificate_packs?status=active") || edge_certs="[]"
    
    edge_cert_type="universal"
    edge_cert_status="active"
    
    # Detect ACM or custom certs
    has_acm=$(echo "$edge_certs" | jq '[.[] | select(.type == "advanced")] | length')
    has_custom=$(echo "$edge_certs" | jq '[.[] | select(.type == "custom")] | length')
    
    if [[ "$has_acm" -gt 0 ]]; then
        edge_cert_type="advanced_certificate_manager"
        zones_with_acm=$((zones_with_acm + 1))
        notes="${notes}ACM_CERT; "
    fi
    if [[ "$has_custom" -gt 0 ]]; then
        edge_cert_type="custom"
        zones_with_custom_ssl=$((zones_with_custom_ssl + 1))
        notes="${notes}CUSTOM_CERT; "
    fi
    
    cert_statuses=$(echo "$edge_certs" | jq -r '[.[] | .status] | unique | join(", ")' 2>/dev/null || echo "unknown")
    if [[ -n "$cert_statuses" && "$cert_statuses" != "null" ]]; then
        edge_cert_status="$cert_statuses"
    fi
    
    # ── Page Rules ────────────────────────────────────────────────────────
    # Note: Page Rules API may return 400 on some zones (deprecated/not available).
    # Try with status filter first, fall back to without, then give up gracefully.
    pagerules_response=$(cf_api "/zones/${zone_id}/pagerules?status=active" 2>/dev/null) \
        || pagerules_response=$(cf_api "/zones/${zone_id}/pagerules" 2>/dev/null) \
        || pagerules_response='{"result":[]}'
    pagerules=$(echo "$pagerules_response" | jq -r '.result // []')
    pagerule_count=$(echo "$pagerules" | jq 'length' 2>/dev/null || echo "0")
    
    pagerule_summary=""
    if [[ "$pagerule_count" -gt 0 ]]; then
        zones_with_pagerules=$((zones_with_pagerules + 1))
        # Summarize each page rule: target pattern + actions
        pagerule_summary=$(echo "$pagerules" | jq -r \
            '[.[] | "\(.targets[0].constraint.value) -> \([.actions[].id] | join(","))"] | join(" | ")' 2>/dev/null || echo "parse_error")
    fi
    
    # ── Rulesets (all Ruleset Engine phases) ─────────────────────────────
    rulesets_response=$(cf_api "/zones/${zone_id}/rulesets") || rulesets_response="{}"
    rulesets=$(echo "$rulesets_response" | jq -r '.result // []')
    
    # Filter to rulesets that have customer-defined rules (skip managed/default)
    # Phases to check: WAF Custom Rules, Redirect Rules, Transform Rules (URL rewrite +
    # request/response header mods), Cache Rules, Config Rules, Origin Rules, Rate Limiting,
    # Snippets, Compression Rules
    custom_rulesets=$(echo "$rulesets" | jq '[.[] | select(.kind == "zone" and (.phase | test("custom|redirect|transform|cache|config|origin|ratelimit|snippet|compression") ))]')
    ruleset_count=0
    ruleset_summary=""
    
    if [[ $(echo "$custom_rulesets" | jq 'length') -gt 0 ]]; then
        # For each custom ruleset, fetch its rules
        ruleset_details=""
        while IFS= read -r rs_id; do
            rs_response=$(cf_api "/zones/${zone_id}/rulesets/${rs_id}") || continue
            rs_name=$(echo "$rs_response" | jq -r '.result.name // "unnamed"')
            rs_phase=$(echo "$rs_response" | jq -r '.result.phase // "unknown"')
            rs_rule_count=$(echo "$rs_response" | jq -r '.result.rules // [] | length')
            
            if [[ "$rs_rule_count" -gt 0 ]]; then
                ruleset_count=$((ruleset_count + rs_rule_count))
                rs_rule_names=$(echo "$rs_response" | jq -r \
                    '[.result.rules[] | .description // .action // "unnamed"] | join(", ")' 2>/dev/null || echo "")
                ruleset_details="${ruleset_details}${rs_phase}(${rs_rule_count}): ${rs_rule_names} | "
            fi
        done < <(echo "$custom_rulesets" | jq -r '.[].id')
        
        if [[ "$ruleset_count" -gt 0 ]]; then
            zones_with_rulesets=$((zones_with_rulesets + 1))
            ruleset_summary="${ruleset_details% | }"
        fi
    fi
    
    # ── Zone Settings (detect non-defaults) ───────────────────────────────
    settings_response=$(cf_api "/zones/${zone_id}/settings") || settings_response="{}"
    settings=$(echo "$settings_response" | jq -r '.result // []')
    
    # Key settings to check for non-default values
    # Defaults for Free zones: ssl=flexible(sometimes off), min_tls=1.0,
    # always_use_https=off, security_level=medium, cache_level=aggressive
    non_defaults=""
    
    always_https=$(echo "$settings" | jq -r '.[] | select(.id == "always_use_https") | .value' 2>/dev/null)
    if [[ "$always_https" == "on" ]]; then
        non_defaults="${non_defaults}always_use_https=on; "
    fi
    
    min_tls=$(echo "$settings" | jq -r '.[] | select(.id == "min_tls_version") | .value' 2>/dev/null)
    if [[ -n "$min_tls" && "$min_tls" != "1.0" ]]; then
        non_defaults="${non_defaults}min_tls=${min_tls}; "
    fi
    
    security_level=$(echo "$settings" | jq -r '.[] | select(.id == "security_level") | .value' 2>/dev/null)
    if [[ -n "$security_level" && "$security_level" != "medium" ]]; then
        non_defaults="${non_defaults}security_level=${security_level}; "
    fi
    
    auto_minify=$(echo "$settings" | jq -r '.[] | select(.id == "minify") | .value | to_entries | map(select(.value == "on") | .key) | join(",")' 2>/dev/null)
    if [[ -n "$auto_minify" ]]; then
        non_defaults="${non_defaults}minify=${auto_minify}; "
    fi
    
    rocket_loader=$(echo "$settings" | jq -r '.[] | select(.id == "rocket_loader") | .value' 2>/dev/null)
    if [[ "$rocket_loader" == "on" ]]; then
        non_defaults="${non_defaults}rocket_loader=on; "
    fi
    
    browser_cache_ttl=$(echo "$settings" | jq -r '.[] | select(.id == "browser_cache_ttl") | .value' 2>/dev/null)
    if [[ -n "$browser_cache_ttl" && "$browser_cache_ttl" != "14400" ]]; then
        non_defaults="${non_defaults}browser_cache_ttl=${browser_cache_ttl}; "
    fi
    
    if [[ -n "$non_defaults" ]]; then
        zones_with_nondefault_settings=$((zones_with_nondefault_settings + 1))
    fi
    
    # ── Flag CNAME at apex in notes ───────────────────────────────────────
    if [[ "$cname_at_apex" == "Yes" ]]; then
        notes="${notes}CNAME_FLATTENING; "
    fi
    
    # ── Write CSV Row ─────────────────────────────────────────────────────
    # Clean up summaries for CSV (replace commas in summaries with semicolons)
    pagerule_summary_csv=$(echo "$pagerule_summary" | tr ',' ';')
    ruleset_summary_csv=$(echo "$ruleset_summary" | tr ',' ';')
    non_defaults_csv=$(echo "$non_defaults" | sed 's/; $//')
    notes_csv=$(echo "$notes" | sed 's/; $//')
    
    printf '%s,%s,%s,%s,%s,%s,"%s",%s,%s,%s,%s,%s,%s,"%s",%s,"%s","%s","%s"\n' \
        "$zone_name" \
        "$zone_id" \
        "$plan_name" \
        "$zone_status" \
        "$dns_count" \
        "$cname_at_apex" \
        "$cname_apex_targets" \
        "$dnssec_status" \
        "$ssl_mode" \
        "$universal_ssl" \
        "$edge_cert_type" \
        "$edge_cert_status" \
        "$pagerule_count" \
        "$pagerule_summary_csv" \
        "$ruleset_count" \
        "$ruleset_summary_csv" \
        "$non_defaults_csv" \
        "$notes_csv" \
        >> "$CSV_FILE"
    
    # Terminal progress
    flags=""
    [[ "$cname_at_apex" == "Yes" ]] && flags="${flags} [CNAME@APEX]"
    [[ "$dnssec_status" == "active" ]] && flags="${flags} [DNSSEC!]"
    [[ "$has_acm" -gt 0 ]] && flags="${flags} [ACM]"
    [[ "$has_custom" -gt 0 ]] && flags="${flags} [CUSTOM-CERT]"
    [[ "$pagerule_count" -gt 0 ]] && flags="${flags} [${pagerule_count} PageRules]"
    [[ "$ruleset_count" -gt 0 ]] && flags="${flags} [${ruleset_count} Rules]"
    [[ -n "$non_defaults" ]] && flags="${flags} [NonDefault Settings]"
    
    echo "   ${dns_count} DNS records | SSL: ${ssl_mode} | Cert: ${edge_cert_type}${flags}"
    
done < <(echo "$ZONES" | jq -c '.[]')

# ─── Summary ──────────────────────────────────────────────────────────────────

echo ""
echo "=============================================="
echo " AUDIT SUMMARY"
echo "=============================================="
echo " Zones audited:                ${ZONE_COUNT}"
echo " Total DNS records:            ${total_dns_records}"
echo " Zones with CNAME at apex:     ${zones_with_cname_apex}"
echo " Zones with DNSSEC active:     ${zones_with_dnssec}"
echo " Zones with Page Rules:        ${zones_with_pagerules}"
echo " Zones with Custom Rulesets:   ${zones_with_rulesets}"
echo " Zones with ACM certs:         ${zones_with_acm}"
echo " Zones with Custom SSL certs:  ${zones_with_custom_ssl}"
echo " Zones with non-default settings: ${zones_with_nondefault_settings}"
echo ""
echo " Report saved to: ${CSV_FILE}"
echo "=============================================="
echo ""

# ─── Migration Readiness Assessment ──────────────────────────────────────────

echo "MIGRATION READINESS FLAGS:"
if [[ "$zones_with_dnssec" -gt 0 ]]; then
    echo "  ⚠️  WARNING: ${zones_with_dnssec} zone(s) have DNSSEC enabled."
    echo "     DNSSEC must be disabled BEFORE migration. This is a blocker."
fi
if [[ "$zones_with_acm" -gt 0 ]]; then
    echo "  ⚠️  ATTENTION: ${zones_with_acm} zone(s) use Advanced Certificate Manager."
    echo "     ACM must be purchased on the new account and certs pre-ordered."
fi
if [[ "$zones_with_custom_ssl" -gt 0 ]]; then
    echo "  ⚠️  ATTENTION: ${zones_with_custom_ssl} zone(s) have custom SSL certificates."
    echo "     Custom certs must be re-uploaded to the new account."
fi
if [[ "$zones_with_cname_apex" -gt 0 ]]; then
    echo "  ℹ️  INFO: ${zones_with_cname_apex} zone(s) use CNAME at apex (flattening)."
    echo "     These will import correctly - flattening is automatic."
fi
if [[ "$zones_with_pagerules" -gt 0 || "$zones_with_rulesets" -gt 0 ]]; then
    echo "  ℹ️  INFO: Some zones have Page Rules or custom rulesets that need recreation."
    echo "     Review the CSV for details."
fi
if [[ "$zones_with_dnssec" -eq 0 && "$zones_with_custom_ssl" -eq 0 ]]; then
    echo "  ✅ No major blockers detected. Migration looks straightforward."
fi

echo ""
echo "Done! Review ${CSV_FILE} and share with the customer for sign-off."