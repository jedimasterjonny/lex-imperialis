#!/usr/bin/env python3
"""Assert the CSP script-src hashes in firebase.json match the site's inline scripts.

`firebase.json` hash-pins the theme's inline script, so a Blowfish bump that
rewrites that script silently invalidates the pin: hugo still builds, every gate
stays green, and the browser blocks the script on the live site. Nothing else
compares the two — this does, from a fresh build, so the mismatch fails the site
gate instead of shipping.

Both directions fail. A served hash that is not pinned is the breakage; a pinned
hash nothing serves is a stale pin left behind by the bump that caused it, which
is the same defect one commit later.

Only executable scripts count. A `<script>` whose type is neither a JavaScript
MIME type nor `module` is a data block — the HTML spec stops preparing it before
any CSP check, so script-src never applies (the theme's `application/ld+json`
structured data is why this matters). Element text is hashed raw: HTMLParser
hands back script content unescaped, which is what CSP digests.
"""

import base64
import hashlib
import json
import re
import sys
from html.parser import HTMLParser
from pathlib import Path

# https://mimesniff.spec.whatwg.org/#javascript-mime-type
JS_MIME_TYPES = {
    "application/ecmascript",
    "application/javascript",
    "application/x-ecmascript",
    "application/x-javascript",
    "text/ecmascript",
    "text/javascript",
    "text/javascript1.0",
    "text/javascript1.1",
    "text/javascript1.2",
    "text/javascript1.3",
    "text/javascript1.4",
    "text/javascript1.5",
    "text/jscript",
    "text/livescript",
    "text/x-ecmascript",
    "text/x-javascript",
}


class InlineScriptCollector(HTMLParser):
    """Collects the text of every executable inline script."""

    def __init__(self) -> None:
        super().__init__(convert_charrefs=False)
        self.scripts = []
        self._capturing = False

    def handle_starttag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        if tag != "script":
            return
        attributes = dict(attrs)
        if attributes.get("src") is not None:
            return
        # An absent type attribute defaults to classic JavaScript.
        script_type = (attributes.get("type") or "").strip().lower()
        script_type = script_type.split(";", 1)[0].strip()
        if script_type in ("", "module") or script_type in JS_MIME_TYPES:
            self._capturing = True

    def handle_data(self, data: str) -> None:
        if self._capturing:
            self.scripts.append(data)
            self._capturing = False

    def handle_endtag(self, tag: str) -> None:
        if tag == "script":
            self._capturing = False


def csp_script_src_hashes(firebase_json: Path) -> set[str]:
    """Return the set of sha256 hashes pinned in the CSP script-src directive."""
    config = json.loads(firebase_json.read_text(encoding="utf-8"))
    for header_block in config["hosting"]["headers"]:
        for header in header_block["headers"]:
            if header["key"].lower() != "content-security-policy":
                continue
            for directive in header["value"].split(";"):
                if directive.strip().startswith("script-src"):
                    return set(re.findall(r"'(sha256-[A-Za-z0-9+/=]+)'", directive))
    return set()


def served_hashes(build_dir: Path) -> dict[str, list[Path]]:
    """Map each executable inline script's hash to the pages serving it."""
    found = {}
    for page in sorted(build_dir.rglob("*.html")):
        collector = InlineScriptCollector()
        collector.feed(page.read_text(encoding="utf-8"))
        collector.close()
        for script in collector.scripts:
            if not script.strip():
                continue
            digest = hashlib.sha256(script.encode("utf-8")).digest()
            hashed = "sha256-" + base64.b64encode(digest).decode()
            found.setdefault(hashed, []).append(page)
    return found


def main(argv: list[str]) -> int:
    try:
        build_dir, firebase_json = map(Path, argv)
    except ValueError:
        print("usage: check-csp-hashes.py <build-dir> <firebase.json>", file=sys.stderr)
        return 2

    if not build_dir.is_dir():
        print(f"{build_dir}: not a directory — build the site first", file=sys.stderr)
        return 2

    served = served_hashes(build_dir)
    if not served:
        print(
            f"{build_dir}: no inline scripts found — is the build empty?",
            file=sys.stderr,
        )
        return 2

    pinned = csp_script_src_hashes(firebase_json)

    status = 0
    for hashed in sorted(set(served) - pinned):
        page = served[hashed][0].relative_to(build_dir)
        print(
            f"{firebase_json}: inline script served by {page} is not pinned in the CSP "
            f"script-src — add '{hashed}'",
            file=sys.stderr,
        )
        status = 1
    for hashed in sorted(pinned - set(served)):
        print(
            f"{firebase_json}: CSP script-src pins '{hashed}', which no built page "
            f"serves — drop it",
            file=sys.stderr,
        )
        status = 1
    return status


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
