#!/usr/bin/env python3
"""Set eligibility for an existing Banana account in an explicitly selected deployment."""
import argparse
import datetime
import json
import pathlib
import re
import subprocess
import time

SERVICE = pathlib.Path(__file__).resolve().parents[1]
# Match the verified deployment CLI rather than an unrelated global installation.
WRANGLER = ['npx', '--yes', 'wrangler@4.158.0']


def statement(account, feature, enabled, expires_at, now):
    if not re.fullmatch(r'[A-Za-z0-9_-]{1,128}', account):
        raise ValueError('Invalid account identifier')
    if feature not in ('email', 'calendarCloud'):
        raise ValueError('Unknown feature')
    ready = " AND NOT EXISTS (SELECT 1 FROM devices WHERE account_id=accounts.id AND provider_protocol<1)" if enabled else ""
    expiry = 'NULL' if expires_at is None else str(int(expires_at))
    if enabled and expires_at is not None and expires_at <= now:
        raise ValueError('Grant expiry must be in the future')
    return f"""INSERT INTO feature_access (account_id, feature, enabled, expires_at, updated_at)
SELECT id, '{feature}', {int(enabled)}, {expiry}, {int(now)} FROM accounts WHERE id = '{account}'{ready}
ON CONFLICT(account_id, feature) DO UPDATE SET enabled=excluded.enabled,
expires_at=excluded.expires_at, updated_at=excluded.updated_at;
SELECT changes() AS accounts_updated,
 EXISTS(SELECT 1 FROM accounts WHERE id = '{account}') AS account_exists,
 (SELECT COUNT(*) FROM devices WHERE account_id = '{account}' AND provider_protocol<1) AS outdated_devices;
"""


def verify_result(payload):
    """A refused grant is a failure, not a successful command with a zero buried in its output."""
    if not isinstance(payload, list) or any(item.get('success') is not True for item in payload):
        raise ValueError('The service did not confirm the update.')
    rows = [row for item in payload for row in item.get('results', []) if 'accounts_updated' in row]
    if len(rows) != 1:
        raise ValueError('The service returned no unambiguous update receipt.')
    row = rows[0]
    if row['accounts_updated'] == 1:
        return
    if row.get('account_exists') == 0:
        raise ValueError('No update: this account does not exist in the selected environment.')
    count = row.get('outdated_devices', 0)
    if isinstance(count, int) and count > 0:
        raise ValueError(f'No update: {count} registered device(s) must run a compatible build before access can be granted.')
    raise ValueError('The service did not update exactly one account.')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--environment', required=True, choices=['stable', 'beta'])
    parser.add_argument('--account', required=True, help='Existing Banana account ID in this environment, not a Google email')
    parser.add_argument('--feature', required=True, choices=['email', 'calendarCloud'])
    parser.add_argument('--access', required=True, choices=['grant', 'revoke'])
    parser.add_argument('--expires', help='Grant expiry as an ISO 8601 timestamp with timezone')
    parser.add_argument('--apply', action='store_true', help='Execute remotely; otherwise validate only')
    args = parser.parse_args()
    expires = None
    if args.expires:
        value = datetime.datetime.fromisoformat(args.expires.replace('Z', '+00:00'))
        if value.tzinfo is None:
            parser.error('--expires requires a timezone')
        expires = int(value.timestamp() * 1000)
    sql = statement(args.account, args.feature, args.access == 'grant', expires, int(time.time() * 1000))
    if not args.apply:
        print(f'Validated {args.access} for {args.feature} in {args.environment}; no changes made.')
        return
    # Remote --file uses D1's import flow and does not return the SELECT receipt.
    # Pass this small statement as an argv value, never through a shell.
    database = 'banana-service' if args.environment == 'stable' else 'banana-service-beta'
    command = [*WRANGLER, 'd1', 'execute', database, '--remote', '--command', sql, '--json']
    if args.environment == 'beta':
        command += ['--env', 'beta']
    result = subprocess.run(command, cwd=SERVICE, capture_output=True, text=True)
    if result.returncode:
        parser.exit(1, 'The service request failed; the update is not confirmed.\n')
    try:
        verify_result(json.loads(result.stdout))
    except (ValueError, TypeError, AttributeError) as error:
        parser.exit(1, str(error) + '\n')
    print(f'Confirmed {args.access} for {args.feature} in {args.environment}.')


if __name__ == '__main__':
    main()
