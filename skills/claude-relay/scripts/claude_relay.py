#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
import sys
from dataclasses import dataclass
from enum import StrEnum
from pathlib import Path
from typing import Final, TypeAlias
from uuid import UUID, uuid4

JsonValue: TypeAlias = (
    str | int | float | bool | None | list["JsonValue"] | dict[str, "JsonValue"]
)
DEFAULT_MODEL: Final = "opus"
DEFAULT_EFFORT: Final = "high"
DEFAULT_PERMISSION_MODE: Final = "plan"
DEFAULT_TIMEOUT_SECONDS: Final = 600


class ToolProfile(StrEnum):
    NONE = "none"
    READ_ONLY = "read-only"
    ALL = "all"


class SkillError(RuntimeError):
    pass


@dataclass(frozen=True, slots=True)
class ClaudeConfig:
    executable: Path
    model: str
    effort: str
    permission_mode: str
    tool_profile: ToolProfile


def resolve_claude_path(explicit: Path | None = None) -> Path:
    candidates: list[Path] = []
    if explicit is not None:
        candidates.append(explicit.expanduser())
    env_path = os.environ.get("CLAUDE_CLI_PATH")
    if env_path:
        candidates.append(Path(env_path).expanduser())
    discovered = shutil.which("claude")
    if discovered:
        candidates.append(Path(discovered))
    candidates.extend(
        [
            Path.home() / ".local/bin/claude",
            Path.home() / ".claude/local/claude",
        ]
    )
    for candidate in candidates:
        if candidate.is_file() and os.access(candidate, os.X_OK):
            return candidate.resolve()
    raise SkillError(
        "Claude Code CLI not found. Pass --claude-path or set CLAUDE_CLI_PATH."
    )


def normalize_session_id(value: str) -> str:
    try:
        return str(UUID(value))
    except ValueError as error:
        raise SkillError(f"Invalid Claude session UUID: {value}") from error


def build_command(
    *,
    action: str,
    prompt: str,
    session_id: str,
    config: ClaudeConfig,
) -> list[str]:
    if action not in {"start", "resume"}:
        raise SkillError(f"Unsupported action: {action}")
    if not prompt.strip():
        raise SkillError("Prompt must not be empty.")
    command = [
        str(config.executable),
        "-p",
        prompt,
        "--output-format",
        "json",
        "--model",
        config.model,
        "--effort",
        config.effort,
        "--permission-mode",
        config.permission_mode,
    ]
    if action == "start":
        command.extend(["--session-id", session_id])
    else:
        command.extend(["--resume", session_id])
    if config.tool_profile is ToolProfile.NONE:
        command.extend(["--tools", ""])
    elif config.tool_profile is ToolProfile.READ_ONLY:
        command.extend(["--tools", "Read", "Grep", "Glob"])
    return command


def find_transcript(session_id: str, projects_root: Path) -> Path | None:
    if not projects_root.is_dir():
        return None
    matches = list(projects_root.glob(f"**/{session_id}.jsonl"))
    if not matches:
        return None
    return max(matches, key=lambda path: path.stat().st_mtime_ns)


def _mapping(value: object) -> dict[str, object] | None:
    if not isinstance(value, dict):
        return None
    if not all(isinstance(key, str) for key in value):
        return None
    return value


def _string(mapping: dict[str, object] | None, key: str) -> str | None:
    if mapping is None:
        return None
    value = mapping.get(key)
    return value if isinstance(value, str) else None


def inspect_transcript(path: Path) -> dict[str, JsonValue]:
    model: str | None = None
    effort: str | None = None
    service_tier: str | None = None
    user_turns = 0
    assistant_turns = 0
    compactions = 0
    records = 0
    with path.open(encoding="utf-8") as transcript:
        for line_number, line in enumerate(transcript, start=1):
            if not line.strip():
                continue
            records += 1
            try:
                record = _mapping(json.loads(line))
            except json.JSONDecodeError as error:
                raise SkillError(
                    f"Invalid JSONL at {path}:{line_number}: {error.msg}"
                ) from error
            if record is None:
                raise SkillError(f"Expected object at {path}:{line_number}")
            record_type = _string(record, "type")
            if record_type == "user":
                user_turns += 1
            elif record_type == "assistant":
                assistant_turns += 1
                message = _mapping(record.get("message"))
                model = _string(message, "model") or model
                effort = _string(record, "effort") or effort
                usage = _mapping(message.get("usage")) if message else None
                service_tier = _string(usage, "service_tier") or service_tier
            if record_type == "summary" or "compactSummary" in record:
                compactions += 1
    return {
        "transcript_path": str(path),
        "records": records,
        "user_turns": user_turns,
        "assistant_turns": assistant_turns,
        "compactions": compactions,
        "model_actual": model,
        "effort_actual": effort,
        "service_tier": service_tier,
    }


def read_prompt(argument: str | None) -> str:
    if argument is not None:
        return argument
    if sys.stdin.isatty():
        raise SkillError("Pass --prompt or pipe prompt text on stdin.")
    prompt = sys.stdin.read()
    if not prompt.strip():
        raise SkillError("Prompt must not be empty.")
    return prompt


