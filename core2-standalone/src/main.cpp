// Shows the Ray-Ban Meta camera stream relayed by glasses-bridge/pc/viewer.py.
//
// Protocol (WebSocket client to ws://RELAY_HOST:RELAY_PORT/core2):
//   Core2 -> PC  text  {"type":"hello","width":W,"height":H}  video area size
//                      {"type":"next"}                        ready for one more frame
//                      {"type":"button","id":"A"|"C"|"C_HOLD"} touch button pressed
//                      {"type":"audio_start","rate":16000}, binary 16-bit PCM chunks,
//                      {"type":"audio_end"}                   spoken question (hold B)
//   PC -> Core2  binary one JPEG, already sized W x H (must stay under 15 KB)
//                text   {"type":"status","text":"..."}        bottom status line
//                       {"type":"answer","text":"..."}        agent answer panel (tap to close)
//
// Frames are pulled: the PC only sends after "next", so latency never builds up.

#include <ArduinoJson.h>
#include <M5Unified.h>
#include <WebSocketsClient.h>
#include <WiFi.h>

#include "secrets.h"

namespace {

constexpr int kStatusHeight = 40;
constexpr uint32_t kSampleRate = 16000;
constexpr size_t kChunkSamples = kSampleRate / 10;  // 100 ms
constexpr size_t kMaxChunks = 150;                  // 15 s of speech
constexpr size_t kSendBytes = 8 * 1024;

WebSocketsClient ws;
bool wsConnected = false;
String statusText = "Starting...";
uint32_t framesThisSecond = 0;
uint32_t fps = 0;
uint32_t lastFpsMillis = 0;
uint32_t lastFrameMillis = 0;

int16_t* audio = nullptr;  // PSRAM, kMaxChunks * kChunkSamples
size_t queuedChunks = 0;
bool recording = false;
bool answerVisible = false;

int videoWidth() { return M5.Display.width(); }
int videoHeight() { return M5.Display.height() - kStatusHeight; }

void drawStatus() {
  auto& d = M5.Display;
  const int top = d.height() - kStatusHeight;
  d.fillRect(0, top, d.width(), kStatusHeight, TFT_BLACK);
  d.setFont(&fonts::Font2);
  d.setTextColor(TFT_WHITE, TFT_BLACK);
  d.setTextWrap(true);
  d.setClipRect(0, top, d.width() - 44, kStatusHeight);
  d.setCursor(4, top + 3);
  d.print(statusText);
  d.clearClipRect();
  d.setTextColor(TFT_GREEN, TFT_BLACK);
  d.setCursor(d.width() - 40, top + 3);
  d.printf("%2ufps", static_cast<unsigned>(fps));
}

void setStatus(const String& text) {
  statusText = text;
  drawStatus();
}

void showMessage(const String& text) {
  auto& d = M5.Display;
  d.fillRect(0, 0, videoWidth(), videoHeight(), TFT_DARKGREY);
  d.setFont(&fonts::Font2);
  d.setTextColor(TFT_WHITE, TFT_DARKGREY);
  d.setTextWrap(true);
  d.setCursor(8, videoHeight() / 2 - 16);
  d.print(text);
}

void sendJson(JsonDocument& doc) {
  String out;
  serializeJson(doc, out);
  ws.sendTXT(out);
}

void requestFrame() {
  ws.sendTXT("{\"type\":\"next\"}");
}

void showAnswer(const char* text) {
  auto& d = M5.Display;
  answerVisible = true;
  d.fillRect(0, 0, videoWidth(), videoHeight(), TFT_NAVY);
  d.setFont(&fonts::Font2);
  d.setTextColor(TFT_WHITE, TFT_NAVY);
  d.setTextWrap(true);
  d.setClipRect(0, 0, videoWidth(), videoHeight());
  d.setCursor(6, 6);
  d.print(text);
  d.clearClipRect();
  setStatus("Tap screen to close");
}

void handleText(const uint8_t* payload, size_t length) {
  JsonDocument doc;
  if (deserializeJson(doc, payload, length)) return;
  const char* type = doc["type"] | "";
  if (strcmp(type, "status") == 0) {
    setStatus(doc["text"] | "");
  } else if (strcmp(type, "answer") == 0) {
    showAnswer(doc["text"] | "");
  }
}

void onWebSocket(WStype_t type, uint8_t* payload, size_t length) {
  switch (type) {
    case WStype_CONNECTED: {
      wsConnected = true;
      setStatus("Relay connected");
      showMessage("Waiting for glasses...");
      JsonDocument hello;
      hello["type"] = "hello";
      hello["width"] = videoWidth();
      hello["height"] = videoHeight();
      sendJson(hello);
      requestFrame();
      break;
    }
    case WStype_DISCONNECTED:
      if (wsConnected) {
        wsConnected = false;
        setStatus("Relay disconnected");
        showMessage("Relay " RELAY_HOST " offline");
      }
      break;
    case WStype_BIN:
      // While an answer is shown, frames are not requested; this one is a stray.
      if (answerVisible) break;
      M5.Display.drawJpg(payload, length, 0, 0, videoWidth(), videoHeight());
      lastFrameMillis = millis();
      framesThisSecond++;
      requestFrame();
      break;
    case WStype_TEXT:
      handleText(payload, length);
      break;
    default:
      break;
  }
}

void sendButton(const char* id) {
  if (!wsConnected) return;
  JsonDocument doc;
  doc["type"] = "button";
  doc["id"] = id;
  sendJson(doc);
}

void startRecording() {
  if (!audio || !wsConnected) return;
  M5.Speaker.end();  // the Core2 speaker and mic share the I2S peripheral
  M5.Mic.begin();
  queuedChunks = 0;
  recording = true;
  setStatus("Listening... release B to ask");
}

void keepRecording() {
  // record() queues at most two blocks; call it again whenever a slot is free.
  while (queuedChunks < kMaxChunks && M5.Mic.isRecording() < 2) {
    if (!M5.Mic.record(&audio[queuedChunks * kChunkSamples], kChunkSamples, kSampleRate)) break;
    queuedChunks++;
  }
}

void finishRecording() {
  recording = false;
  while (M5.Mic.isRecording()) delay(1);
  M5.Mic.end();
  const size_t bytes = queuedChunks * kChunkSamples * sizeof(int16_t);
  if (bytes < kSampleRate / 2 * sizeof(int16_t)) {  // under 0.5 s: treat as an accidental tap
    setStatus("Hold B and speak");
    return;
  }
  ws.sendTXT("{\"type\":\"audio_start\",\"rate\":16000}");
  const uint8_t* data = reinterpret_cast<const uint8_t*>(audio);
  for (size_t offset = 0; offset < bytes; offset += kSendBytes) {
    ws.sendBIN(data + offset, std::min(kSendBytes, bytes - offset));
  }
  ws.sendTXT("{\"type\":\"audio_end\"}");
  setStatus("Thinking...");
}

void closeAnswer() {
  answerVisible = false;
  M5.Display.fillRect(0, 0, videoWidth(), videoHeight(), TFT_BLACK);
  setStatus("");
  if (wsConnected) requestFrame();
}

void connectWiFi() {
  WiFi.mode(WIFI_STA);
  WiFi.setSleep(false);  // modem sleep adds 100+ ms of latency per frame
  WiFi.begin(WIFI_SSID, WIFI_PASSWORD);
  setStatus("Wi-Fi: joining " WIFI_SSID);
  showMessage("Joining Wi-Fi...");
  while (WiFi.status() != WL_CONNECTED) {
    delay(250);
    M5.update();
  }
  setStatus("Wi-Fi: " + WiFi.localIP().toString());
}

}  // namespace

