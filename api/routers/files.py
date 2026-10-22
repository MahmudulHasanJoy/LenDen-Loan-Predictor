"""Signed, short-lived file downloads (like signed URLs)."""
from fastapi import APIRouter
from fastapi.responses import Response

from ..deps import platform, run

router = APIRouter(tags=["files"])


@router.get("/files/{token}")
def download(token: str):
    data, ctype, filename = run(platform.read_file, token)
    safe = "".join(c for c in filename if c.isalnum() or c in "._- ")[:80] or "document"
    return Response(content=data, media_type=ctype,
                    headers={"Content-Disposition": f'attachment; filename="{safe}"', "Cache-Control": "no-store"})
