#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
from __future__ import annotations

import importlib.util
import json
import sys
import tempfile
import unittest
from pathlib import Path
from types import ModuleType

SCRIPT_PATH = Path(__file__).parents[1] / "scripts" / "claude_relay.py"


def load_module() -> ModuleType:
    spec = importlib.util.spec_from_file_location("claude_relay", SCRIPT_PATH)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"Cannot load {SCRIPT_PATH}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


class CommandTests(unittest.TestCase):
    def __init__(self, methodName: str = "runTest") -> None:
        super().__init__(methodName)
        self.module = load_module()
        self.config: object = object()

    def setUp(self) -> None:
        self.module = load_module()
        self.config = self.module.ClaudeConfig(
            executable=Path("/tmp/claude"),
            model="opus",
            effort="high",
            permission_mode="plan",
            tool_profile=self.module.ToolProfile.NONE,
        )

    def test_start_command_sets_explicit_session_and_model(self) -> None:
        command = self.module.build_command(
            action="start",
            prompt="remember alpha",
            session_id="11111111-1111-4111-8111-111111111111",
            config=self.config,
        )

        self.assertEqual(command[0], "/tmp/claude")
        self.assertIn("--session-id", command)
        self.assertIn("opus", command)
        self.assertIn("--effort", command)
        self.assertIn("high", command)
        self.assertEqual(command[-2:], ["--tools", ""])

    def test_resume_command_uses_resume_not_session_id(self) -> None:
        command = self.module.build_command(
            action="resume",
            prompt="what was alpha?",
            session_id="11111111-1111-4111-8111-111111111111",
            config=self.config,
        )

        self.assertIn("--resume", command)
        self.assertNotIn("--session-id", command)


class TranscriptTests(unittest.TestCase):
    def __init__(self, methodName: str = "runTest") -> None:
        super().__init__(methodName)
        self.module = load_module()

    def setUp(self) -> None:
        self.module = load_module()

    def test_inspect_reports_actual_model_effort_and_turns(self) -> None:
        records = [
            {"type": "user", "sessionId": "s", "message": {"role": "user"}},
            {
                "type": "assistant",
                "sessionId": "s",
                "effort": "high",
                "message": {
                    "role": "assistant",
                    "model": "claude-opus-5",
                    "usage": {"service_tier": "standard"},
                },
            },
            {"type": "summary", "summary": "compact"},
        ]
        with tempfile.TemporaryDirectory() as directory:
            transcript = Path(directory) / "s.jsonl"
            transcript.write_text(
                "\n".join(json.dumps(record) for record in records) + "\n",
                encoding="utf-8",
            )

            result = self.module.inspect_transcript(transcript)

        self.assertEqual(result["model_actual"], "claude-opus-5")
        self.assertEqual(result["effort_actual"], "high")
        self.assertEqual(result["service_tier"], "standard")
        self.assertEqual(result["user_turns"], 1)
        self.assertEqual(result["assistant_turns"], 1)
        self.assertEqual(result["compactions"], 1)


if __name__ == "__main__":
    unittest.main()
