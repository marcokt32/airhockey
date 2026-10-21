// Worker que gera credenciais TURN temporárias da Cloudflare para o jogo.
// O token da Cloudflare fica só aqui (secret); o app manda o token do Firebase
// (login anônimo) e o Worker confere antes de gerar.
//
// Secrets (wrangler secret put ...):
//   TURN_KEY_ID         -> "TURN Key ID" (Cloudflare > Realtime > TURN)
//   TURN_KEY_API_TOKEN  -> "API Token" dessa mesma chave

const PROJECT_ID = "airhockey-ae632"; // mesmo projeto do DB_URL do firebase.gd
const JWKS_URL = "https://www.googleapis.com/service_accounts/v1/jwk/securetoken@system.gserviceaccount.com";
const MIN_TTL = 600;
const MAX_TTL = 86400;

const b64uToBytes = (s) =>
  Uint8Array.from(atob(s.replace(/-/g, "+").replace(/_/g, "/")), (c) => c.charCodeAt(0));
const b64uToJson = (s) => JSON.parse(new TextDecoder().decode(b64uToBytes(s)));

// Confere assinatura (RS256), emissor, projeto e validade do ID token do Firebase.
async function verifyFirebaseToken(token) {
  const parts = token.split(".");
  if (parts.length !== 3) return null;
  let header, payload;
  try {
    header = b64uToJson(parts[0]);
    payload = b64uToJson(parts[1]);
  } catch {
    return null;
  }
  const now = Math.floor(Date.now() / 1000);
  if (header.alg !== "RS256" || !header.kid) return null;
  if (payload.aud !== PROJECT_ID) return null;
  if (payload.iss !== `https://securetoken.google.com/${PROJECT_ID}`) return null;
  if (!payload.sub || !payload.exp || payload.exp < now) return null;

  const jwks = await fetch(JWKS_URL, { cf: { cacheTtl: 3600, cacheEverything: true } }).then((r) => r.json());
  const jwk = jwks.keys.find((k) => k.kid === header.kid);
  if (!jwk) return null;
  const key = await crypto.subtle.importKey(
    "jwk", jwk, { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" }, false, ["verify"]);
  const ok = await crypto.subtle.verify(
    "RSASSA-PKCS1-v1_5", key, b64uToBytes(parts[2]),
    new TextEncoder().encode(parts[0] + "." + parts[1]));
  return ok ? payload : null;
}

const json = (obj, status = 200) =>
  new Response(JSON.stringify(obj), { status, headers: { "Content-Type": "application/json" } });

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    if (request.method !== "POST" || url.pathname !== "/ice") return json({ error: "not found" }, 404);

    const auth = request.headers.get("Authorization") || "";
    const token = auth.startsWith("Bearer ") ? auth.slice(7) : "";
    if (!token || !(await verifyFirebaseToken(token))) return json({ error: "unauthorized" }, 401);

    let ttl = MAX_TTL;
    try {
      const body = await request.json();
      if (Number.isFinite(body.ttl)) ttl = Math.min(MAX_TTL, Math.max(MIN_TTL, Math.floor(body.ttl)));
    } catch { /* corpo vazio: usa o padrão */ }

    const cf = await fetch(
      `https://rtc.live.cloudflare.com/v1/turn/keys/${env.TURN_KEY_ID}/credentials/generate-ice-servers`,
      {
        method: "POST",
        headers: {
          Authorization: `Bearer ${env.TURN_KEY_API_TOKEN}`,
          "Content-Type": "application/json",
        },
        body: JSON.stringify({ ttl }),
      });
    if (!cf.ok) return json({ error: "cloudflare", status: cf.status }, 502);
    return json(await cf.json());
  },
};
