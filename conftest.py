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

import os
import subprocess

import pytest


class Target:
    def __init__(self, spec):
        self.spec = spec

    def run(self, cmd, timeout=60):
        if self.spec.startswith("ssh:"):
            argv = ["ssh", self.spec[len("ssh:"):], cmd]
        else:
            argv = ["incus", "exec", self.spec, "--", "sh", "-c", cmd]
        return subprocess.run(
            argv, capture_output=True, text=True, timeout=timeout, check=False
        )


@pytest.fixture(scope="session")
def host():
    return Target(os.environ["VERIFY_TARGET"])
