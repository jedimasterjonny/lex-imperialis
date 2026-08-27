#!/usr/bin/env python3
"""Hold every shipped alert rule to having a promtool test case, both ways round.

`promtool test rules` asserts what the cases say; it cannot say a rule has no case
at all. Coverage was 14 of 44 before anyone counted, and the rules that had gone
untested were the ones nobody had reason to revisit — exactly the set a habit
protects worst.

The reverse direction is not symmetry for its own sake. Where a case expects alerts,
promtool already fails on a name no rule defines. Where every one of a case's
assertions is negative — `exp_alerts: []`, which is how each `for:` window here is
pinned — it matches the empty set against an empty expectation and passes in
silence, so the case keeps its green tick and asserts nothing. Measured, not
assumed: a case naming `RuleThatDoesNotExist` passes `promtool test rules`.

It is a set comparison, so it holds names rather than occurrences: an alert
asserted correctly somewhere and misspelt in one further assertion still appears on
both sides and goes unreported. Renames are the case it does catch, and it names
both sides of one.

Every file is parsed as YAML rather than grepped. `alerts.yml` carries long prose
comments that already contain the string `alert:`, and the tests carry `alertname`
in theirs, so a line-oriented match reads commentary as declarations.

It also holds the one cross-rule invariant promtool cannot see. SystemdUnitFailed and
ScheduledJobMetricMissing carry the same roster of oneshot units in two syntaxes, 500
lines apart: the former excludes them from the catch-all on the grounds that each has
a bespoke *Failed rule, the latter is what makes that grounds true, and a unit missed
on either side is monitored by neither, silently. ServiceRestartStorm and
WireguardTunnelDown are the same shape, but one series drives both, so a promtool case
pins that pair either way and it needs nothing here. A roster cannot be pinned that
way — a case only exercises the units it names — so it is read off the file here
rather than regexed back out of Prometheus's HTTP API by the molecule scenario.
"""

import re
import sys
from pathlib import Path

import yaml

REPO = Path(__file__).resolve().parent.parent
# The rule file is named outright: prometheus is the only role that ships rules, and
# the fleet runs one of it, so there is no pair to discover.
RULES = REPO / "roles/prometheus/files/rules/alerts.yml"
# The tests are a set rather than one file. promtool fixes evaluation_interval per
# file, so the cases whose grid has to differ live in their own — and coverage is a
# property of the rules against ALL of them, so a glob is what keeps a case from
# going missing by being moved. Sorted for stable messages.
TESTS = sorted((REPO / "roles/prometheus/tests").glob("*_test.yml"))
TESTS_LABEL = ", ".join(str(path.relative_to(REPO)) for path in TESTS)


def declared(rules):
    # A recording rule carries `record:` where an alert carries `alert:`; the repo
    # ships none, but reading past one beats a KeyError traceback out of a gate.
    # Keyed by name rather than a bare set so the roster check below can read an
    # expression without walking the tree a second time; a missing alert yields ""
    # there and reds the gate through its own message.
    return {
        rule["alert"]: rule.get("expr", "")
        for group in rules.get("groups", [])
        for rule in group.get("rules", [])
        if "alert" in rule
    }


def asserted(tests):
    return {
        case["alertname"]
        for test in tests.get("tests", [])
        for case in test.get("alert_rule_test", [])
        if "alertname" in case
    }


# Both rosters are read out of the rule's own expression, so neither can be restated
# here and drift from what is shipped. Both anchor on the matcher that carries them
# rather than scanning the expression at large: an unanchored scan picks up any other
# parenthesised sub-expression (`and on (instance)` yields a phantom `instance`), and —
# the failure that matters — a unit named outside the scanned alphabet drops out of
# BOTH rosters at once, so they compare equal and the gate stays green on a real
# mismatch. Measured: with `[a-z-]+`, a `wordpress-boost2` excluded but uncovered
# passed.
def excluded_roster(expr):
    # One alternation inside SystemdUnitFailed's name!~ matcher. Spaces around !~ are
    # valid PromQL and are the likely shape of the next edit, so the whitespace is
    # matched loosely.
    return sorted(
        {
            unit
            for alt in re.findall(r'name\s*!~\s*"\(([^)]+)\)', expr)
            for unit in alt.split("|")
        }
    )


