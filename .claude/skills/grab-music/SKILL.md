---
name: grab-music
description: >-
  Pull music into the Lidarr library from a radio playlist and keep the library
  canonical. Scrapes a station's recently-played tracks, adds the artists at the
  High Quality + Album Only profiles, searches their missing albums, then watches
  the beets import quarantine and processes every parked album to the same
  standard — split image rips, tag + scrub against the exact MusicBrainz release,
  then import — so nothing reaches the library that has not been beets-scrubbed and
  canonically tagged. Use whenever the operator wants music grabbed or the music
  quarantine drained — triggers include "grab music", "scrape Kerrang", "scrape the
  radio playlist and add the artists", "search for these artists' missing albums",
  "process the music import quarantine", "keep watching the quarantine", "don't let
  the standard slip", even when the skill is not named.
---

# Grab music

Drive music from a radio playlist into the Lidarr library on `solar`, holding one
invariant: **an album enters the library only after beets has scrubbed it and
tagged it 1:1 with MusicBrainz.** No force-imports of raw source tags; anything
that cannot be auto-placed stays in quarantine and is surfaced, never imported
sub-standard.

This invariant rests on two runtime settings in Lidarr (documented in
`roles/arr/README.md`, not codified): **completed-download handling is OFF** so
Lidarr never imports straight from `downloads/`, and **renameTracks is ON** so it
owns the library layout. If CDH is ever turned on, grabs bypass beets and the
guarantee breaks — confirm it's off before relying on this skill.

Run autonomously. The quarantine watch is a loop — fire, drain, re-arm — and only
stop to ask when an album genuinely can't be placed (no matching edition, no album
match, only deluxe/APE rips) or the operator says to pause.

## Setup (do once per run)

**Reach Lidarr internally.** This repo is public, so the external hostname must
never appear in it. Lidarr is at `http://lidarr:8686` (`arr_beets_lidarr_url`) on
solar's container network, and the `beets` container can reach it and already holds
the API key as `LIDARR__AUTH__APIKEY` (from the 0600 `/etc/arr/lidarr.env`). Run the
API helpers there: stage a script under `/data/downloads/` (beets sees the host
`/nfs/scriptorum/arr-data/downloads/`) and run
`ansible solar -b --vault-password-file .vault_pass -m shell -a 'set -a; .
/etc/arr/lidarr.env; podman exec --env LIDARR__AUTH__APIKEY beets /lsiopy/bin/python3
/data/downloads/<x>.py'`. `/etc/arr/lidarr.env` (a `KEY=value` file) is in scope only
for the systemd service, not an ad-hoc shell, so source it first — `-b` runs as root,
which can read the 0600 file — then `--env` copies it into the container; the script
takes `BASE=http://lidarr:8686` and the key from `os.environ`. `/lsiopy/bin/python3`
carries `mutagen`. Never write the external FQDN or the key into a repo file.

- **Profiles / root**: High Quality = `qualityProfileId 7`, Album Only =
  `metadataProfileId 3` (confirm via `GET /api/v1/metadataprofile` if unsure), root
  folder `/data/media/music` (id 1).
- **cue-splitter image** `localhost/cue-splitter:latest` on solar splits single-file
  FLAC+cue disc images. Build if missing — FLAC tools only, no APE decoder:
  `printf 'FROM docker.io/library/ubuntu:latest\nRUN apt-get update && apt-get
  install -y --no-install-recommends shntool cuetools flac && rm -rf
  /var/lib/apt/lists/*\n' | podman build -t localhost/cue-splitter:latest -f - .`
- Work dir: regenerate the helper scripts from this skill into the session
  scratchpad each run; do not rely on an earlier session's files.

Underlying detail lives in the operator memories `lidarr-library-mb-canonicalisation`,
`beets-lidarr-autoimport-edition-gap`, `lidarr-min-format-score-relaxed`, and
`arr-beets-lidarr-pipeline`.

## Phase 1 — scrape the playlist

