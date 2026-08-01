// Ensures the bundle id exists and prints the account's Team ID (seedId).
const crypto = require("crypto"), fs = require("fs"), https = require("https");
const key = fs.readFileSync(process.env.ASC_P8_PATH, "utf8");
const iss = process.env.ASC_ISSUER, kid = process.env.ASC_KEY_ID;
const BUNDLE = process.env.BUNDLE_ID || "com.idoschoenberg.scarlettalk";
const b64u = (x) => Buffer.from(x).toString("base64url");
const now = Math.floor(Date.now() / 1000);
const si = b64u(JSON.stringify({ alg: "ES256", kid, typ: "JWT" })) + "." +
  b64u(JSON.stringify({ iss, iat: now, exp: now + 900, aud: "appstoreconnect-v1" }));
const jwt = si + "." + crypto.sign("sha256", Buffer.from(si), { key, dsaEncoding: "ieee-p1363" }).toString("base64url");
function api(method, path, body) {
  return new Promise((res, rej) => {
    const data = body ? JSON.stringify(body) : null;
    const r = https.request({ host: "api.appstoreconnect.apple.com", path, method,
      headers: { Authorization: "Bearer " + jwt, "Content-Type": "application/json",
        ...(data ? { "Content-Length": Buffer.byteLength(data) } : {}) } },
      (x) => { let d = ""; x.on("data", (c) => d += c); x.on("end", () => res({ s: x.statusCode, b: d })); });
    r.on("error", rej); if (data) r.write(data); r.end();
  });
}
(async () => {
  const g = await api("GET", "/v1/bundleIds?filter[identifier]=" + encodeURIComponent(BUNDLE) + "&limit=1");
  let seed = null;
  try { const j = JSON.parse(g.b); if (j.data && j.data[0]) seed = j.data[0].attributes.seedId; } catch (e) {}
  if (!seed) {
    const c = await api("POST", "/v1/bundleIds",
      { data: { type: "bundleIds", attributes: { identifier: BUNDLE, name: "ScarletTalk", platform: "IOS" } } });
    try { const j = JSON.parse(c.b); seed = j.data && j.data.attributes && j.data.attributes.seedId; } catch (e) {}
    if (!seed) { console.error("bundleId create failed:", c.s, c.b.slice(0, 500)); process.exit(1); }
  }
  process.stdout.write(seed);
})().catch((e) => { console.error(e); process.exit(1); });
