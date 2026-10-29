"""Exercise UTC boundaries, historical pagination and dashboard HTTP controls."""
import json
import sqlite3
import unittest

from dashboard_keys import KeyAdminError
from dashboard_usage import history, summaries
from test_dashboard_keys import KeyHttpFixture


class UsageTests(KeyHttpFixture):
    def setUp(self):
        super().setUp()
        self.key = self.manager.create({"name": "usage-test"})["key"]
        directory = self.root / "usage"
        directory.mkdir()
        self.db = sqlite3.connect(directory / "requests.sqlite3")
        self.addCleanup(self.db.close)
        self.db.executescript("""
            CREATE TABLE metadata (name TEXT PRIMARY KEY, value INTEGER);
            INSERT INTO metadata VALUES ('recording_since', 1000);
            CREATE TABLE requests (id INTEGER PRIMARY KEY, started_at INTEGER, finished_at INTEGER,
                key_id TEXT, method TEXT, route TEXT, status INTEGER, elapsed_ms INTEGER,
                quota_charged INTEGER, no_speech INTEGER, cleanup_failed INTEGER);
        """)

    def record(self, at, status=200, charged=1, key=None):
        self.db.execute("INSERT INTO requests VALUES(NULL, ?, ?, ?, 'POST', '/v1/clean', ?, 50, ?, NULL, 0)",
                        (at, at + 50, key or self.key["id"], status, charged))
        self.db.commit()

    def test_utc_totals_and_key_listing_survive_new_reader(self):
        self.record(86400000 - 1)
        self.record(86400000, 400)
        self.record(86400001, 429, 0)
        usage = summaries(self.root, now=86401)["keys"][self.key["id"]]
        self.assertEqual((usage["total"], usage["today"], usage["today_charged"]), (3, 2, 1))
        self.assertEqual((usage["successful"], usage["failed"]), (1, 2))
        self.assertEqual(summaries(self.root, now=86401)["keys"][self.key["id"]], usage)
        listed = self.manager.listing()
        self.assertTrue(listed["usage_available"])
        self.assertEqual(listed["keys"][0]["usage"]["total"], 3)

    def test_cursor_has_no_duplicates_when_new_requests_arrive(self):
        for i in range(105):
            self.record(i)
        page = history(self.root, {})
        self.assertEqual(len(page["rows"]), 100)
        self.record(106)
        older = history(self.root, {"before_id": page["next_cursor"]})
        self.assertEqual(len(older["rows"]), 5)
        self.assertIsNone(older["next_cursor"])
        self.assertFalse({r["id"] for r in page["rows"]} & {r["id"] for r in older["rows"]})

    def test_filters_exclude_other_keys_and_use_inclusive_utc_dates(self):
        self.record(86400000, 429, 0)
        self.record(86400000, 200, key="0" * 16)
        self.record(86400000 - 1, 429, 0)
        self.record(2 * 86400000, 429, 0)
        result = history(self.root, {"key_id": self.key["id"], "status": "limited",
                                    "from": "1970-01-02", "to": "1970-01-02"})
        self.assertEqual(len(result["rows"]), 1)
        self.assertEqual(result["rows"][0]["started_at"], 86400000)

    def test_invalid_filters_fail_before_query(self):
        for payload in [None, [], {"token": "secret"}, {"key_id": "' OR 1=1"},
                        {"key_id": False}, {"status": []}, {"before_id": True},
                        {"before_id": 0}, {"from": "2026-10-99"},
                        {"from": "2026-10-06", "to": "2026-10-05"}]:
            with self.subTest(payload=payload), self.assertRaises(KeyAdminError) as error:
                history(self.root, payload)
            self.assertEqual(error.exception.status, 400)

    def test_history_http_is_read_only_and_requires_admin_marker(self):
        self.record(1000)
        before = (self.root / "api-keys.json").read_bytes()
        self.assertEqual(self.request("POST", "/api/keys/usage", {})[0], 403)
        code, data, _ = self.request("POST", "/api/keys/usage", {},
                                     {"X-OLIV-Admin": "1", "Content-Type": "application/json"})
        self.assertEqual(code, 200)
        self.assertEqual(len(data["rows"]), 1)
        self.assertEqual((self.root / "api-keys.json").read_bytes(), before)
        self.assertNotIn("sha256", json.dumps(data))

    def test_corrupt_database_is_unavailable_without_hiding_keys(self):
        self.db.close()
        (self.root / "usage/requests.sqlite3").write_bytes(b"synthetic-secret-corrupt")
        result = self.manager.listing()
        self.assertFalse(result["usage_available"])
        self.assertEqual(len(result["keys"]), 1)
        with self.assertRaises(KeyAdminError) as error:
            history(self.root, {})
        self.assertEqual(error.exception.status, 503)
        self.assertNotIn("synthetic", str(error.exception))


if __name__ == "__main__":
    unittest.main()