The Bauer/Planet network (Kerrang and its sisters) exposes recent histories at
`https://listenapi.planetradio.co.uk/api9/initweb/<code>` — a third-party public
API, fetched read-only. `initweb/ker` also lists every station code+id. Known: `ker`
Kerrang, `krg` Klassic Kerrang, `krq` Kerrang Unleashed, `nmk` Nu Metal, `ppa` Pop
Punk Anthems, `kra/krb/krc/krd` Alt Rock 80s/90s/00s/10s. `nowplaying/<code>` gives
only the current track — XML if the code is wrong. For main Kerrang,
`onlineradiobox.com/uk/kerrangradio/playlist/` also renders a clean last-10; most
sister stations are dry there and on the JS-rendered hellorayo pages, so prefer the
API. Extract the recent tracks → the distinct artists — the API surfaces six to ten.

## Phase 2 — add the artists

Per artist: `GET /api/v1/artist/lookup?term=<name>`, take the exact-name match else
the first. Skip any with `id>0` — already in library. POST the lookup resource to
`/api/v1/artist` with `qualityProfileId 7`, `metadataProfileId 3`, `rootFolderPath
/data/media/music`, `monitored true`, `monitorNewItems "all"`, `addOptions
{monitor:"all", searchForMissingAlbums:false}` — search separately so the count is
reportable. Already-present artists: leave them, unless asked to standardise, then
PUT `/api/v1/artist/editor {artistIds, qualityProfileId:7, metadataProfileId:3}`.

## Phase 3 — search missing albums

Wait for each new artist's albums to load — poll `/api/v1/album?artistId=`. Collect
albums that are `albumType=="Album"`, `monitored`, released (`releaseDate <= today`),
and not complete (`trackFileCount < trackCount`). Trigger one `POST /api/v1/command
{name:"AlbumSearch", albumIds:[…]}`. Report the count — full discographies are large.

## Phase 4 — process the import quarantine (the standard)

beets screens each completed download; matches stage and import, no-matches land in
`/data/downloads/quarantine/<album>`, and matched albums Lidarr refused after the
poke cap land in `…/quarantine/lidarr-rejected/<album>`.

**Watch.** Run a background poll that exits — notifying you — when there is work.
Each tick reads the host metric file
`/var/lib/node_exporter/textfile_collector/beets-pipeline.prom`
(`beets_pipeline_quarantine_albums`, `…_lidarr_rejected_albums`) and the in-container
poke counters (`podman exec beets cat /config/pipeline/pokes/*`) against the cap
`arr_beets_poke_cap`= 6. Exit when quarantine>0 or rejected>0 — **not** on a high poke.
A staged album Lidarr won't auto-import (edition mismatch) climbs the poke cap and caps
into `lidarr-rejected` on the pipeline's own timer, where the orchestrator drains it;
exiting on poke ≥ 5 just re-fires the watch on something not yet drainable. Note the high
poke and keep watching. On exit, run the orchestrator. Then mind two things: the
quarantine count includes **already-surfaced stragglers** (no-edition, image-only) you
deliberately parked, so once a drain leaves only those, report and **stop** — don't
re-arm into an immediate re-fire loop. And after a *productive* drain, before re-arming,
run `systemctl start beets-pipeline.service` (root): it reconciles the poke counters —
dropping the file for each imported/capped staging dir — and refreshes the metric, so a
stale count doesn't re-fire the watch.

**Orchestrate.** For the whole quarantine + lidarr-rejected backlog, in order:

