"""The standing beets library catalog: timer, script, config, and an idempotent
run over a generated fixture album.

Sorts after test_apps (posture) and before test_beets_pipeline. The idempotence
test mutates the music library (generates a fixture and imports it), so it is
defined after the empty-library run it must not perturb.
"""

CONFIG = "/config/managed/library-config.yaml"


def test_catalog_timer_enabled_active(host):
    assert host.run("systemctl is-enabled beets-library.timer").stdout.strip() == "enabled"
    assert host.run("systemctl is-active beets-library.timer").stdout.strip() == "active"


def test_catalog_script_present(host):
    res = host.run("stat -c '%a' /usr/local/sbin/beets-library.sh")
    assert res.returncode == 0
    assert res.stdout.strip() == "755"


def test_catalog_config_no_media_writes(host):
    assert "write: no" in host.run("podman exec beets cat " + CONFIG).stdout


# Running the oneshot proves the script resolves beet in the container and the
# catalog completes over the empty library — a non-zero exit fails the start.
def test_catalog_runs_on_empty_library(host):
    assert host.run("systemctl start beets-library.service", timeout=120).returncode == 0


# Prove the catalog actually imports — not just that it runs clean on empty — and
# that a second run adds nothing (the standing catalog's core contract). The
# fixture is generated in-container with ffmpeg (POSIX sh — the beets image is
# Alpine/busybox); import -A is no-autotag so it needs no MusicBrainz network.
def test_catalog_imports_and_is_idempotent(host):
    host.run(
        "podman exec --user abc beets sh -c '"
        "mkdir -p /data/media/music/TestArtist/TestAlbum && "
        "ffmpeg -hide_banner -loglevel error -f lavfi -i anullsrc=r=44100:cl=mono "
        "-t 1 -metadata artist=TestArtist -metadata album=TestAlbum "
        "-metadata title=Track1 /data/media/music/TestArtist/TestAlbum/01.mp3'",
        timeout=120,
    )
    host.run("systemctl start beets-library.service", timeout=120)
    first = host.run("podman exec --user abc beets beet -c " + CONFIG + " ls").stdout.splitlines()
    host.run("systemctl start beets-library.service", timeout=120)
    again = host.run("podman exec --user abc beets beet -c " + CONFIG + " ls").stdout.splitlines()
    assert len(first) >= 1
    assert len(again) == len(first)
