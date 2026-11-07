import { test } from "node:test";
import assert from "node:assert/strict";
import { validate, POST, tooMany } from "./api/speak.js";

const good = () => ({
  model: "gemini-3.8-flash-lite-tts",
  input: [{ type: "user_input", content: [{ type: "text", text: "覚えておきたいことを、話してください。",
    annotations: [{ type: "speech_metadata", style: "calm" }] }] }],
  response_format: { type: "audio" },
  generation_config: { speech_config: [{ voice: "Sulafat" }] },
  stream: true,
});

test("accepts the app's request and rebuilds it", () => {
  const out = validate(good());
  assert.equal(out.model, "gemini-3.8-flash-lite-tts");
  assert.equal(out.input[0].content[0].text, "覚えておきたいことを、話してください。");
  assert.equal(out.stream, true);
});

test("rejects other models, voices, empty or long text", () => {
  for (const change of [
    (b) => { b.model = "gemini-3-pro"; },
    (b) => { b.generation_config.speech_config[0].voice = "Other"; },
    (b) => { b.input[0].content[0].text = ""; },
    (b) => { b.input[0].content[0].text = "あ".repeat(401); },
  ]) {
    const b = good(); change(b);
    assert.equal(validate(b), null);
  }
});

test("drops fields the app does not send", () => {
  const b = good(); b.tools = [{ evil: true }];
  assert.equal(validate(b).tools, undefined);
});

test("answers 503 without a key and never calls Google", async () => {
  delete process.env.GEMINI_API_KEY;
  const res = await POST(new Request("https://x/api/speak", { method: "POST", body: JSON.stringify(good()) }));
  assert.equal(res.status, 503);
});

test("forwards to Google with the server key only", async () => {
  process.env.GEMINI_API_KEY = "test-key";
  let seen;
  globalThis.fetch = async (url, init) => { seen = { url, init }; return new Response("data: {}\n", { status: 200, headers: { "content-type": "text/event-stream" } }); };
  const res = await POST(new Request("https://x/api/speak", { method: "POST", body: JSON.stringify(good()) }));
  assert.equal(res.status, 200);
  assert.equal(seen.init.headers["x-goog-api-key"], "test-key");
  assert.match(seen.url, /generativelanguage\.googleapis\.com/);
});

test("limits one caller to 20 an hour and everyone to 60 an hour", () => {
  const t = Date.UTC(2030, 0, 1, 5);
  for (let i = 0; i < 20; i++) assert.equal(tooMany("a", t), false);
  assert.equal(tooMany("a", t), true);
  for (let i = 0; i < 40; i++) assert.equal(tooMany(`b${i}`, t), false);
  assert.equal(tooMany("c", t), true);
  assert.equal(tooMany("c", t + 3_600_000), false);
});