1. **Split** single-file FLAC+cue disc images to per-track FLAC with the cue-splitter —
   `podman run --rm --security-opt label=disable -v <host-quarantine>:/q -v <split.sh>:/split.sh:ro
   localhost/cue-splitter` (`label=disable` is required for the bind mount on solar's
   enforcing SELinux) running `shnsplit -f *.cue -o flac -t "%n %t"`; drop the `00`
   pregap; remove the original + cue + log; `chown -R 1040:65537`. **Verify the split produced tracks before
   deleting the original** — a malformed/empty cue makes shnsplit yield nothing yet
   exit 0, and deleting then loses the only copy (leaving just artwork); on zero
   tracks, leave it parked. shnsplit output is **untagged**, so the `fromfilename`
   plugin (step 3 config) is what maps it under `--search-id` — without track numbers
   beets matches by duration alone and, because the config forces apply, silently writes
   a scrambled order. **Multi-disc nested rip** (`Disc 1/`/`Disc 2/`, each its own
   image): split each disc, then `metaflac --set-tag=DISCNUMBER=<n> --set-tag=DISCTOTAL=<t>
   --set-tag=TRACKNUMBER=<nn>` per file and flatten all into one dir (rename
   `n-NN Title.flac`, `rm -rf` the disc subdirs) so beets sees one album and `--search-id`
   maps the multi-medium release. **APE images: do not split** — see gotcha — re-grab instead.
2. **Identify**: per album, `GET /api/v1/manualimport?folder=<path>` → matched
   `album.id`; pick the edition whose `trackCount` equals the audio-file count → its
   `foreignReleaseId` (the MB release id). No album match or no matching edition →
   straggler, leave parked.
3. **Tag + scrub** in place: `beet -c retag-mb.yaml -l <tmpdb> import --search-id
   <mbid> <path>` (config below) writes canonical MB tags and scrubs foreign ones —
   the only way an album becomes library-grade.
