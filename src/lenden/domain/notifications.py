"""In-app notification inbox."""
from __future__ import annotations

from .. import db
from ..errors import NotFound
from .base import Base


class Notifications(Base):
    def list_notifications(self, user: dict, limit: int = 30, cursor: str | None = None,
                           unread_only: bool = False) -> dict:
        offset = int(cursor) if cursor and cursor.isdigit() else 0
        where = "user_id=?" + (" AND read_at IS NULL" if unread_only else "")
        total = self._scalar(f"SELECT COUNT(*) FROM notifications WHERE {where}", (user["id"],))
        items = self._q(f"SELECT id, event, payload, created_at, read_at FROM notifications WHERE {where} "
                        "ORDER BY id DESC LIMIT ? OFFSET ?", (user["id"], min(limit, 100), offset))
        unread = self._scalar("SELECT COUNT(*) FROM notifications WHERE user_id=? AND read_at IS NULL", (user["id"],))
        nxt = offset + len(items)
        return {"items": items, "unread": unread, "total": total, "next_cursor": str(nxt) if nxt < total else None}

    def mark_read(self, user: dict, notification_id: int) -> dict:
        n = self._one("SELECT id FROM notifications WHERE id=? AND user_id=?", (notification_id, user["id"]))
        if not n:
            raise NotFound("Notification not found.", code="NOTIFICATION_NOT_FOUND")
        self.db.execute("UPDATE notifications SET read_at=? WHERE id=? AND read_at IS NULL", (db.now(), notification_id))
        return {"ok": True}

    def mark_all_read(self, user: dict) -> dict:
        self.db.execute("UPDATE notifications SET read_at=? WHERE user_id=? AND read_at IS NULL", (db.now(), user["id"]))
        return {"ok": True}
