"""A stand-in for R2's S3 API, serving canned listings to the probe.

The bucket is not reachable from a throwaway container, and pointing the probe at
the real one would make the scenario depend on live backup state. This answers
the two calls the probe makes, with a fixture chosen to exercise the cases that
matter: an object listing whose pages split one container's objects, a container
with a stranded multipart upload, and a prefix nobody declared. Signatures are
not checked — what is under test is the probe's tallying and output, not R2's
authorisation, which the role cannot influence anyway.
"""

import http.server
import sys

PAGE_ONE = """<?xml version="1.0" encoding="UTF-8"?>
<ListBucketResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/">
  <IsTruncated>true</IsTruncated>
  <NextContinuationToken>PAGE2</NextContinuationToken>
  <Contents><Key>home.hbk/one</Key><Size>1000</Size>
    <LastModified>2026-08-28T09:00:00.000Z</LastModified></Contents>
</ListBucketResult>"""

PAGE_TWO = """<?xml version="1.0" encoding="UTF-8"?>
<ListBucketResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/">
  <IsTruncated>false</IsTruncated>
  <Contents><Key>home.hbk/two</Key><Size>2000</Size>
    <LastModified>2026-08-28T10:00:00.000Z</LastModified></Contents>
  <Contents><Key>podman.hbk/one</Key><Size>4000</Size>
    <LastModified>2026-08-27T06:00:00.000Z</LastModified></Contents>
  <Contents><Key>stray.hbk/one</Key><Size>8000</Size>
    <LastModified>2026-08-01T00:00:00.000Z</LastModified></Contents>
</ListBucketResult>"""

UPLOADS = """<?xml version="1.0" encoding="UTF-8"?>
<ListMultipartUploadsResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/">
  <IsTruncated>false</IsTruncated>
  <Upload><Key>podman.hbk/interrupted</Key><UploadId>abc</UploadId></Upload>
</ListMultipartUploadsResult>"""


class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self) -> None:  # the name BaseHTTPRequestHandler dispatches to
        if "uploads" in self.path:
            body = UPLOADS
        elif "continuation-token=PAGE2" in self.path:
            body = PAGE_TWO
        else:
            body = PAGE_ONE
        payload = body.encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/xml")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def log_message(self, *_args: object) -> None:
        pass


if __name__ == "__main__":
    http.server.HTTPServer(("127.0.0.1", int(sys.argv[1])), Handler).serve_forever()
