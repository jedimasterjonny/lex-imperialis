"""Session host fixture for the pytest molecule-verify harness.

A role's molecule verify is a thin shim that runs `pytest roles/<role>/tests`
on the controller with `VERIFY_TARGET` naming the converged instance. This
fixture is the whole framework the role suites build on: it turns that value
into a way to run one shell command on the target.

`VERIFY_TARGET`:
  - `lex-...` (a molecule instance name) -> `incus exec <target> -- sh -c <cmd>`
  - `ssh:<dest>`                         -> `ssh <dest> <cmd>` (the live-smoke path)

`host.run(cmd, timeout=60)` returns the CompletedProcess (returncode, stdout,
stderr). Nothing more lives here until a second role needs it.
"""

from __future__ import annotations

import os
import subprocess

import pytest

# testlib carries the shared posture assertion; register it so a failed
# assert there still gets pytest's rich rewriting, not a bare AssertionError.
pytest.register_assert_rewrite("testlib")


class Target:
    """A converged molecule instance one shell command can be run against."""

    def __init__(self, spec: str) -> None:
        """Bind to a target spec: a molecule instance name, or ssh:<dest>."""
        self.spec = spec

    def run(self, cmd: str, timeout: int = 60) -> subprocess.CompletedProcess[str]:
        """Run cmd on the target and return the finished CompletedProcess."""
        if self.spec.startswith("ssh:"):
            argv = ["ssh", self.spec[len("ssh:") :], cmd]
        else:
            argv = ["incus", "exec", self.spec, "--", "sh", "-c", cmd]
        # Fixed argv, no shell -- running a command on the target is the point.
        return subprocess.run(  # noqa: S603
            argv, capture_output=True, text=True, timeout=timeout, check=False
        )


@pytest.fixture(scope="session")
def host() -> Target:
    return Target(os.environ["VERIFY_TARGET"])
