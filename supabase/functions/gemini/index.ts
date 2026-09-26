// TeachAssist - Gemini proxy
//
// Why this exists: index.html must never contain the Gemini API key.
// The browser sends its Supabase session token, this function checks the
// caller is a real signed-in user, attaches the key from Secrets, and
// forwards the request to Google.
//
// It also owns the model fallback chain that used to live in the browser,
// so a page load makes one round trip instead of up to nine.
//
// Deploy (dashboard):
//   Edge Functions -> Create function -> name it "gemini" -> paste this
//   Settings -> Edge Functions -> Secrets -> add GEMINI_API_KEY
//   Turn OFF "Verify JWT" for this function (see note on requireUser below)

const SUPABASE_URL = Deno.env.get('SUPABASE_URL') ?? '';
const SUPABASE_ANON_KEY = Deno.env.get('SUPABASE_ANON_KEY') ?? '';
const GEMINI_API_KEY = Deno.env.get('GEMINI_API_KEY') ?? '';

// Mirrors the constants in index.html. The budget deliberately sits below
// BOTH the browser's 30s per-attempt timeout and the 150s Edge Function
// wall-clock limit on the free plan - if it did not, the client would abort
// first and neither side would know how far the other got.
const PRIMARY_MODEL = 'gemini-3.6-flash';
const FALLBACK_MODELS = ['gemini-3.5-flash', 'gemini-3.5-flash-lite'];
const TOTAL_BUDGET_MS = 24000;
const ATTEMPTS_PER_MODEL = 3;
const BACKOFF_MS = [700, 1500, 3000];
const RETRYABLE = [429, 500, 502, 503, 504];
const PER_ATTEMPT_TIMEOUT_MS = 18000;

// The app is opened straight from disk, so the Origin header is literally
// "null". Echo the caller rather than pinning a domain - there is no cookie
// involved, so nothing is at risk.
const CORS: Record<string, string> = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...CORS, 'Content-Type': 'application/json' },
  });
}

const sleep = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms));

// verify-jwt is switched OFF for this function so the browser's OPTIONS
// preflight actually reaches the handler below (the gateway would otherwise
// answer it with a 401 and the browser would never send the real request).
// The key is still protected: nothing is forwarded until this resolves.
async function requireUser(req: Request): Promise<Record<string, unknown> | null> {
  const header = req.headers.get('Authorization') ?? '';
  const token = header.replace(/^Bearer\s+/i, '').trim();
  if (!token || !SUPABASE_URL || !SUPABASE_ANON_KEY) return null;

  try {
    const res = await fetch(`${SUPABASE_URL}/auth/v1/user`, {
      headers: { apikey: SUPABASE_ANON_KEY, Authorization: `Bearer ${token}` },
    });
    if (!res.ok) return null;
    return await res.json();
  } catch {
    return null;
  }
}

interface AttemptResult {
  ok: boolean;
  status: number;
  body: unknown;
}

async function callGoogle(
  model: string,
  payload: Record<string, unknown>,
  deadline: number,
): Promise<AttemptResult> {
  const controller = new AbortController();
  const remaining = Math.max(1000, deadline - Date.now());
  const timer = setTimeout(() => controller.abort(), Math.min(PER_ATTEMPT_TIMEOUT_MS, remaining));

  try {
    const res = await fetch(
      `https://generativelanguage.googleapis.com/v1beta/models/${encodeURIComponent(model)}:generateContent`,
      {
        method: 'POST',
        headers: { 'Content-Type': 'application/json', 'x-goog-api-key': GEMINI_API_KEY },
        body: JSON.stringify({
          // `model` is ours, not Google's - never forward it.
          system_instruction: payload.system_instruction,
          contents: payload.contents,
          generationConfig: payload.generationConfig,
        }),
        signal: controller.signal,
      },
    );

    const text = await res.text();
    let parsed: unknown;
    try { parsed = JSON.parse(text); } catch { parsed = { error: { message: text.slice(0, 400) } }; }
    return { ok: res.ok, status: res.status, body: parsed };
  } catch (err) {
    const aborted = err instanceof Error && err.name === 'AbortError';
    return {
      ok: false,
      status: aborted ? 504 : 502,
      body: { error: { message: aborted ? 'The model timed out.' : 'Could not reach the model.' } },
    };
  } finally {
    clearTimeout(timer);
  }
}

Deno.serve(async (req) => {
  // Preflight: answer before anything else, with no auth involved.
  if (req.method === 'OPTIONS') return new Response('ok', { headers: CORS });
  if (req.method !== 'POST') return json({ error: { message: 'Use POST.' } }, 405);

  const user = await requireUser(req);
  if (!user) return json({ message: 'Sign in to use the coach.' }, 401);

  if (!GEMINI_API_KEY) {
    return json({
      error: {
        message:
          'GEMINI_API_KEY is not set. Add it under Settings -> Edge Functions -> Secrets.',
      },
    }, 500);
  }

  let payload: Record<string, unknown>;
  try {
    payload = await req.json();
  } catch {
    return json({ error: { message: 'Request body must be JSON.' } }, 400);
  }

  // One model is enough when the client asks for it, but always keep the
  // fallback chain in reserve - a 503 on the primary should degrade, not fail.
  const requested = typeof payload.model === 'string' ? payload.model.trim() : '';
  const queue: string[] = [];
  const push = (m: string) => { if (m && !queue.includes(m)) queue.push(m); };
  if (requested && requested !== PRIMARY_MODEL) push(requested);
  push(PRIMARY_MODEL);
  FALLBACK_MODELS.forEach(push);

  const deadline = Date.now() + TOTAL_BUDGET_MS;
  let last: AttemptResult | null = null;

  for (const model of queue) {
    for (let attempt = 0; attempt < ATTEMPTS_PER_MODEL; attempt++) {
      if (attempt > 0) {
        const wait = BACKOFF_MS[attempt - 1] ?? 3000;
        if (Date.now() + wait >= deadline) break;
        await sleep(wait);
      }
      if (Date.now() >= deadline) break;

      const result = await callGoogle(model, payload, deadline);

      if (result.ok) return json(result.body);

      // Google rejecting the SERVER key must not look like the browser's
      // session expiring - index.html maps 401/403 to "sign in again".
      if (result.status === 401 || result.status === 403) {
        return json({
          error: { message: 'The server could not authenticate with the AI provider. Check the GEMINI_API_KEY secret.' },
        }, 502);
      }

      last = result;
      if (!RETRYABLE.includes(result.status)) return json(result.body, result.status);
    }
    if (Date.now() >= deadline) break;
  }

  if (last) return json(last.body, last.status);
  return json({ error: { message: 'The coach ran out of time. Try again in a moment.' } }, 504);
});
