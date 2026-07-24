"""Scheduled-task timers and their node_exporter outcome metrics.

Each timer is asserted active, then stopped so a live fire can't clobber the
.prom the metric checks write and read back; the oneshot it drives is run to
exercise the ExecStopPost metric hook, and the success/failure metric values are
driven the way systemd would (SERVICE_RESULT) since the uninstalled site can't
force a clean cron run. Per timer the active check is defined first, so it runs
before the stop fixture it does not depend on; each stop fixture restarts its
timer on teardown, leaving the instance healthy and the suite re-runnable.
"""

from __future__ import annotations

from typing import TYPE_CHECKING

import pytest

from wphelpers import DB_NAME, TEXTFILE_DIR

if TYPE_CHECKING:
    from collections.abc import Iterator

    from conftest import Target

CRON_PROM = TEXTFILE_DIR + "/wordpress-cron.prom"
DUMP_PROM = TEXTFILE_DIR + "/wordpress-db-dump.prom"
UPDATE_PROM = TEXTFILE_DIR + "/wordpress-updates.prom"


# --- wp-cron ---


@pytest.fixture(scope="module")
def cron_timer_stopped(host: Target) -> Iterator[None]:
    host.run("systemctl stop wordpress-cron.timer")
    yield
    host.run("systemctl start wordpress-cron.timer")


def test_cron_timer_active(host: Target) -> None:
    assert host.run("systemctl is-active wordpress-cron.timer").stdout.strip() == "active"


def test_cron_service_records_outcome_metric(host: Target, cron_timer_stopped: None) -> None:
    # wp cron event run needs an installed site, so ExecStart may exit non-zero;
    # ExecStopPost fires either way, so ignore the start and assert the metric's
    # structure (the success gauge and a timestamp), not a value it can't pin.
    host.run("systemctl start wordpress-cron.service")
    prom = host.run("cat " + CRON_PROM).stdout
    assert "wordpress_cron_success " in prom
    assert "wordpress_cron_last_run_timestamp_seconds " in prom


def test_cron_success_metric(host: Target, cron_timer_stopped: None) -> None:
    host.run("SERVICE_RESULT=success /usr/local/sbin/wp-cron-metric.sh")
    prom = host.run("cat " + CRON_PROM).stdout
    assert "wordpress_cron_success 1" in prom
    assert "wordpress_cron_last_run_timestamp_seconds " in prom


def test_cron_failure_metric(host: Target, cron_timer_stopped: None) -> None:
    host.run("SERVICE_RESULT=exit-code /usr/local/sbin/wp-cron-metric.sh")
    prom = host.run("cat " + CRON_PROM).stdout
    assert "wordpress_cron_success 0" in prom


# --- database backup ---


@pytest.fixture(scope="module")
def db_dump_run(host: Target) -> Iterator[int]:
    # Starting a oneshot blocks until it exits; rc != 0 if the wrapper cannot
    # reach the database, authenticate, or write the volume.
    host.run("systemctl stop wordpress-db-dump.timer")
    rc = host.run("systemctl start wordpress-db-dump.service", timeout=120).returncode
    yield rc
    host.run("systemctl start wordpress-db-dump.timer")


def test_db_dump_timer_active(host: Target) -> None:
    assert host.run("systemctl is-active wordpress-db-dump.timer").stdout.strip() == "active"


def test_db_dump_service_runs(db_dump_run: int) -> None:
    assert db_dump_run == 0


def test_db_dump_landed(host: Target, db_dump_run: int) -> None:
    # No tables until WordPress is installed, but --databases still emits its
    # CREATE DATABASE, so a dump carrying the db name proves it landed in the
    # volume (not the docroot) and is loadable. Use the running db image so a
    # renovate bump can't leave a stale digest here.
    cmd = (
        "img=$(podman inspect wordpress-db --format '{{.ImageName}}'); "
        'podman run --rm --volume wordpress-db-dump:/dump:ro "$img" '
        "grep -qE 'CREATE DATABASE.*" + DB_NAME + "' /dump/wordpress.sql"
    )
    assert host.run(cmd, timeout=120).returncode == 0


def test_db_dump_success_metric(host: Target, db_dump_run: int) -> None:
    prom = host.run("cat " + DUMP_PROM).stdout
    assert "wordpress_db_dump_success 1" in prom
    assert "wordpress_db_dump_last_run_timestamp_seconds " in prom


def test_db_dump_failure_metric(host: Target, db_dump_run: int) -> None:
    host.run("SERVICE_RESULT=exit-code /usr/local/sbin/wp-db-dump-metric.sh")
    prom = host.run("cat " + DUMP_PROM).stdout
    assert "wordpress_db_dump_success 0" in prom


# --- update check ---


@pytest.fixture(scope="module")
def update_check_run(host: Target) -> Iterator[tuple[int, str]]:
    host.run("systemctl stop wordpress-update-check.timer")
    rc = host.run("systemctl start wordpress-update-check.service", timeout=180).returncode
    prom = host.run("cat " + UPDATE_PROM).stdout
    yield rc, prom
    host.run("systemctl start wordpress-update-check.timer")


def test_update_check_timer_active(host: Target) -> None:
    active = host.run("systemctl is-active wordpress-update-check.timer").stdout.strip()
    assert active == "active"


def test_update_check_service_runs(update_check_run: tuple[int, str]) -> None:
    assert update_check_run[0] == 0


def test_update_check_metric(update_check_run: tuple[int, str]) -> None:
    # The uninstalled site yields no real counts, so assert the metric's
    # structure: success, timestamp, and a gauge for every update type.
    prom = update_check_run[1]
    assert "wordpress_update_check_success " in prom
    assert "wordpress_update_check_last_run_timestamp_seconds " in prom
    assert 'wordpress_updates_available{type="core"}' in prom
    assert 'wordpress_updates_available{type="plugins"}' in prom
    assert 'wordpress_updates_available{type="themes"}' in prom
    assert 'wordpress_updates_available{type="translations"}' in prom