void setup() {
  auto cfg = M5.config();
  M5.begin(cfg);
  M5.Display.setRotation(0);  // portrait 240x320, matches the glasses' tall frames
  M5.Display.fillScreen(TFT_BLACK);
  Serial.begin(115200);

  audio = static_cast<int16_t*>(
      heap_caps_malloc(kMaxChunks * kChunkSamples * sizeof(int16_t), MALLOC_CAP_SPIRAM));
  if (!audio) setStatus("No PSRAM: voice disabled");

  connectWiFi();

  ws.begin(RELAY_HOST, RELAY_PORT, "/core2");
  ws.onEvent(onWebSocket);
  ws.setReconnectInterval(2000);
  ws.enableHeartbeat(15000, 3000, 2);
  showMessage("Connecting to relay...");
}

void loop() {
  M5.update();
  ws.loop();

  // A: describe the view. B (hold): spoken question. C: log meal; hold C: undo last meal.
  if (M5.BtnA.wasClicked()) {
    sendButton("A");
    setStatus("Thinking...");
  }
  if (M5.BtnB.wasPressed()) startRecording();
  if (recording) {
    if (M5.BtnB.isPressed()) {
      keepRecording();
    } else {
      finishRecording();
    }
  }
  if (M5.BtnC.wasClicked()) {
    sendButton("C");
    setStatus("Logging meal...");
  }
  if (M5.BtnC.wasHold()) sendButton("C_HOLD");

  if (answerVisible) {
    auto t = M5.Touch.getDetail();
    if (t.wasClicked() && t.y < videoHeight()) closeAnswer();
  }

  const uint32_t now = millis();
  if (now - lastFpsMillis >= 1000) {
    fps = framesThisSecond;
    framesThisSecond = 0;
    lastFpsMillis = now;
    drawStatus();
  }
  // If frames stall (e.g. a "next" was lost), ask again.
  if (wsConnected && lastFrameMillis && now - lastFrameMillis > 3000) {
    lastFrameMillis = now;
    requestFrame();
  }
}
