"""File storage for uploaded documents.

Local disk by default (var/uploads). When SUPABASE_URL and SUPABASE_SERVICE_KEY are set, files go
to a private Supabase Storage bucket instead. Either way the API hands out short-lived signed
links (see security.sign_path), never public URLs.
"""
from __future__ import annotations

import json
import urllib.error
import urllib.request
import uuid
from pathlib import Path

from .settings import STORAGE_BUCKET, SUPABASE_SERVICE_KEY, SUPABASE_URL, UPLOAD_DIR


class LocalStorage:
    kind = "local"

    def __init__(self, root: Path = UPLOAD_DIR):
        self.root = Path(root)

    def _path(self, key: str) -> Path:
        p = (self.root / key).resolve()
        if self.root.resolve() not in p.parents:
            raise ValueError("bad storage key")
        return p

    def save(self, key: str, data: bytes, content_type: str) -> str:
        p = self._path(key)
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_bytes(data)
        return key

    def load(self, key: str) -> bytes:
        return self._path(key).read_bytes()

    def delete(self, key: str) -> None:
        self._path(key).unlink(missing_ok=True)


class SupabaseStorage:
    """Minimal client for Supabase Storage's REST API (service key stays on the server)."""
    kind = "supabase"

    def __init__(self, url: str = SUPABASE_URL, key: str = SUPABASE_SERVICE_KEY, bucket: str = STORAGE_BUCKET):
        self.base, self.key, self.bucket = url.rstrip("/") + "/storage/v1", key, bucket

    def _req(self, method: str, path: str, data: bytes | None = None, ctype: str | None = None):
        req = urllib.request.Request(f"{self.base}{path}", data=data, method=method)
        req.add_header("Authorization", f"Bearer {self.key}")
        req.add_header("apikey", self.key)
        if ctype:
            req.add_header("Content-Type", ctype)
        return urllib.request.urlopen(req, timeout=20)

    def ensure_bucket(self) -> None:
        try:
            self._req("POST", "/bucket", json.dumps({"id": self.bucket, "name": self.bucket, "public": False}).encode(),
                      "application/json")
        except urllib.error.HTTPError as e:
            if e.code not in (400, 409):        # already exists
                raise

    def save(self, key: str, data: bytes, content_type: str) -> str:
        self._req("POST", f"/object/{self.bucket}/{key}", data, content_type)
        return key

    def load(self, key: str) -> bytes:
        with self._req("GET", f"/object/{self.bucket}/{key}") as r:
            return r.read()

    def delete(self, key: str) -> None:
        try:
            self._req("DELETE", f"/object/{self.bucket}/{key}")
        except urllib.error.HTTPError as e:
            if e.code != 404:
                raise


def new_key(app_id: int, ext: str) -> str:
    """Uploaded files are renamed to random ids; the original name is kept only in the database."""
    return f"applications/{app_id}/{uuid.uuid4().hex}{ext}"


def default_storage():
    return SupabaseStorage() if (SUPABASE_URL and SUPABASE_SERVICE_KEY) else LocalStorage()
