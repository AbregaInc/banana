import unittest
from fixture_policy import matches_fixture


class FixturePolicyTests(unittest.TestCase):
    def test_rejects_missing_or_ignored_fixture(self):
        self.assertFalse(matches_fixture({}, 'varied-v1', 20261009))
        self.assertFalse(matches_fixture({'fixture': None}, 'varied-v1', 20261009))
        data = {'fixture': dict(profile='uniform-v1', seed='20261009', calendarCount=1, hiddenCalendars=[])}
        self.assertFalse(matches_fixture(data, 'varied-v1', 20261009))
        self.assertTrue(matches_fixture(data, 'uniform-v1', 20261009))

    def test_checks_seed_calendars_and_filter(self):
        fixture = dict(profile='varied-v1', seed='20261009', calendarCount=12, hiddenCalendars=[1, 3])
        self.assertTrue(matches_fixture({'fixture': fixture}, 'varied-v1', 20261009, '3,1,1'))
        for key, bad in [('seed', '20261010'), ('calendarCount', 1), ('hiddenCalendars', [])]:
            self.assertFalse(matches_fixture({'fixture': {**fixture, key: bad}}, 'varied-v1', 20261009, '1,3'))


if __name__ == '__main__':
    unittest.main()
