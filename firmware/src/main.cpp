// GreenSense firmware: reads a DHT22 (temperature, humidity) and a soil moisture
// sensor, then publishes JSON to AWS IoT Core over MQTT with mutual TLS.
#include <Arduino.h>
#include <ArduinoJson.h>
#include <DHT.h>
#include <PubSubClient.h>
#include <WiFi.h>
#include <WiFiClientSecure.h>
#include <time.h>

#include "secrets.h"

constexpr uint8_t DHT_PIN = 4;
constexpr uint8_t SOIL_PIN = 34;  // ADC1 pin: works while Wi-Fi is active
constexpr uint32_t PUBLISH_INTERVAL_MS = 10000;
// Calibrate on your sensor: raw ADC in dry air and in water.
constexpr int SOIL_DRY = 3200;
constexpr int SOIL_WET = 1300;

DHT dht(DHT_PIN, DHT22);
WiFiClientSecure tls;
PubSubClient mqtt(tls);
char topic[96];
uint32_t lastPublish = 0;

float soilPercent(int raw) {
  float pct = 100.0f * (SOIL_DRY - raw) / (SOIL_DRY - SOIL_WET);
  return constrain(pct, 0.0f, 100.0f);
}

void connectWifi() {
  WiFi.mode(WIFI_STA);
  WiFi.begin(WIFI_SSID, WIFI_PASSWORD);
  Serial.print("[wifi] connecting");
  for (uint32_t start = millis(); WiFi.status() != WL_CONNECTED; delay(500)) {
    Serial.print('.');
    if (millis() - start > 30000) ESP.restart();  // stuck: reboot and retry
  }
  Serial.printf("\n[wifi] connected, rssi %d dBm\n", WiFi.RSSI());
}

void syncClock() {
  configTime(0, 0, "pool.ntp.org", "time.google.com");
  for (int i = 0; time(nullptr) < 1700000000 && i < 40; i++) delay(500);  // TLS needs a valid clock
}

void connectMqtt() {
  while (!mqtt.connected()) {
    Serial.print("[mqtt] connecting... ");
    if (mqtt.connect(DEVICE_ID)) {
      Serial.println("connected");
    } else {
      Serial.printf("failed rc=%d, retry in 5s\n", mqtt.state());
      delay(5000);
    }
  }
}

void setup() {
  Serial.begin(115200);
  dht.begin();
  snprintf(topic, sizeof(topic), "greensense/%s/telemetry", DEVICE_ID);
  connectWifi();
  syncClock();
  tls.setCACert(AWS_ROOT_CA);
  tls.setCertificate(DEVICE_CERT);
  tls.setPrivateKey(DEVICE_KEY);
  mqtt.setServer(AWS_IOT_ENDPOINT, 8883);
}

void loop() {
  if (WiFi.status() != WL_CONNECTED) connectWifi();
  connectMqtt();
  mqtt.loop();

  if (millis() - lastPublish < PUBLISH_INTERVAL_MS) return;
  lastPublish = millis();

  float t = dht.readTemperature();
  float h = dht.readHumidity();
  if (isnan(t) || isnan(h)) {
    Serial.println("[sensor] DHT read failed, skipping this cycle");
    return;  // never publish garbage: silence is alarmed on in the cloud
  }

  JsonDocument doc;
  doc["device_id"] = DEVICE_ID;
  doc["ts"] = (uint32_t)time(nullptr);
  doc["temp_c"] = t;
  doc["humidity"] = h;
  doc["soil_pct"] = soilPercent(analogRead(SOIL_PIN));

  char payload[256];
  size_t n = serializeJson(doc, payload, sizeof(payload));
  bool ok = mqtt.publish(topic, (const uint8_t*)payload, n);
  Serial.printf("[mqtt] publish %s: %s\n", ok ? "ok" : "FAILED", payload);
}
