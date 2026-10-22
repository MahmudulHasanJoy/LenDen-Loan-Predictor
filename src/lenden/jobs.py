"""Background jobs and a tiny scheduler.

On the free tier the scheduler runs as a thread inside the web process. Each job takes a
cluster-wide lock (PostgreSQL advisory lock) inside its own transaction, so if several instances
run, each job still runs once. Jobs are idempotent and catch up after the server wakes up.

    python -m lenden.jobs --once            # run every due job once (e.g. from a Render cron job)
    python -m lenden.jobs --run outbox_dispatch
"""
from __future__ import annotations

import argparse
import logging
import threading
import zlib
from datetime import timedelta

from . import clock, db
from .notifier import render, send_email, send_sms

log = logging.getLogger("lenden.jobs")
MAX_ATTEMPTS = 5


# ------------------------------------------------------------------ jobs
def outbox_dispatch(p) -> dict:
    sent = skipped = failed = 0
    rows = p._q("SELECT * FROM outbox WHERE processed_at IS NULL AND attempts < ? ORDER BY id LIMIT 50",
                (MAX_ATTEMPTS,))
    for r in rows:
        payload = r["payload"]
        try:
            if r["event"] == "notify.email":
                u = p._one("SELECT email, locale, notification_prefs, deleted_at, active FROM users WHERE id=?",
                           (payload["user_id"],))
                wants = (u and not u["deleted_at"] and (payload.get("transactional")
                                                        or (u["notification_prefs"] or {}).get("email", True)))
                if not wants or not p.flag("email_notifications"):
                    skipped += 1
                else:
                    subject, body = render(payload["event"], u["locale"] or "en", payload.get("data") or {})
                    send_email(u["email"], subject, body)
                    sent += 1
            elif r["event"] == "notify.sms":
                _, body = render(payload["event"], "en", payload.get("data") or {})
                send_sms(payload["phone"], body)
                sent += 1
            else:
                skipped += 1
            p.db.execute("UPDATE outbox SET processed_at=?, attempts=attempts+1 WHERE id=?", (db.now(), r["id"]))
        except Exception as e:                       # keep going; retry later
            failed += 1
            p.db.execute("UPDATE outbox SET attempts=attempts+1, last_error=? WHERE id=?", (str(e)[:300], r["id"]))
    return {"sent": sent, "skipped": skipped, "failed": failed}


def draft_reminders(p) -> dict:
    now = clock.utcnow()
    n = 0
    for d in p._q("SELECT * FROM drafts WHERE status='active' AND user_id IS NOT NULL AND reminders_sent < 2"):
        idle = now - clock.parse(d["updated_at"])
        due = (d["reminders_sent"] == 0 and idle >= timedelta(hours=24)) or \
              (d["reminders_sent"] == 1 and idle >= timedelta(hours=72))
        if due and clock.parse(d["expires_at"]) > now:
            p._notify(d["user_id"], "draft.reminder", {"draft_id": d["id"], "step": d["step"]})
            p.db.execute("UPDATE drafts SET reminders_sent=reminders_sent+1 WHERE id=?", (d["id"],))
            n += 1
    return {"reminded": n}


def doc_request_timers(p) -> dict:
    now = clock.utcnow()
    reminded = expired = 0
    for r in p._q("""SELECT r.*, a.borrower_id, a.assigned_to FROM document_requests r
                     JOIN applications a ON a.id=r.application_id WHERE r.status='open'"""):
        age = now - clock.parse(r["created_at"])
        if clock.parse(r["due_at"]) <= now:
            p.db.execute("UPDATE document_requests SET status='expired' WHERE id=?", (r["id"],))
            p._notify(r["borrower_id"], "documents.expired", {"application_id": r["application_id"]})
            if r["assigned_to"]:
                p._notify(r["assigned_to"], "documents.expired", {"application_id": r["application_id"]}, email=False)
            expired += 1
        elif (r["reminders_sent"] == 0 and age >= timedelta(days=2)) or (r["reminders_sent"] == 1 and age >= timedelta(days=5)):
            p._notify(r["borrower_id"], "documents.reminder", {"application_id": r["application_id"]})
            p.db.execute("UPDATE document_requests SET reminders_sent=reminders_sent+1 WHERE id=?", (r["id"],))
            reminded += 1
    return {"reminded": reminded, "expired": expired}


