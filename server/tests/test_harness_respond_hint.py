"""Contract tests for the play-console respond/dismiss routing (#46a).

The harness hint is client-facing; this keeps it from drifting back to the
misleading `{"dismiss":{...}}` shape that made the round-3 play agent puzzle
over a native popup.
"""
import importlib.util
import unittest
from pathlib import Path

HARNESS = Path(__file__).resolve().parents[2] / "harness/console/agent-play.py"


def load_harness():
    spec = importlib.util.spec_from_file_location("tome_agent_play", HARNESS)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class RespondRoutingTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.harness = load_harness()

    def test_command_interaction_uses_respond(self):
        self.assertEqual(self.harness.respond_route(True, False), "respond")
        self.assertEqual(self.harness.respond_route(True, True), "respond")

    def test_native_popup_routes_to_dismiss(self):
        self.assertEqual(self.harness.respond_route(False, True), "dismiss")

    def test_no_interaction_is_none(self):
        self.assertEqual(self.harness.respond_route(False, False), "none")

    def test_hint_names_the_dismiss_call_and_answer_shape(self):
        hint = self.harness.native_popup_hint(
            {"answer_types": ["option"], "options": [{"option_id": "interaction-15:option-13"}]})
        self.assertIn("tome.dismiss", hint)
        self.assertIn("option_id", hint)
        self.assertIn("answer_types", hint)
        self.assertNotIn('{"dismiss":{...}}', hint)

    def test_hint_offers_confirm_when_applicable(self):
        hint = self.harness.native_popup_hint({"answer_types": ["confirm"]})
        self.assertIn("confirm", hint)
        self.assertIn("option_id", hint)


if __name__ == "__main__":
    unittest.main()
