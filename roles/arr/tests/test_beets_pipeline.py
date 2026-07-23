"""The beets per-download pipeline: timer, script, config, run, and backlog metric.

Definition order matters: the empty-tree run fires the ExecStopPost that writes
the .prom the empty-queue test reads, and the parked-albums test mutates the
quarantine tree, so it is defined last.
"""

from __future__ import annotations

from typing import TYPE_CHECKING

import pytest

from arrhelpers import DATA_ROOT, TEXTFILE_DIR

if TYPE_CHECKING:
    from conftest import Target

CONFIG = "/config/managed/pipeline-config.yaml"
PROM = TEXTFILE_DIR + "/beets-pipeline.prom"
METRIC = "/usr/local/sbin/beets-pipeline-metric.sh"


def test_pipeline_timer_enabled_active(host: Target) -> None:
    assert host.run("systemctl is-enabled beets-pipeline.timer").stdout.strip() == "enabled"
    assert host.run("systemctl is-active beets-pipeline.timer").stdout.strip() == "active"


def test_pipeline_script_present(host: Target) -> None:
    res = host.run("stat -c '%a' /usr/local/sbin/beets-pipeline.sh")
    assert res.returncode == 0
    assert res.stdout.strip() == "755"


def test_pipeline_config_has_musicbrainz(host: Target) -> None:
    assert "musicbrainz" in host.run("podman exec beets cat " + CONFIG).stdout


# The empty tree runs the wrapper's "no download dir -> exit 0" path, proving the
# wrapper resolves beet/find/curl in the container and fires the ExecStopPost hook.
def test_pipeline_runs_on_empty_tree(host: Target) -> None:
    assert host.run("systemctl start beets-pipeline.service", timeout=120).returncode == 0


@pytest.mark.parametrize("d", ["/data/downloads/staging", "/data/downloads/quarantine"])
def test_pipeline_creates_staging_and_quarantine(host: Target, d: str) -> None:
    assert host.run("podman exec beets test -d " + d).returncode == 0


# The ExecStopPost hook published the backlog metric; the empty tree has nothing
# parked, so both gauges read zero.
def test_pipeline_metric_empty_queue(host: Target) -> None:
    prom = host.run("cat " + PROM).stdout
    assert "beets_pipeline_quarantine_albums 0" in prom
    assert "beets_pipeline_lidarr_rejected_albums 0" in prom


# Exercise the counting itself: park one no-match album and one lidarr-rejected
# album on the host quarantine tree, re-run the hook, and confirm each gauge counts
# its own pile (the lidarr-rejected subdir excluded from the no-match count).
def test_pipeline_metric_counts_piles(host: Target) -> None:
    quar = DATA_ROOT + "/downloads/quarantine"
    host.run(
        "mkdir -p '"
        + quar
        + "/Some No-Match Album' '"
        + quar
        + "/lidarr-rejected/Some Rejected Album'"
    )
    host.run(METRIC)
    prom = host.run("cat " + PROM).stdout
    assert "beets_pipeline_quarantine_albums 1" in prom
    assert "beets_pipeline_lidarr_rejected_albums 1" in prom
