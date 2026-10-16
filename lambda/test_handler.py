import io
import time
import unittest
from contextlib import redirect_stdout

import handler


class FakeTable:
    def __init__(self):
        self.items = []

    def put_item(self, Item):
        self.items.append(Item)


def good(**over):
    base = {"device_id": "gs-001", "ts": time.time(), "temp_c": 24.6, "humidity": 61, "soil_pct": 40}
    base.update(over)
    return base


class ValidateTests(unittest.TestCase):
    def test_accepts_good_reading(self):
        clean, reason = handler.validate(good())
        self.assertIsNone(reason)
        self.assertEqual(clean["temp_c"], 24.6)

    def test_rejects_out_of_range(self):
        for field, value in [("temp_c", 200), ("humidity", -1), ("soil_pct", 101)]:
            with self.subTest(field=field):
                self.assertIsNotNone(handler.validate(good(**{field: value}))[1])

    def test_rejects_missing_and_wrong_types(self):
        for bad in [good(device_id=""), good(device_id=None), good(temp_c="hot"), good(humidity=True)]:
            with self.subTest(bad=bad):
                self.assertIsNone(handler.validate(bad)[0])
        missing = good()
        del missing["soil_pct"]
        self.assertIsNone(handler.validate(missing)[0])

    def test_rejects_stale_or_future_timestamp(self):
        self.assertIsNone(handler.validate(good(ts=time.time() - 3 * 86400))[0])
        self.assertIsNone(handler.validate(good(ts=time.time() + 3 * 86400))[0])


class HandlerTests(unittest.TestCase):
    def run_handler(self, event, table):
        out = io.StringIO()
        with redirect_stdout(out):
            result = handler.handler(event, table=table)
        return result, out.getvalue()

    def test_stores_valid_reading_and_emits_metric(self):
        table = FakeTable()
        result, log = self.run_handler(good(), table)
        self.assertTrue(result["stored"])
        self.assertEqual(len(table.items), 1)
        self.assertIn("ReadingsReceived", log)

    def test_invalid_reading_is_not_stored_but_is_counted(self):
        table = FakeTable()
        result, log = self.run_handler(good(temp_c=999), table)
        self.assertFalse(result["stored"])
        self.assertEqual(table.items, [])
        self.assertIn("InvalidReadings", log)


if __name__ == "__main__":
    unittest.main()