def repayment_due(p) -> dict:
    return p.run_repayment_checks()


def drift_report(p) -> dict:
    return {"snapshots": p.snapshot_drift()}


def cleanup(p) -> dict:
    now = db.now()
    p.db.execute("UPDATE drafts SET status='expired' WHERE status='active' AND expires_at<?", (now,))
    p.db.execute("UPDATE offers SET status='expired' WHERE status='estimate' AND expires_at<?", (now,))
    p.db.execute("DELETE FROM idempotency_keys WHERE created_at<?", (clock.iso(clock.utcnow() - timedelta(days=2)),))
    p.db.execute("DELETE FROM otp_codes WHERE expires_at<?", (clock.iso(clock.utcnow() - timedelta(days=1)),))
    cutoff = clock.iso(clock.utcnow() - timedelta(days=90))
    removed = 0
    for d in p._q("""SELECT d.id, d.storage_path FROM documents d JOIN applications a ON a.id=d.application_id
                     WHERE d.deleted_at IS NULL AND a.status IN ('rejected','withdrawn') AND a.updated_at<?""", (cutoff,)):
        try:
            p.storage.delete(d["storage_path"])
        except Exception as e:                       # pragma: no cover - storage outage
            log.warning("could not delete %s: %s", d["storage_path"], e)
            continue
        p.db.execute("UPDATE documents SET deleted_at=? WHERE id=?", (now, d["id"]))
        removed += 1
    return {"documents_removed": removed}


def refresh_models(p) -> dict:
    p.load_models()
    return {"active": p.model_version_label, "shadow": p.shadow_label}


JOBS = {  # name: (interval in seconds, function)
    "outbox_dispatch": (10, outbox_dispatch),
    "refresh_models": (60, refresh_models),
    "draft_reminders": (3600, draft_reminders),
    "doc_request_timers": (3600, doc_request_timers),
    "repayment_due": (6 * 3600, repayment_due),
    "drift_report": (24 * 3600, drift_report),
    "cleanup": (6 * 3600, cleanup),
}


# ------------------------------------------------------------------ scheduler
def run_job(p, name: str, force: bool = True) -> dict | None:
    """Run one job in its own transaction. Returns its result, or None if not due / locked elsewhere."""
    interval, fn = JOBS[name]
    with p.db.session():
        if not p.db.try_lock(zlib.crc32(f"lenden:{name}".encode())):
            return None
        last = p._scalar("SELECT last_run_at FROM job_runs WHERE name=?", (name,))
        if not force and last and (clock.utcnow() - clock.parse(last)).total_seconds() < interval:
            return None
        result = fn(p)
        p.db.execute("""INSERT INTO job_runs (name, last_run_at, last_result) VALUES (?,?,?)
                        ON CONFLICT(name) DO UPDATE SET last_run_at=excluded.last_run_at,
                        last_result=excluded.last_result""", (name, db.now(), str(result)[:500]))
        return result


def run_due(p) -> dict:
    out = {}
    for name in JOBS:
        try:
            r = run_job(p, name, force=False)
            if r is not None:
                out[name] = r
        except Exception:
            log.exception("job %s failed", name)
    return out


class Scheduler(threading.Thread):
    def __init__(self, platform, tick: float = 10.0):
        super().__init__(name="lenden-jobs", daemon=True)
        self.p, self.tick, self._halt = platform, tick, threading.Event()

    def run(self):
        while not self._halt.wait(self.tick):
            run_due(self.p)

    def stop(self):
        self._halt.set()


def main(argv=None):
    from .services import build_platform
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--once", action="store_true")
    ap.add_argument("--run", choices=sorted(JOBS))
    args = ap.parse_args(argv)
    p = build_platform()
    if args.run:
        print(args.run, run_job(p, args.run))
    else:
        print(run_due(p))
    if not args.once and not args.run:
        Scheduler(p).run()


if __name__ == "__main__":
    logging.basicConfig(level=logging.INFO)
    main()
