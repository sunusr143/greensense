# GreenSense

ESP32 sensor boards publish temperature, humidity and soil moisture to AWS IoT Core over MQTT with mutual TLS. An IoT rule routes each message to a Lambda that validates and stores it, and CloudWatch alarms fire when a device goes silent or sends bad data. Firmware and cloud code are built and tested in CI.

```
ESP32 + DHT22 + soil sensor
   | MQTT over TLS (per-device certificate)
   v
AWS IoT Core --rule--> Lambda (validate) --> DynamoDB
                          |
                          +--> CloudWatch metrics --> alarms --> SNS email
```

## What is verified, and what is not

| Part | Status |
|---|---|
| Lambda validation + handler | 6 unit tests pass (`python3 -m unittest discover -s lambda`) |
| Ingest path | `python3 simulator/simulate.py` runs readings (with injected faults) through the real handler, no AWS needed |
| Firmware | Compiles for `esp32dev` with PlatformIO (`pio run`) |
| Terraform | `terraform fmt -check` and `terraform validate` pass |
| Deployed to AWS / flashed to a board | **Not done yet.** Needs your AWS account and hardware |

## Layout

- `firmware/` PlatformIO project (Arduino framework). Copy `include/secrets.h.example` to `secrets.h`.
- `lambda/` ingest handler and tests (stdlib only).
- `simulator/` local end-to-end run.
- `terraform/` things, certificates, least-privilege policy, rule, Lambda, DynamoDB, alarms.
- `.github/workflows/ci.yml` tests, validates Terraform and builds the firmware.

## Wiring (ESP32 dev board)

DHT22 data -> GPIO 4. Capacitive soil sensor analog out -> GPIO 34 (ADC1). Power both from 3V3. Calibrate `SOIL_DRY` and `SOIL_WET` in `firmware/src/main.cpp` against your sensor.

## Deploy

```
cd terraform
terraform init
terraform apply -var alert_email=you@example.com
terraform output -json certificate_pem   # and private_keys: flash to each board
aws iot describe-endpoint --endpoint-type iot:Data-ATS
```

Certificate private keys end up in Terraform state. Use an encrypted remote backend and restrict access.

## Design decisions

- **One certificate per device**, policy allows connect and publish only as itself, so one stolen board can be revoked alone.
- **The rule takes the device id from the topic**, not the payload, so a device cannot impersonate another.
- **Alarm on silence** (`treat_missing_data = breaching`) as well as on invalid data; a dead sensor sends nothing.
- **Firmware skips a cycle on a failed sensor read** instead of publishing garbage.
- **Firmware is a CI artifact**, built the same way as the cloud code.

## Next steps

OTA updates with signed images and staged rollout, a dashboard, DynamoDB TTL for retention, a Raspberry Pi gateway variant for non-WiFi sensors.