def covered_roster(expr):
    # One node_systemd_unit_state selector per ScheduledJobMetricMissing clause. The
    # promtool case's input_series carry the same shape, so this reads those too.
    return sorted(
        set(re.findall(r'node_systemd_unit_state\{[^}]*name="([^"]+)\.service"', expr))
    )


def catch_all_series(tests):
    # Located by the alert its cases assert, not by case name, so renaming the case
    # does not quietly empty this.
    return {
        unit
        for test in tests.get("tests", [])
        if any(
            case.get("alertname") == "SystemdUnitFailed"
            for case in test.get("alert_rule_test", [])
        )
        for series in test.get("input_series", [])
        for unit in covered_roster(series.get("series", ""))
    }


def main():
    if not TESTS:
        print(
            "ERROR: no *_test.yml under roles/prometheus/tests — every check below "
            "would pass by having nothing to compare the rules against.",
            file=sys.stderr,
        )
        return 1

    rules = declared(yaml.safe_load(RULES.read_text()))
    # Merged, not compared file by file: which file a case sits in is a matter of the
    # grid it needs, and says nothing about what it covers.
    tests = {
        "tests": [
            group
            for path in TESTS
            for group in (yaml.safe_load(path.read_text()) or {}).get("tests", [])
        ]
    }
    cases = asserted(tests)

    status = 0
    for name in sorted(rules.keys() - cases):
        print(
            f"ERROR: alert '{name}' has no case in {TESTS_LABEL}; "
            "add one asserting it fires on the fault it names.",
            file=sys.stderr,
        )
        status = 1
    for name in sorted(cases - rules.keys()):
        print(
            f"ERROR: a case in {TESTS_LABEL} asserts alert '{name}', which "
            f"{RULES.relative_to(REPO)} does not define — a renamed or misspelt rule.",
            file=sys.stderr,
        )
        status = 1

    # Emptiness is checked as well as equality: two rosters that matched nothing
    # compare equal, and a renamed or rewritten rule is how that would happen.
    excluded = excluded_roster(rules.get("SystemdUnitFailed", ""))
    covered = covered_roster(rules.get("ScheduledJobMetricMissing", ""))
    if not excluded or not covered:
        print(
            f"ERROR: in {RULES.relative_to(REPO)}, the roster reads {excluded} out of "
            f"SystemdUnitFailed and {covered} out of ScheduledJobMetricMissing — one "
            "matched nothing, so a renamed or rewritten rule has left this check "
            "asserting nothing at all.",
            file=sys.stderr,
        )
        status = 1
    elif excluded != covered:
        print(
            f"ERROR: in {RULES.relative_to(REPO)}, SystemdUnitFailed excludes "
            f"{excluded} but ScheduledJobMetricMissing covers {covered} — they differ "
            f"on {sorted(set(excluded) ^ set(covered))}. A unit excluded from the "
            "catch-all with no outcome-metric alert behind it is monitored by neither "
            "rule.",
            file=sys.stderr,
        )
        status = 1

    # The roster's third copy. The SystemdUnitFailed case drives one series per
    # excluded unit; a unit added to both rules but not there leaves that case
    # asserting nothing about it, which is what it did for wordpress-boost from
    # dab44a0 until now. A subset, not equality: the case deliberately also drives an
    # ordinary unit that SHOULD alert.
    undriven = sorted(set(excluded) - catch_all_series(tests))
    if undriven:
        print(
            f"ERROR: the SystemdUnitFailed case in {TESTS_LABEL} drives no "
            f"series for {undriven}, so it cannot notice them being dropped from the "
            "exclusion roster; add one input_series per unit.",
            file=sys.stderr,
        )
        status = 1

    return status


if __name__ == "__main__":
    sys.exit(main())
