#!/usr/bin/env python3
"""Assert a desktop-verify --json payload satisfies the "app-it compatible" gate.

The gate, per references/verification.md (the versioned verify contract):

    tool == "app-it.desktop-verify", schema_version understood, status == "pass".

A passing --strict run (counts.fail == 0 and counts.warn == 0) is the documented
"done" signal. Unknown keys are ignored on purpose — additive changes do not bump
schema_version, so reading defensively keeps an older gate working against a newer
launcher. Exits non-zero (failing the job) on any contract violation.

Usage: assert_contract.py <verify-json-path> <expected-schema-version>
"""
import json
import os
import sys

CONTRACT_URL = (
    "https://github.com/Christian-Katzmann/app-it/blob/main/docs/APP-IT-COMPATIBLE.md"
)


def emit_summary(lines):
    """Append a Markdown block to the GitHub job summary, if running in Actions."""
    path = os.environ.get("GITHUB_STEP_SUMMARY")
    if not path:
        return
    try:
        with open(path, "a", encoding="utf-8") as handle:
            handle.write("\n".join(lines) + "\n")
    except OSError:
        pass


def fail(message):
    print(f"::error::app-it compatible gate: {message}")
    emit_summary(["### ❌ app-it compatible — FAILED", "", message])
    sys.exit(1)


def main():
    if len(sys.argv) != 3:
        fail("internal: expected <verify-json-path> <expected-schema-version>")
    json_path, expected_raw = sys.argv[1], sys.argv[2]
    try:
        expected_schema = int(expected_raw)
    except ValueError:
        fail(f"internal: schema-version {expected_raw!r} is not an integer")

    try:
        with open(json_path, encoding="utf-8") as handle:
            payload = json.load(handle)
    except (OSError, json.JSONDecodeError) as err:
        fail(f"could not read verify --json output: {err}")

    tool = payload.get("tool")
    if tool != "app-it.desktop-verify":
        fail(f'unexpected tool {tool!r} (want "app-it.desktop-verify")')

    schema = payload.get("schema_version")
    if schema != expected_schema:
        fail(
            f"verify JSON schema_version {schema!r} is not the contract version this "
            f"gate understands ({expected_schema}). Pin the action to a matching app-it "
            "release, or bump the action's schema-version input once you've reviewed the change."
        )

    counts = payload.get("counts") or {}
    app = payload.get("app") or {}
    manifest = payload.get("manifest") or {}
    name = app.get("name") or app.get("slug") or "app"
    gen = manifest.get("generator_version") or "unstamped"
    tpl = manifest.get("template_version") or "unstamped"

    status = payload.get("status")
    if status != "pass":
        fail(
            f"{name}: status is {status!r}, not \"pass\" "
            f"({counts.get('fail', '?')} fail, {counts.get('warn', '?')} warn). "
            "A passing --strict run is required for app-it compatibility."
        )

    print(
        f"app-it compatible: PASS — {name} verified "
        f"(status=pass, {counts.get('ok', '?')} ok, generator {gen})."
    )
    emit_summary(
        [
            "### ✅ app-it compatible",
            "",
            f"**{name}** passes `app-it verify --strict` "
            f"(`tool=app-it.desktop-verify`, `schema_version={schema}`, `status=pass`).",
            "",
            f"- ok: {counts.get('ok', '?')} · warn: {counts.get('warn', '?')} "
            f"· fail: {counts.get('fail', '?')}",
            f"- manifest generator: `{gen}` · template: `{tpl}`",
            "",
            f"See [the app-it compatible contract]({CONTRACT_URL}).",
        ]
    )


if __name__ == "__main__":
    main()
