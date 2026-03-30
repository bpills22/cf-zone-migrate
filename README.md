# cf-zone-migrate

A set of bash scripts for migrating Cloudflare zones between accounts. Handles DNS record export/import, zone settings, Page Rules, and all Ruleset Engine phases (Redirect Rules, Cache Rules, Origin Rules, WAF Custom Rules, Transform Rules, etc.).

Built for scenarios where zones need to be split across separate Cloudflare accounts, such as isolating Enterprise zones from Free zones for Account-level feature scoping (Bot Management, WAF, etc.).

## Scripts

| Script | Purpose |
|--------|---------|
| `cf-zone-audit.sh` | Inventories zones in an account. Produces a CSV with DNS record counts, DNSSEC status, SSL/TLS config, rules, CNAME-at-apex detection, and non-default zone settings. |
| `cf-zone-migrate.sh` | Exports zone config from a source account and recreates it on a destination account (DNS, settings, rules). Supports dry run, single zone, and batch modes. |
| `cf-zone-cleanup.sh` | Deletes migrated zones from the source account after verifying they are Active on the destination. |

## Requirements

- `bash` (3.2+, macOS-compatible)
- `curl`
- `jq`
- Cloudflare User API Tokens (created under My Profile > API Tokens)

## API Token Permissions

**Source account (read-only):**

- Zone > Zone > Read
- Zone > DNS > Read
- Zone > SSL and Certificates > Read
- Zone > Firewall Services > Read
- Zone > Zone Settings > Read
- Zone > DNSSEC > Read (optional)

**Destination account (read/write):**

- Zone > Zone > Edit
- Zone > DNS > Edit
- Zone > Firewall Services > Edit
- Zone > Zone Settings > Edit

## Usage

### Audit

Produces a timestamped CSV report of all zones in an account.

```bash
export CF_API_TOKEN="your-api-token"
export CF_ACCOUNT_ID="your-account-id"

# Audit Free zones only (default)
./cf-zone-audit.sh

# Audit all zones
./cf-zone-audit.sh --all

# Audit a single zone
./cf-zone-audit.sh --zone-id <zone_id>
```

Output: `cf-zone-audit-YYYY-MM-DD-HHMM.csv`

The CSV includes: zone name, zone ID, plan, DNS record count, CNAME-at-apex usage, DNSSEC status, SSL mode, edge certificate type, Page Rule count and summary, Ruleset Engine rule count and summary, and non-default zone settings.

The script also prints a Migration Readiness Assessment that flags blockers (DNSSEC active, custom certificates) and informational items.

### Migrate

Exports zone configuration from a source account and recreates it on a destination account.

```bash
export CF_SOURCE_API_TOKEN="source-account-token"
export CF_DEST_API_TOKEN="destination-account-token"
export CF_DEST_ACCOUNT_ID="destination-account-id"

# Dry run (export only, nothing gets created on destination account)
./cf-zone-migrate.sh --zone-id <zone_id> --dry-run

# Migrate a single zone
./cf-zone-migrate.sh --zone-id <zone_id>

# Migrate a batch from a file (one zone ID per line, separated by carriage return/newline)
./cf-zone-migrate.sh --zone-file batch1.txt

# Skip confirmation prompts
./cf-zone-migrate.sh --zone-file batch1.txt --yes
```

Per-zone steps:

1. Exports DNS records (BIND format, preserves proxy status)
2. Exports Page Rules
3. Exports all Ruleset Engine rules (all phases)
4. Exports zone settings
5. Checks SSL/TLS configuration
6. Creates zone on destination account (zone enters Pending status; source zone is unaffected)
7. Imports DNS records via BIND upload
8. Applies zone settings
9. Recreates rules (Ruleset Engine phases and Page Rules)

Output per zone is saved to `./migration-exports/<zone_name>/` and includes the DNS BIND file, rules JSON, settings JSON, new zone ID, new nameservers, and a timestamped migration log.

After the script completes, the zone is in Pending status on the destination account. The final step (updating nameservers at the registrar) is manual and described in the script output.

### Cleanup

Removes migrated zones from the source account. Verifies each zone is Active on the destination before allowing deletion.

```bash
export CF_SOURCE_API_TOKEN="source-account-token"
export CF_DEST_API_TOKEN="destination-account-token"

# Check status (dry run)
./cf-zone-cleanup.sh --from-exports ./migration-exports --dry-run

# Delete migrated zones from source
./cf-zone-cleanup.sh --from-exports ./migration-exports

# Or specify zones directly
./cf-zone-cleanup.sh --zone-name example.com
./cf-zone-cleanup.sh --zone-file migrated-zones.txt
```

The cleanup script requires typing `DELETE` to confirm. It will not delete a zone from the source if the destination zone is not Active.

## Migration Workflow

The intended workflow is:

1. **Audit** -- Run `cf-zone-audit.sh` against the source account to inventory zones and identify any blockers (DNSSEC, custom certs, complex rules).

2. **Migrate in batches** -- Run `cf-zone-migrate.sh` with `--dry-run` first, review the exports, then run without `--dry-run`. Start with a pilot batch of 3-5 zones.

3. **Switch nameservers** -- Update NS records at the domain registrar to the new Cloudflare-assigned nameservers. The migration script outputs the new NS pair for each zone.

4. **Validate** -- Confirm zones are Active on the destination, SSL certificates have provisioned, DNS resolves correctly, and rules are working.

5. **Clean up** -- Run `cf-zone-cleanup.sh` to remove the old zones from the source account.

## Important Notes

**Dual-account coexistence.** A domain can exist on two Cloudflare accounts simultaneously. The source zone stays Active until the registrar nameserver switch is detected, at which point the destination zone goes Active and the source zone transitions to Moved Away.

**DNSSEC.** If DNSSEC is enabled on a zone, it must be disabled at both the registrar (remove the DS record) and Cloudflare before migration. Wait for the DS TTL to expire before proceeding. Failure to do this will break DNS resolution. The audit script flags this.

**TLS certificates.** SSL/TLS certificates do not transfer between accounts. Universal SSL provisions automatically once a zone goes Active (typically within minutes). For zero-downtime TLS, order an Advanced Certificate on the destination zone while it is still in Pending status.

**Zone IDs change.** Zones get new IDs on the destination account. The migration script handles this, but any external integrations referencing zone IDs will need updating.

**CNAME at apex.** CNAME flattening is automatic Cloudflare behavior and requires no special handling during migration. CNAME-at-apex records export and import normally.

**Registrar access.** The nameserver switch must be done at the domain registrar. If domains are spread across multiple registrars, this is the primary time bottleneck. Some registrars support bulk NS updates via API.

## Limitations

- Page Rules API may return errors on zones where Page Rules have been fully deprecated. The script handles this gracefully.
- Some zone settings may fail to apply on the destination if they require a specific plan tier. The script logs these failures and continues.
- The scripts do not migrate account-level resources (Workers scripts, KV namespaces, R2 buckets, etc.).
- Worker Routes are not currently exported/imported. If zones have Worker Routes, these need to be recreated manually.

## References

- [Moving a domain between Cloudflare accounts](https://developers.cloudflare.com/fundamentals/manage-domains/move-domain/)
- [Cloudflare API documentation](https://developers.cloudflare.com/api/)
- [DNS record export/import](https://developers.cloudflare.com/dns/manage-dns-records/how-to/import-and-export/)
- [Universal SSL](https://developers.cloudflare.com/ssl/edge-certificates/universal-ssl/)

## License

MIT
