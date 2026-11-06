#!/usr/bin/env python3
"""Select physical iOS hardware, never a Simulator exposed through CoreDevice."""
import argparse
import json


def select(inventory, requested=None):
    devices = [d for d in inventory.get('result', {}).get('devices', [])
               if d.get('hardwareProperties', {}).get('reality') == 'physical'
               and d.get('hardwareProperties', {}).get('deviceType') in ('iPhone', 'iPad')]
    if requested:
        devices = [d for d in devices if requested in
                   (d.get('identifier'), d.get('hardwareProperties', {}).get('udid'))]
    if len(devices) != 1:
        raise ValueError('Name one physical iPhone or iPad from devicectl; Simulator destinations are not supported.')
    return devices[0]['identifier']


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('inventory')
    parser.add_argument('--device')
    args = parser.parse_args()
    try:
        with open(args.inventory) as source:
            print(select(json.load(source), args.device))
    except (ValueError, KeyError, OSError) as error:
        parser.exit(1, str(error) + '\n')
