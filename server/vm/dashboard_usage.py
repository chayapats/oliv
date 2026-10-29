"""Read-only, bounded usage reporting from the API's private SQLite audit store."""
import contextlib
import sqlite3
import time
from datetime import date
from pathlib import Path
from urllib.parse import quote

from dashboard_keys import ID, KeyAdminError, invalid


@contextlib.contextmanager
def database(root):
    path = Path(root) / "usage/requests.sqlite3"
    if not path.is_file():
        yield None
        return
    try:
        connection = sqlite3.connect("file:" + quote(str(path.resolve()), safe="/") + "?mode=ro", uri=True, timeout=1)
        connection.row_factory = sqlite3.Row
        try:
            yield connection
        finally:
            connection.close()
    except sqlite3.Error:
        raise KeyAdminError(503, "usage_unavailable", "Usage history is unavailable") from None


def summaries(root, now=None):
    now = int(time.time()) if now is None else now
    today = now // 86400 * 86400000
    with database(root) as db:
        if db is None:
            return None
        # One indexed grouping, never one full scan per key.
        rows = db.execute("""SELECT key_id, count(*) AS total,
            sum(status < 400) AS successful, sum(status >= 400) AS failed,
            sum(quota_charged) AS quota_charged,
            sum(started_at >= ?) AS today,
            sum(CASE WHEN started_at >= ? THEN quota_charged ELSE 0 END) AS today_charged,
            max(started_at) AS last_used
            FROM requests WHERE key_id IS NOT NULL GROUP BY key_id""", (today, today))
        keys = {row["key_id"]: {name: row[name] for name in
                ("total", "successful", "failed", "quota_charged", "today", "today_charged", "last_used")}
                for row in rows}
        since = db.execute("SELECT value FROM metadata WHERE name='recording_since'").fetchone()[0]
        return {"keys": keys, "recording_since": since, "day_start": today}


def date_ms(value, name):
    if not isinstance(value, str) or len(value) != 10:
        raise invalid(f"{name} must be a UTC date (YYYY-MM-DD)")
    try:
        parsed = date.fromisoformat(value)
        if parsed.isoformat() != value:
            raise ValueError
        return (parsed - date(1970, 1, 1)).days * 86400000
    except ValueError:
        raise invalid(f"{name} must be a UTC date (YYYY-MM-DD)") from None


def history(root, posted):
    if not isinstance(posted, dict) or set(posted) - {"key_id", "status", "from", "to", "before_id"}:
        raise invalid("Unknown usage filters")
    clauses, args = [], []
    key = posted.get("key_id", "")
    if key:
        if not isinstance(key, str) or not ID.fullmatch(key):
            raise invalid("Provide one valid key ID")
        clauses.append("key_id = ?")
        args.append(key)
    elif not isinstance(key, str):
        raise invalid("Provide one valid key ID")
    status = posted.get("status", "all")
    if status not in ("all", "success", "error", "limited", "anonymous"):
        raise invalid("Unknown usage status")
    if status != "all":
        clauses.append({"success": "status < 400", "error": "status >= 400",
                        "limited": "status = 429", "anonymous": "key_id IS NULL"}[status])
    lower = date_ms(posted["from"], "from") if posted.get("from") else None
    upper = date_ms(posted["to"], "to") if posted.get("to") else None
    if lower is not None and upper is not None and lower > upper:
        raise invalid("Date range is reversed")
    if lower is not None:
        clauses.append("started_at >= ?")
        args.append(lower)
    if upper is not None:
        clauses.append("started_at < ?")
        args.append(upper + 86400000)
    cursor = posted.get("before_id")
    if cursor is not None:
        if type(cursor) is not int or not 1 <= cursor <= 2**63 - 1:
            raise invalid("Invalid history cursor")
        clauses.append("id < ?")
        args.append(cursor)
    where = " WHERE " + " AND ".join(clauses) if clauses else ""
    with database(root) as db:
        if db is None:
            raise KeyAdminError(503, "usage_unavailable", "Usage recording has not started")
        rows = [dict(row) for row in db.execute("""SELECT id, started_at, finished_at, key_id,
            method, route, status, elapsed_ms, quota_charged, no_speech, cleanup_failed
            FROM requests""" + where + " ORDER BY id DESC LIMIT 101", args)]
        more = len(rows) > 100
        rows = rows[:100]
        return {"ok": True, "rows": rows, "next_cursor": rows[-1]["id"] if more else None}
