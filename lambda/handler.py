"""GreenSense ingest Lambda.

Triggered by an AWS IoT rule for each telemetry message. Validates the reading,
stores it, and emits a CloudWatch metric (via Embedded Metric Format) so that
"device went silent" can be alarmed on, not just bad values.
"""
import json
import os
import time

LIMITS = {"temp_c": (-40.0, 80.0), "humidity": (0.0, 100.0), "soil_pct": (0.0, 100.0)}
MAX_CLOCK_SKEW_S = 24 * 3600
NAMESPACE = "GreenSense"

_table = None


def _get_table():
    global _table
    if _table is None:
        import boto3  # imported lazily so unit tests need no AWS SDK

        _table = boto3.resource("dynamodb").Table(os.environ["TABLE_NAME"])
    return _table


def validate(event, now=None):
    """Return (clean_reading, None) or (None, reason)."""
    now = time.time() if now is None else now
    device = event.get("device_id")
    if not isinstance(device, str) or not 1 <= len(device) <= 64:
        return None, "invalid device_id"
    ts = event.get("ts")
    if not isinstance(ts, (int, float)) or abs(now - ts) > MAX_CLOCK_SKEW_S:
        return None, "timestamp missing or too far from server time"
    clean = {"device_id": device, "ts": int(ts)}
    for field, (lo, hi) in LIMITS.items():
        value = event.get(field)
        if isinstance(value, bool) or not isinstance(value, (int, float)):
            return None, f"{field} missing or not a number"
        if not lo <= value <= hi:
            return None, f"{field} out of range ({value})"
        clean[field] = round(float(value), 2)
    return clean, None


def emit_metric(device_id, name, value=1):
    """CloudWatch Embedded Metric Format: one structured log line becomes a metric."""
    print(json.dumps({
        "_aws": {
            "Timestamp": int(time.time() * 1000),
            "CloudWatchMetrics": [{
                "Namespace": NAMESPACE,
                "Dimensions": [["DeviceId"]],
                "Metrics": [{"Name": name, "Unit": "Count"}],
            }],
        },
        "DeviceId": device_id,
        name: value,
    }))


def handler(event, context=None, table=None):
    reading, reason = validate(event)
    device = event.get("device_id") if isinstance(event.get("device_id"), str) else "unknown"
    if reading is None:
        emit_metric(device, "InvalidReadings")
        print(json.dumps({"level": "warn", "device_id": device, "rejected": reason}))
        return {"stored": False, "reason": reason}
    (table or _get_table()).put_item(Item=_to_decimal(reading))
    emit_metric(device, "ReadingsReceived")
    return {"stored": True}


def _to_decimal(item):
    """DynamoDB rejects floats; convert via str to avoid binary rounding noise."""
    from decimal import Decimal

    return {k: Decimal(str(v)) if isinstance(v, float) else v for k, v in item.items()}
