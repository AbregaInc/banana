"""Verify measured zero, missing data and import failure atomicity with tiny USDA-shaped rows."""
import sqlite3
import unittest
from build_food_nutrients import populate, primary_digest

class Archive:
    def __init__(self, values, unit='MG'):
        self.values, self.unit = values, unit
    def nutrient_id_map(self): return {'1180': '1180'}
    def rows(self, name):
        if name == 'nutrient.csv': return iter([{'id': '1180', 'unit_name': self.unit}])
        return iter({'fdc_id': '1', 'nutrient_id': '1180', 'amount': v} for v in self.values)

class NutrientImportTests(unittest.TestCase):
    def setUp(self):
        self.db = sqlite3.connect(':memory:')
        self.db.executescript('CREATE TABLE foods(id TEXT PRIMARY KEY, name TEXT); INSERT INTO foods VALUES("sr:1","Food"); CREATE TABLE portions(food_id TEXT,seq INTEGER); CREATE TABLE metadata(key TEXT PRIMARY KEY,value TEXT);')
        self.config = {'version': 1, 'source': 'USDA', 'sourceURL': 'https://fdc.nal.usda.gov/', 'nutrients': [{'id': '1180', 'key': 'choline', 'name': 'Choline', 'unit': 'mg', 'usdaUnit': 'MG', 'aliases': []}]}
    def tearDown(self): self.db.close()
    def testZeroIsStoredMissingIsAbsentAndIdenticalDuplicatesAreSafe(self):
        before = primary_digest(self.db)
        with self.db: self.assertEqual(populate(self.db, {'sr': Archive(['', '0', '0'])}, self.config), 1)
        self.assertEqual(self.db.execute('SELECT amount FROM food_nutrient').fetchall(), [(0.0,)])
        self.assertEqual(primary_digest(self.db), before)
    def testConflictingMeasurementsRollBackThePreviousCatalog(self):
        with self.db: populate(self.db, {'sr': Archive(['10'])}, self.config)
        with self.assertRaises(ValueError):
            with self.db: populate(self.db, {'sr': Archive(['20', '30'])}, self.config)
        self.assertEqual(self.db.execute('SELECT amount FROM food_nutrient').fetchall(), [(10.0,)])
    def testUnitMismatchAndNonfiniteDataAreRejected(self):
        for archive in [Archive(['10'], 'UG'), Archive(['nan']), Archive(['-1'])]:
            with self.assertRaises(ValueError):
                with self.db: populate(self.db, {'sr': archive}, self.config)

if __name__ == '__main__': unittest.main()