def parse_claude_output(stdout: str) -> dict[str, JsonValue]:
    try:
        parsed = json.loads(stdout)
    except json.JSONDecodeError as error:
        raise SkillError(f"Claude returned invalid JSON: {error.msg}") from error
    mapping = _mapping(parsed)
    if mapping is None:
        raise SkillError("Claude returned a non-object JSON value.")
    return {key: _json_value(value) for key, value in mapping.items()}


def _json_value(value: object) -> JsonValue:
    if value is None or isinstance(value, str | int | float | bool):
        return value
    if isinstance(value, list):
        return [_json_value(item) for item in value]
    if isinstance(value, dict):
        if not all(isinstance(key, str) for key in value):
            raise SkillError("Claude JSON contains a non-string object key.")
        return {key: _json_value(item) for key, item in value.items()}
    raise SkillError(f"Claude JSON contains unsupported value type: {type(value).__name__}")


def run_turn(
    *,
    action: str,
    prompt: str,
    session_id: str,
    config: ClaudeConfig,
    cwd: Path,
    timeout_seconds: int,
    projects_root: Path,
) -> tuple[dict[str, JsonValue], int]:
    if not cwd.is_dir():
        raise SkillError(f"Working directory does not exist: {cwd}")
    command = build_command(
        action=action,
        prompt=prompt,
        session_id=session_id,
        config=config,
    )
    try:
        completed = subprocess.run(
            command,
            cwd=cwd,
            capture_output=True,
            check=False,
            text=True,
            timeout=timeout_seconds,
        )
    except subprocess.TimeoutExpired as error:
        raise SkillError(
            f"Claude timed out after {timeout_seconds} seconds."
        ) from error
    response = parse_claude_output(completed.stdout) if completed.stdout else {}
    transcript = find_transcript(session_id, projects_root)
    inspection = inspect_transcript(transcript) if transcript else {}
    is_error = response.get("is_error") is True
    result: dict[str, JsonValue] = {
        "ok": completed.returncode == 0 and not is_error,
        "action": action,
        "session_id": session_id,
        "model_requested": config.model,
        "effort_requested": config.effort,
        "permission_mode": config.permission_mode,
        "tool_profile": config.tool_profile.value,
        "exit_code": completed.returncode,
        "result": response.get("result"),
        "is_error": response.get("is_error"),
        "stderr": completed.stderr.strip() or None,
        **inspection,
    }
    return result, 0 if result["ok"] is True else 1


def add_turn_arguments(parser: argparse.ArgumentParser, *, resume: bool) -> None:
    parser.add_argument("--prompt")
    parser.add_argument("--cwd", type=Path, default=Path.cwd())
    parser.add_argument("--claude-path", type=Path)
    parser.add_argument("--model", default=DEFAULT_MODEL)
    parser.add_argument("--effort", default=DEFAULT_EFFORT)
    parser.add_argument(
        "--permission-mode",
        default=DEFAULT_PERMISSION_MODE,
        choices=["default", "acceptEdits", "auto", "dontAsk", "plan"],
    )
    parser.add_argument(
        "--tool-profile",
        default=ToolProfile.NONE.value,
        choices=[profile.value for profile in ToolProfile],
    )
    parser.add_argument(
        "--timeout", type=int, default=DEFAULT_TIMEOUT_SECONDS, metavar="SECONDS"
    )
    parser.add_argument("--projects-root", type=Path, default=Path.home() / ".claude/projects")
    parser.add_argument("--session-id", required=resume)


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="claude-relay")
    commands = parser.add_subparsers(dest="command", required=True)
    start = commands.add_parser("start")
    add_turn_arguments(start, resume=False)
    resume = commands.add_parser("resume")
    add_turn_arguments(resume, resume=True)
    inspect = commands.add_parser("inspect")
    inspect.add_argument("--session-id", required=True)
    inspect.add_argument(
        "--projects-root", type=Path, default=Path.home() / ".claude/projects"
    )
    return parser


def emit(value: dict[str, JsonValue]) -> None:
    print(json.dumps(value, ensure_ascii=False, indent=2, sort_keys=True))


def main() -> int:
    arguments = build_parser().parse_args()
    try:
        session_id = normalize_session_id(arguments.session_id) if arguments.session_id else str(uuid4())
        if arguments.command == "inspect":
            transcript = find_transcript(session_id, arguments.projects_root.expanduser())
            if transcript is None:
                raise SkillError(f"Transcript not found for session {session_id}")
            emit({"ok": True, "session_id": session_id, **inspect_transcript(transcript)})
            return 0
        executable = resolve_claude_path(arguments.claude_path)
        config = ClaudeConfig(
            executable=executable,
            model=arguments.model,
            effort=arguments.effort,
            permission_mode=arguments.permission_mode,
            tool_profile=ToolProfile(arguments.tool_profile),
        )
        result, exit_code = run_turn(
            action=arguments.command,
            prompt=read_prompt(arguments.prompt),
            session_id=session_id,
            config=config,
            cwd=arguments.cwd.expanduser().resolve(),
            timeout_seconds=arguments.timeout,
            projects_root=arguments.projects_root.expanduser(),
        )
        emit(result)
        return exit_code
    except (OSError, SkillError) as error:
        emit({"ok": False, "error": str(error)})
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
