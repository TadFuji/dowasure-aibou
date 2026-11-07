// ど忘れ相棒の「声の中継所」。
// アプリから読み上げる一文を受け取り、Gemini の音声合成に取り次いで、音をそのまま返す。
// Google のキーはこのサーバーの環境変数 GEMINI_API_KEY にだけ置く（アプリにもリポジトリにも入れない）。
// 文の中身は保存しない・記録に書かない。

const GEMINI_ENDPOINT = "https://generativelanguage.googleapis.com/v1beta/interactions";
const MODELS = new Set(["gemini-3.8-flash-lite-tts", "gemini-3.8-flash-tts"]);
const VOICES = new Set(["Sulafat", "Vindemiatrix", "Achernar"]);
const MAX_TEXT = 400;   // アプリが読み上げる一文は長くても200文字ほど
const MAX_STYLE = 300;
// 1台のサーバーの中だけで数える、ゆるい上限（悪用で藤川さんの枠を使い切られにくくする）。
const PER_IP_PER_HOUR = 120;
const counts = new Map();

function tooMany(ip) {
  const hour = Math.floor(Date.now() / 3_600_000);
  const key = `${ip}|${hour}`;
  const n = (counts.get(key) ?? 0) + 1;
  counts.set(key, n);
  if (counts.size > 5000) counts.clear();
  return n > PER_IP_PER_HOUR;
}

function reply(status, message) {
  return new Response(JSON.stringify({ error: message }), {
    status,
    headers: { "content-type": "application/json" },
  });
}

// アプリが送る形（Gemini の interactions と同じ形）を確かめ、決まった形だけを組み立て直して送る。
export function validate(body) {
  if (!body || typeof body !== "object") return null;
  const { model, stream } = body;
  const part = body.input?.[0]?.content?.[0];
  const text = part?.text;
  const style = part?.annotations?.[0]?.style ?? "";
  const voice = body.generation_config?.speech_config?.[0]?.voice;
  if (!MODELS.has(model) || !VOICES.has(voice)) return null;
  if (typeof text !== "string" || text.length === 0 || text.length > MAX_TEXT) return null;
  if (typeof style !== "string" || style.length > MAX_STYLE) return null;
  const annotation = { type: "speech_metadata" };
  if (style) annotation.style = style;
  return {
    model,
    input: [{ type: "user_input", content: [{ type: "text", text, annotations: [annotation] }] }],
    response_format: { type: "audio" },
    generation_config: { speech_config: [{ voice }] },
    stream: stream === true,
  };
}

export async function POST(request) {
  const key = process.env.GEMINI_API_KEY;
  if (!key) return reply(503, "relay not configured");
  const ip = (request.headers.get("x-forwarded-for") ?? "").split(",")[0].trim() || "unknown";
  if (tooMany(ip)) return reply(429, "too many requests");

  let body;
  try {
    body = await request.json();
  } catch {
    return reply(400, "bad json");
  }
  const clean = validate(body);
  if (!clean) return reply(400, "not allowed");

  const upstream = await fetch(GEMINI_ENDPOINT, {
    method: "POST",
    headers: { "content-type": "application/json", "x-goog-api-key": key },
    body: JSON.stringify(clean),
  });
  // 上限（429）などの状態はそのままアプリへ返す。アプリは予備のモデルか iPhone の声に切り替える。
  return new Response(upstream.body, {
    status: upstream.status,
    headers: {
      "content-type": upstream.headers.get("content-type") ?? "application/json",
      "cache-control": "no-store",
    },
  });
}

export function GET() {
  return new Response("ok", { headers: { "content-type": "text/plain" } });
}
