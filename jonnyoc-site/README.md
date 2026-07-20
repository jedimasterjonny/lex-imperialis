# jonnyoc-site

The `jonnyoc.uk` website: a Hugo static site, Blowfish theme pulled as a Hugo
Module (`go.mod`). CI builds and deploys it to Firebase Hosting (project
`jonnyoc-website`) on any change under `jonnyoc-site/` — a push to `main` deploys
the live channel, a PR a 30-day preview channel
(`.github/workflows/firebase-hosting-*.yml`).

Local preview needs `hugo` **and** `go` on PATH (the theme is a Hugo Module,
fetched via the Go toolchain) — the `dev` role provisions both on the
workstation:

    make hugo-serve      # serves on http://localhost:1313
    make hugo-build      # renders to public/, exactly as CI does

The deploy authenticates to GCP keylessly via Workload Identity Federation, so it
needs no secret; the deploy service account, WIF binding, `jonnyoc.uk` DNS, and
the Firebase verification TXT are all managed in `terraform/`.

`firebase.json` sets the response headers. HTML is `no-cache` (fingerprinted
CSS/JS/images keep their long `immutable`/30d TTLs via the later, more specific
blocks); the CSP `script-src` hash-pins the theme's one inline script, so a
Blowfish bump that changes it must have the `sha256-` regenerated from a fresh
`make hugo-build`. HSTS is intentionally bare `max-age` — `includeSubDomains`
(and thus `preload`) on the apex would bind the unmanaged dynamic-DNS subdomain
to HTTPS.
