# Backend

Rust (Axum) API service for the evidence and media platform.

## Running locally

```sh
cargo run
```

Configuration is read from environment variables (see `.env.example`).

## Evidence & media upload security

Uploads are treated as untrusted input. The server enforces the following
controls independently of anything the browser declares.

### Size and content-type allowlists

- **Size limit:** every upload is capped by `MAX_UPLOAD_BYTES` (default 25 MiB).
  Requests exceeding the limit are rejected with `413 Payload Too Large` before
  the body is buffered to disk.
- **Type allowlist:** only the following content types are accepted:
  `image/jpeg`, `image/png`, `image/webp`, `application/pdf`, `video/mp4`.
  Anything else is rejected with `415 Unsupported Media Type`.

### Content sniffing (server-side)

The declared `Content-Type` / file extension is **never trusted**. The server
inspects the leading magic bytes of the payload and derives the real content
type from them. If the sniffed type does not match the allowlist, or does not
match the declared type, the upload is rejected. This blocks spoofed MIME
uploads (e.g. an executable renamed to `.png`).

### Malware scanning and quarantine

- Every accepted upload is scanned before it becomes retrievable.
- On a **positive detection** the object is moved to the quarantine bucket and
  the request fails with `422 Unprocessable Entity`.
- On a **scanner error / timeout** the upload is treated as untrusted: it stays
  in quarantine and is **not** served. Failures are fail-closed.
- Quarantine events are logged with the object key and reason so they are
  observable in the application logs and metrics.

### Private storage and object-key isolation

- Objects are stored **private by default**; there is no public/anonymous read
  path. Buckets deny public ACLs.
- Object keys are generated server-side as random, non-guessable identifiers
  (UUIDv4) and are namespaced per tenant/owner. Client-supplied paths or keys
  are ignored, preventing path traversal and key manipulation.

### Signed URL expiry

- Objects are only reachable through short-lived signed URLs.
- Signed URLs expire after `SIGNED_URL_TTL_SECONDS` (default 300s) and are
  scoped to a single object key. Expired or tampered links are rejected.

### Cleanup of abandoned uploads

- Uploads that are started but never completed (or that fail scanning) are
  removed by a periodic cleanup job after `UPLOAD_ABANDON_TTL_SECONDS`
  (default 86400s).

### Validation checklist

When changing upload handling, verify:

- Spoofed MIME (executable renamed to an allowed image type) is rejected.
- Oversized payloads are rejected with `413`.
- Path/key manipulation attempts cannot escape the owner namespace.
- Expired signed URLs are rejected.
