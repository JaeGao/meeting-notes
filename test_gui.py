"""Checks on what the engine accepts for recording: python3 -m unittest test_gui"""
import json
import os
import tempfile
import unittest
from pathlib import Path

import gui

SOURCES = {
    "displays": [{"id": 1, "width": 2000, "height": 1000, "main": True, "number": 1},
                 {"id": 5, "width": 1920, "height": 1080, "main": False, "number": 2}],
    "windows": [{"id": 7, "title": "Call", "app": "Zoom", "width": 800, "height": 600}],
}


class Recording(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        d = Path(self.tmp.name)
        self.old = (gui.PREVIEW, gui.REC_STATE, gui.REC_CMD)
        gui.PREVIEW, gui.REC_STATE, gui.REC_CMD = d / "preview", d / "state.json", d / "cmd.json"
        gui.PREVIEW.mkdir()
        (gui.PREVIEW / "sources.json").write_text(json.dumps(SOURCES))

    def tearDown(self):
        gui.PREVIEW, gui.REC_STATE, gui.REC_CMD = self.old
        self.tmp.cleanup()

    def choice(self, source, rect=None):
        return gui.source_choice(source, rect)

    def test_sound_only_needs_no_screen(self):
        c, label, err = self.choice({"kind": "none"})
        self.assertEqual((c, label, err), ({"none": True}, "Sound only", None))
        self.assertEqual(gui.choice_args(c), ["--no-screen"])
        self.assertEqual(gui.choice_kind(c), "none")

    def test_no_choice_is_the_main_screen(self):
        c, label, err = self.choice(None)
        self.assertEqual((c, label, err, gui.choice_args(c)), ({}, "Main screen", None, []))

    def test_screens_are_named(self):
        self.assertEqual(self.choice({"kind": "display", "id": 1})[1], "Main screen")
        c, label, _ = self.choice({"kind": "display", "id": 5})
        self.assertEqual((label, gui.choice_args(c), gui.choice_kind(c)),
                         ("Screen 2", ["--display", "5"], "display"))

    def test_an_area_is_turned_into_points(self):
        c, label, err = self.choice({"kind": "display", "id": 1}, {"x": .1, "y": .2, "w": .5, "h": .5})
        self.assertIsNone(err)
        self.assertEqual(c, {"display": 1, "rect": [200, 200, 1000, 500]})
        self.assertEqual(label, "Main screen, part")
        self.assertEqual(gui.choice_args(c), ["--display", "1", "--rect", "200,200,1000,500"])
        self.assertEqual(gui.choice_kind(c), "area")

    def test_a_window_is_named_by_its_app(self):
        c, label, _ = self.choice({"kind": "window", "id": 7})
        self.assertEqual((c, label, gui.choice_kind(c)), ({"window": 7}, "Zoom", "window"))

    def test_refusals(self):
        for source, rect, words in [
            ({"kind": "window", "id": 99}, None, "no longer in the list"),
            ({"kind": "display", "id": 99}, None, "no longer connected"),
            ({"kind": "tape", "id": 1}, None, "no longer connected"),
            ({"kind": "display"}, None, "Choose what to record again"),
            ({"kind": "display", "id": 1}, {"x": 0, "y": 0, "w": .01, "h": .5}, "too small"),
            ({"kind": "display", "id": 1}, {"x": .8, "y": 0, "w": .5, "h": .5}, "off the screen"),
            ({"kind": "display", "id": 1}, {"x": "a"}, "could not be read"),
        ]:
            c, _, err = self.choice(source, rect)
            self.assertIsNone(c, source)
            self.assertIn(words, err)

    def test_switch_is_refused_when_nothing_is_recording(self):
        self.assertEqual(gui.switch_recording({"kind": "none"}, None), (False, "Nothing is being recorded."))
        for state in ("starting", "stopping", "finished", "error"):
            gui.REC_STATE.write_text(json.dumps({"state": state, "pid": os.getpid()}))
            self.assertEqual(gui.switch_recording({"kind": "none"}, None)[0], False, state)
        gui.REC_STATE.write_text(json.dumps({"state": "recording", "pid": 2 ** 22 + 12345}))
        self.assertEqual(gui.switch_recording({"kind": "none"}, None)[0], False, "recorder gone")
        self.assertFalse(gui.REC_CMD.exists())

    def test_switch_refuses_a_bad_choice_without_touching_the_recorder(self):
        gui.REC_STATE.write_text(json.dumps({"state": "recording", "pid": os.getpid()}))
        ok, msg = gui.switch_recording({"kind": "window", "id": 99}, None)
        self.assertFalse(ok)
        self.assertIn("no longer in the list", msg)
        self.assertEqual(gui.switch_recording(None, None), (False, "Choose what to record."))
        self.assertFalse(gui.REC_CMD.exists())

    def test_the_label_follows_what_the_recorder_reports(self):
        gui.rec_opts.update(label="Zoom", kind="window")
        gui.REC_STATE.write_text(json.dumps({"state": "recording", "pid": os.getpid(), "source": "window"}))
        self.assertEqual(gui.recording()["label"], "Zoom")
        gui.REC_STATE.write_text(json.dumps({"state": "recording", "pid": os.getpid(), "source": "none"}))
        self.assertEqual(gui.recording()["label"], "Sound only")


if __name__ == "__main__":
    unittest.main()
