#!/usr/bin/env python3
"""Set eligibility for an existing Banana account in an explicitly selected deployment."""
import argparse
import datetime
import pathlib
import re
import subprocess
import tempfile
import time

SERVICE = pathlib.Path(__file__).resolve().parents[1]


def statement(account, feature, enabled, expires_at, now):
    if not re.fullmatch(r'[A-Za-z0-9_-]{1,128}', account):
        raise ValueError('Invalid account identifier')
    if feature not in ('email', 'calendarCloud'):
        raise ValueError('Unknown feature')
    expiry = 'NULL' if expires_at is None else str(int(expires_at))
    if enabled and expires_at is not None and expires_at <= now:
        raise ValueError('Grant expiry must be in the future')
    return f"""INSERT INTO feature_access (account_id, feature, enabled, expires_at, updated_at)
SELECT id, '{feature}', {int(enabled)}, {expiry}, {int(now)} FROM accounts WHERE id = '{account}'
ON CONFLICT(account_id, feature) DO UPDATE SET enabled=excluded.enabled,
expires_at=excluded.expires_at, updated_at=excluded.updated_at;
SELECT changes() AS accounts_updated;
"""


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
    # Temporary files have owner-only access and are removed on both success and failure.
    with tempfile.NamedTemporaryFile(mode='w', suffix='.sql') as query:
        query.write(sql)
        query.flush()
        database = 'banana-service' if args.environment == 'stable' else 'banana-service-beta'
        command = ['wrangler', 'd1', 'execute', database, '--remote', '--file', query.name]
        if args.environment == 'beta':
            command += ['--env', 'beta']
        subprocess.run(command, cwd=SERVICE, check=True)
    print('Check accounts_updated is 1; 0 means this account does not exist in the selected environment.')


if __name__ == '__main__':
    main()
