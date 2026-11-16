#!/usr/bin/env python3
"""Add measured micronutrients to the existing catalog without replacing food IDs or macros.

Uses the same USDA archives as build_food_database.py. Missing measurements stay absent;
recorded zeros stay zero. Branded/label foods without USDA measurements remain unknown.
"""
import argparse
import hashlib
import json
import math
from pathlib import Path
import sqlite3

DEFINITIONS = Path(__file__).with_name('food-nutrients.json')


def primary_digest(db):
    result = hashlib.sha256()
    for table, order in [('foods', 'id'), ('portions', 'food_id,seq')]:
        for row in db.execute(f'SELECT * FROM {table} ORDER BY {order}'):
            result.update(json.dumps(row, ensure_ascii=False, separators=(',', ':')).encode())
    return result.hexdigest()


def populate(db, archives, definitions=None):
    config = definitions or json.loads(DEFINITIONS.read_text())
    nutrients = {n['id']: n for n in config['nutrients']}
    if len(nutrients) != len(config['nutrients']):
        raise ValueError('Duplicate nutrient ID')
    before = primary_digest(db)
    if not db.in_transaction:
        db.execute('BEGIN IMMEDIATE')
    db.execute('DROP TABLE IF EXISTS food_nutrient')
    db.execute('DROP TABLE IF EXISTS nutrient')
    db.execute('CREATE TABLE nutrient(id TEXT PRIMARY KEY, key TEXT NOT NULL UNIQUE, name TEXT NOT NULL, unit TEXT NOT NULL, aliases TEXT NOT NULL, reference_json TEXT) WITHOUT ROWID')
    db.execute('CREATE TABLE food_nutrient(food_id TEXT NOT NULL, nutrient_id TEXT NOT NULL, amount REAL NOT NULL CHECK(amount>=0), PRIMARY KEY(food_id,nutrient_id)) WITHOUT ROWID')
    for n in nutrients.values():
        db.execute('INSERT INTO nutrient VALUES(?,?,?,?,?,?)', (n['id'], n['key'], n['name'], n['unit'], json.dumps(n['aliases']), json.dumps(n['reference']) if n.get('reference') else None))
    known = {row[0] for row in db.execute('SELECT id FROM foods')}
    count = 0
    for prefix, archive in archives.items():
        mapping = archive.nutrient_id_map()
        for n in archive.rows('nutrient.csv'):
            if n['id'] in nutrients and n['unit_name'].upper() != nutrients[n['id']]['usdaUnit']:
                raise ValueError(f'Unexpected unit for nutrient {n["id"]}')
        for row in archive.rows('food_nutrient.csv'):
            food = prefix + ':' + row['fdc_id']
            nutrient = mapping.get(row['nutrient_id'])
            if food not in known or nutrient not in nutrients or row['amount'] == '':
                continue
            value = float(row['amount'])
            if not math.isfinite(value) or value < 0:
                raise ValueError('Invalid measured nutrient value')
            inserted = db.execute('INSERT INTO food_nutrient VALUES(?,?,?) ON CONFLICT DO NOTHING', (food, nutrient, value)).rowcount
            if not inserted and db.execute('SELECT amount FROM food_nutrient WHERE food_id=? AND nutrient_id=?', (food, nutrient)).fetchone()[0] != value:
                raise ValueError(f'Conflicting source measurements for {food}/{nutrient}')
            count += inserted
    if primary_digest(db) != before:
        raise ValueError('Primary food data changed')
    for key, value in [('micronutrient_schema', str(config['version'])), ('micronutrient_source', config['source']), ('micronutrient_source_url', config['sourceURL']), ('micronutrient_values', str(count))]:
        db.execute('INSERT OR REPLACE INTO metadata VALUES(?,?)', (key, value))
    return count


def main():
    from build_food_database import Archive
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('database', type=Path)
    p.add_argument('survey', type=Path)
    p.add_argument('sr', type=Path)
    p.add_argument('foundation', type=Path)
    a = p.parse_args()
    with sqlite3.connect(a.database) as db:
        count = populate(db, {'fndds': Archive(a.survey), 'sr': Archive(a.sr), 'foundation': Archive(a.foundation)})
        if db.execute('PRAGMA integrity_check').fetchone()[0] != 'ok':
            raise ValueError('Catalog failed integrity check')
    print(f'{count} measured nutrient values; primary food/portion digest unchanged')


if __name__ == '__main__':
    main()