4. **Import**: set `anyReleaseOk:true`, monitor the matching-track-count release (a
   sensible default, not a filter — `anyReleaseOk:true` accepts whatever release the tags
   name), `RefreshAlbum`; then `POST /api/v1/command {name:"ManualImport",
   importMode:"move", files:[…]}` mapping each file by the track Lidarr's manualimport
   assigns it (`item.tracks[0].id`, using the *item's own* `albumReleaseId`) — **not**
   blind sequential, and **not** `anyReleaseOk:false` (see the gotcha for why).
5. **Cleanup**: `shutil.rmtree` each imported dir; refresh the metric
   (`/usr/local/sbin/beets-pipeline-metric.sh`, root — also the service's ExecStopPost).

The `retag-mb.yaml` beets config — `musicbrainz` is a *plugin* in beets 2.x (without it,
zero candidates and everything skips); `fromfilename` reads track numbers from the
`NN Title` filenames shnsplit leaves, so untagged split/multi-disc rips match positionally
not by duration (a no-op once files carry real tags):

```yaml
directory: /data/media/music
plugins: [musicbrainz, scrub, fromfilename]
import: { copy: no, move: no, write: yes, quiet: yes, quiet_fallback: skip }
ui: { color: no }
match: { strong_rec_thresh: 1.0, rec_gap_thresh: 0.10 }   # permissive so --search-id always applies
scrub: { auto: yes }
```

## Stragglers — surface, never force

Park and report (do not import sub-standard):

- **No matching edition** — the rip is a deluxe/anniversary with more tracks than any
  MusicBrainz edition Lidarr models. Offer: re-grab a standard edition, or add the MB
  release as the edition.
- **Incomplete rip** — fewer tracks than the standard edition. Re-grab a complete
  per-track release; blocklist the bad one first via the queue.
- **APE disc image** — `monkeys-audio` is not packaged and ffmpeg-decoding APE proved
  to lose its split output. Do not split: remove the parked copy, blocklist the APE in
  the queue (`removeFromClient=true&blocklist=true`), and re-grab a per-track FLAC/MP3.
  The pristine original is still in `/data/downloads/completed/…`.
- **FLAC image with a malformed cue** — shnsplit yields zero tracks but exits 0; the
  splitter must not delete the original on a zero-track split (Phase 4 step 1). The
  pristine source survives in `completed/…` — re-grab a per-track release.
- **WavPack (`.wv`) image** — like APE, the FLAC-only splitter can't decode it; re-grab
  per-track. (`wvunpack` *is* packaged, unlike `mac`, if you ever extend the splitter.)
- **Multi-album pack** — one download holding several albums in subdirs (e.g. a `… Vinyls`
  folder of 4 LPs) matches nothing as a unit. Check each album's coverage; remove the
  pack and re-grab only the genuinely-missing ones — the rest are usually already in.
- **Bonus DVD / video** — a `[DVD]`/`(Bonus DVD)` folder has files=0 (no audio); junk.
  Remove it and blocklist that release; the audio album is a separate download.
- **Multi-disc nested rip** — disc subdirs (`Disc 1/`, `CD-01/`) each holding an image.
  Split + disc-tag + flatten per Phase 4 step 1, then it imports like any image; left as
  raw subdirs, `--search-id` skips and untagged files leak into the library. Park (remove +
  re-grab single-folder) only if Lidarr models no matching multi-disc edition.

When re-grabbing, force-grab the best non-image per-track release
(`POST /api/v1/release {guid, indexerId}`), preferring FLAC and excluding by title/quality:
cue/image, APE, WavPack/`.wv`, vinyl/LP/`24-96`/`24-48`/`TR24`/DVDA hi-res rips,
deluxe/iTunes, and DVD/bonus — any of which re-quarantine.

## Gotchas

- **minFormatScore** on the Lossless + High Quality profiles is 0 (relaxed) so +0
  releases pass; that also lets APE/cue images through, which is why Phase 4 exists.
- **Tracker 522/520 warnings** in the queue are transient Cloudflare announce errors,
  not import problems — ignore.
- **Never import with `anyReleaseOk:false`.** Pinning a release by track count and
  force-importing trips `Album release not requested` + move-but-not-link whenever a
  file's canonical tags resolve to a marginally different release of the same count —
  and it does happen *even after* `--search-id`, where it was assumed safe. Always
  import with `anyReleaseOk:true` (Phase 4 step 4).
- **Move-but-not-link recovery.** A ManualImport that reports mapped N but leaves the
  album 0/N failed in one of two ways: (a) files *moved* into the library unlinked —
  re-run ManualImport against the *library* folder in place with `anyReleaseOk:true`;
  (b) the move failed *outright*, files never left quarantine (check before you delete
  the quarantine dir!) — recover by splitting the original → `--search-id` tag → `mv`
  the tracks into the library folder yourself → in-place relink. A few stubborn albums
  (large single-file FLAC images) only import via path (b).
- **Orphaned queue items accumulate.** With CDH off, Lidarr never clears a queue item
  it didn't import itself, so every album the pipeline imports leaves a 100%/
  `importPending` orphan — and duplicate grabs (auto + manual + re-grab on one album)
  pile on more. Periodically clear them: for each queue item whose album is already
  complete, `DELETE /api/v1/queue/<id>?removeFromClient=true&blocklist=false` (no
  blocklist — the release is fine, just redundant). Leave genuine-straggler downloads
  (album still incomplete, only a bad rip available) — removing risks a re-grab loop.
- **Permutation rename.** If applying renames reports success but moves nothing, the
  album is a same-folder name permutation; do a temp-name permutation on disk
  (`os.rename` each to `.rtmp.N`, then to final) and `RefreshArtist`.
- **Re-grabs re-quarantine** — a re-grabbed album just re-enters Phase 4; fine.

## What this skill does not do

- It does not relax the standard. Every imported album is beets-scrubbed and
  MB-tagged; uncertain ones stay parked.
- It does not commit or touch the repo's Ansible, and it runs no Ansible plays — it
  operates the live Lidarr/beets *services* on solar (API + `podman exec`), the operator's
  standing intent when they ask for music, which is a sanctioned exception to the repo's
  "live hosts get --check/--diff only" rule.

## Final report

Per cycle: artists added (and which were already present), albums searched, albums
imported to standard (with track counts), and every straggler with the reason it was
parked and the recommended fix.
