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

Both files are parsed as YAML rather than grepped. `alerts.yml` carries long prose
comments that already contain the string `alert:`, and the tests carry `alertname`
in theirs, so a line-oriented match reads commentary as declarations.
"""

import sys
from pathlib import Path

import yaml

REPO = Path(__file__).resolve().parent.parent
# Named outright, as the promtool-test hook names the same test file. prometheus is
# the only role that ships rules, and the fleet runs one of it, so there is no pair
# to discover.
RULES = REPO / "roles/prometheus/files/rules/alerts.yml"
TESTS = REPO / "roles/prometheus/tests/alerts_test.yml"


def declared(rules):
    # A recording rule carries `record:` where an alert carries `alert:`; the repo
    # ships none, but reading past one beats a KeyError traceback out of a gate.
    return {
        rule["alert"]
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


def main():
    rules = declared(yaml.safe_load(RULES.read_text()))
    cases = asserted(yaml.safe_load(TESTS.read_text()))

    status = 0
    for name in sorted(rules - cases):
        print(
            f"ERROR: alert '{name}' has no case in {TESTS.relative_to(REPO)}; "
            "add one asserting it fires on the fault it names.",
            file=sys.stderr,
        )
        status = 1
    for name in sorted(cases - rules):
        print(
            f"ERROR: {TESTS.relative_to(REPO)} asserts alert '{name}', which "
            f"{RULES.relative_to(REPO)} does not define — a renamed or misspelt rule.",
            file=sys.stderr,
        )
        status = 1

    return status


if __name__ == "__main__":
    sys.exit(main())
