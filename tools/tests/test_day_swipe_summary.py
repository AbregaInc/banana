import importlib.util
from pathlib import Path
import plistlib
import tempfile
import unittest


script = Path(__file__).resolve().parents[1] / "physical-stress-tests" / "summarize-day-swipes.py"
spec = importlib.util.spec_from_file_location("day_swipes", script)
day_swipes = importlib.util.module_from_spec(spec)
spec.loader.exec_module(day_swipes)


class DaySwipeSummaryTests(unittest.TestCase):
    def state(self, day, offset, window_y, count):
        return {"page": day, "visibleIDs": [day], "y": offset, "windowY": window_y,
                "width": 390, "height": 600, "visibleCells": 5, "descriptors": 12,
                **{key: count for key in day_swipes.COUNTERS}}

    def test_window_and_scroll_adjustment_preserve_the_same_hour(self):
        data = [self.state("a", 560, 100, 1), self.state("b", 580, 120, 4),
                self.state("c", 580, 135, 6), self.state("b", 580, 120, 9),
                self.state("a", 560, 100, 12)]
        result = day_swipes.summarize(data)
        self.assertTrue(result["completedRoundTrip"])
        self.assertEqual([row["rulerShiftFromStartPoints"] for row in result["swipes"]], [0, 15, 0, 0])
        self.assertEqual([row["work"]["reloads"] for row in result["swipes"]], [3, 2, 3, 3])

    def test_settling_uses_two_callbacks_for_the_current_gesture(self):
        data = [self.state(day, 560, 100, count) for count, day in enumerate("abcba")]
        data[1]["lastDayDrag"] = {"release": 100, "settled": 100.25}
        data[2]["lastDayDrag"] = data[1]["lastDayDrag"]
        data[3]["lastDayDrag"] = {"release": 102}
        data[4]["lastDayDrag"] = {"release": 104, "settled": 103}
        self.assertEqual([s["releaseToSettledMS"] for s in day_swipes.summarize(data)["swipes"]],
                         [250, None, None, None])

    def test_missing_or_changed_return_events_do_not_complete_round_trip(self):
        self.assertFalse(day_swipes.summarize([])["completedRoundTrip"])
        data = [self.state(day, 560, 100, count) for count, day in enumerate("abcba")]
        data[-1]["visibleIDs"] = ["another-event"]
        self.assertFalse(day_swipes.summarize(data)["completedRoundTrip"])


motion_script = script.with_name("day-swipe-motion.py")
motion_spec = importlib.util.spec_from_file_location("day_swipe_motion", motion_script)
motion = importlib.util.module_from_spec(motion_spec)
motion_spec.loader.exec_module(motion)


class DaySwipeRecordingTests(unittest.TestCase):
    def test_landscape_drag_is_vertical_in_archived_device_coordinates(self):
        points = [{"offset": t, "coordinate.x": 40, "coordinate.y": y}
                  for t, y in [(0, 100), (0.5, 200), (1.0, 300)]]
        with tempfile.TemporaryDirectory() as temp:
            folder = Path(temp)
            (folder / "touch").write_bytes(plistlib.dumps({"$objects": points}))
            attachments = [{"suggestedHumanReadableName": "Synthesized Event",
                            "timestamp": 9, "exportedFileName": "touch"}]
            self.assertEqual(motion.horizontal_drags(attachments, folder, 3, landscape=True), [(5, 6, 200)])
            self.assertEqual(motion.horizontal_drags(attachments, folder, 3, landscape=False), [])

    def test_stationary_ruler_is_distinct_from_event_motion_and_release(self):
        result = motion.examine([0, 0.3, 0.6, 1.1], {"events": [0, 4, 7, 3], "ruler": [0, 0, 0, 2]},
                                start=0, end=1, distance=200)
        drag = result["windows"]["duringDrag"]
        self.assertEqual(drag["recordedSamples"], 2)
        self.assertEqual(drag["changedSamples"], {"events": 2, "ruler": 0})
        self.assertEqual(result["windows"]["aroundRelease"]["changedSamples"], {"events": 1, "ruler": 1})
