import importlib.util
import sqlite3
import tempfile
import unittest
from pathlib import Path


SCRIPT = Path(__file__).resolve().parents[2] / "tokens" / "crew.py"
SPEC = importlib.util.spec_from_file_location("hud_crew", SCRIPT)
CREW = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(CREW)


class CurrentSessionModelTest(unittest.TestCase):
    def scan(self, model=None, provider=None, legacy=False):
        with tempfile.TemporaryDirectory() as tmp:
            db = Path(tmp) / "state.db"
            cfg = Path(tmp) / "config.yaml"
            cfg.write_text("model:\n  default: configured-model\n  provider: anthropic\n")
            with sqlite3.connect(db) as con:
                extra = "" if legacy else ", model TEXT, billing_provider TEXT"
                con.execute(
                    "CREATE TABLE sessions (started_at REAL, ended_at REAL,"
                    " last_activity_at REAL, title TEXT, api_call_count INTEGER,"
                    " input_tokens INTEGER, output_tokens INTEGER,"
                    " cache_read_tokens INTEGER, cache_write_tokens INTEGER,"
                    " archived INTEGER, hidden INTEGER" + extra + ")"
                )
                row = [9000, None, 9995, "Current work", 1, 10, 5, 0, 0, 0, 0]
                if not legacy:
                    row += [model, provider]
                con.execute(
                    "INSERT INTO sessions VALUES (" + ",".join("?" for _ in row) + ")",
                    row,
                )
                con.commit()
                return CREW.scan_store(db, "default", cfg, 1000, 10000)

    def test_live_session_metadata_overrides_configured_defaults(self):
        bot = self.scan("mimo-v2.6-flash", "opencode-go")
        self.assertEqual(bot["model"], "mimo-v2.6-flash")
        self.assertEqual(bot["provider"], "opencode-go")
        self.assertEqual(bot["state"], "active")
        self.assertEqual(bot["name"], "default")

    def test_missing_session_metadata_keeps_config_fallback(self):
        bot = self.scan()
        self.assertEqual(bot["model"], "configured-model")
        self.assertEqual(bot["provider"], "anthropic")
        self.assertEqual(bot["state"], "active")

    def test_older_schema_without_model_columns_keeps_existing_activity(self):
        bot = self.scan(legacy=True)
        self.assertEqual(bot["model"], "configured-model")
        self.assertEqual(bot["provider"], "anthropic")
        self.assertEqual(bot["state"], "active")


if __name__ == "__main__":
    unittest.main()
