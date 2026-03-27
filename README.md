# Cloudflare Zone Audit

This script inventories Cloudflare zones and generates a CSV report to assist with migration planning and account audits. It identifies DNS configurations, SSL/TLS settings, Page Rules, and custom Rulesets.

## Prerequisites

- curl
- jq
- Cloudflare API Token with the following permissions:
  - Zone > Zone > Read
  - Zone > DNS > Read
  - Zone > SSL and Certificates > Read
  - Zone > Firewall Services > Read
  - Zone > Zone Settings > Read

## Usage

The script requires the Cloudflare API Token and Account ID to be set as environment variables.

export CF_API_TOKEN="your-api-token"
export CF_ACCOUNT_ID="your-account-id"

Run the script using the following options:

# Audit only Free zones (default)
./cf-zone-audit.sh

# Audit all zones in the account
./cf-zone-audit.sh --all

# Audit a specific zone by ID
./cf-zone-audit.sh --zone-id <zone_id>

## Output

The script produces a CSV file (cf-zone-audit-YYYY-MM-DD-HHMM.csv) including:
- Zone status and plan type.
- DNS record counts and CNAME-at-apex (flattening) detection.
- DNSSEC, SSL mode, and Edge Certificate status.
- Summaries of active Page Rules and Ruleset Engine configurations.
- Detection of non-default zone settings (Min TLS, Security Level, etc.).