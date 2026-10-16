"""Run the whole ingest path locally with no AWS account and no hardware.

Generates realistic readings (plus a few faults) and feeds them through the real
Lambda handler into an in-memory table, then prints what was stored or rejected.
Usage: python3 simulator/simulate.py [count]
"""
import math
import os
import random
import sys
import time
from contextlib import redirect_stdout
from io import StringIO

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "lambda"))
import handler  # noqa: E402


class MemoryTable:
    def __init__(self):
        self.items = []

    def put_item(self, Item):
        self.items.append(Item)


def reading(device, step, fault=None):
    day = math.sin(step / 12)
    r = {
        "device_id": device,
        "ts": time.time(),
        "temp_c": round(23 + 3 * day + random.uniform(-0.3, 0.3), 2),
        "humidity": round(60 - 8 * day + random.uniform(-1, 1), 2),
        "soil_pct": round(max(0, 45 - step * 0.2 + random.uniform(-0.5, 0.5)), 2),
    }
    if fault == "sensor":
        r["temp_c"] = 999  # stuck/failed sensor
    if fault == "missing":
        del r["humidity"]
    return r


def main(count):
    random.seed(7)
    table = MemoryTable()
    stored = rejected = 0
    for step in range(count):
        for device in ("gs-001", "gs-002"):
            fault = "sensor" if (device == "gs-002" and step % 17 == 5) else "missing" if (device == "gs-001" and step % 23 == 11) else None
            with redirect_stdout(StringIO()):
                result = handler.handler(reading(device, step, fault), table=table)
            if result["stored"]:
                stored += 1
            else:
                rejected += 1
                print(f"rejected {device} step {step}: {result['reason']}")
    print(f"\nstored {stored}, rejected {rejected}, rows in table {len(table.items)}")
    last = table.items[-1]
    print("last stored:", {k: str(v) for k, v in last.items()})


if __name__ == "__main__":
    main(int(sys.argv[1]) if len(sys.argv) > 1 else 60)
