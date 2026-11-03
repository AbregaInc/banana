import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location('judge', Path(__file__).with_name('judge.py'))
judge = importlib.util.module_from_spec(spec)
spec.loader.exec_module(judge)

class CouncilTests(unittest.TestCase):
    def summarize(self, ballots):
        result = {'judges': ballots}
        judge.summarize_pair(result, ['one', 'two'], ['opus', 'sol', 'argon'])
        return result

    def ballot(self, winner='after'):
        return {'states': {name: {'winner': winner} for name in ['one', 'two']}}

    def test_two_provider_failures_cannot_report_a_win(self):
        result = self.summarize({'opus': self.ballot(), 'sol': {'error': 'offline'}, 'argon': {'error': 'offline'}})
        self.assertFalse(result['valid_comparison'])
        self.assertIsNone(result['after_win_rate'])

    def test_partial_ballot_does_not_count_towards_quorum(self):
        result = self.summarize({'opus': self.ballot(), 'sol': {'states': {'one': {'winner': 'after'}}}})
        self.assertFalse(result['valid_comparison'])
        self.assertEqual(result['tally']['after'], 2)

    def test_complete_majority_counts_ties_and_losses(self):
        result = self.summarize({'opus': self.ballot(), 'sol': self.ballot('before'), 'argon': {'error': 'offline'}})
        self.assertTrue(result['valid_comparison'])
        self.assertEqual(result['after_win_rate'], .5)

if __name__ == '__main__':
    unittest.main()
