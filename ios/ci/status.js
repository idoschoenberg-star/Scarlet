// Prints TestFlight processing status for the app's recent builds.
const crypto = require("crypto"), fs = require("fs"), https = require("https");
const key = fs.readFileSync(process.env.ASC_P8_PATH, "utf8");
const iss = process.env.ASC_ISSUER, kid = process.env.ASC_KEY_ID;
const BUNDLE = process.env.BUNDLE_ID || "com.idoschoenberg.scarlettalk";
const b64u = (x) => Buffer.from(x).toString("base64url");
const now = Math.floor(Date.now() / 1000);
const si = b64u(JSON.stringify({ alg: "ES256", kid, typ: "JWT" })) + "." +
  b64u(JSON.stringify({ iss, iat: now, exp: now + 900, aud: "appstoreconnect-v1" }));
const jwt = si + "." + crypto.sign("sha256", Buffer.from(si), { key, dsaEncoding: "ieee-p1363" }).toString("base64url");
function api(path) {
  return new Promise((res, rej) => {
    const r = https.request({ host: "api.appstoreconnect.apple.com", path, method: "GET",
      headers: { Authorization: "Bearer " + jwt } },
      (x) => { let d = ""; x.on("data", (c) => d += c); x.on("end", () => res({ s: x.statusCode, b: d })); });
    r.on("error", rej); r.end();
  });
}
(async () => {
  const out = {};
  const a = await api("/v1/apps?filter[bundleId]=" + encodeURIComponent(BUNDLE));
  const app = (JSON.parse(a.b).data || [])[0];
  if (!app) { out.app = "NOT FOUND for " + BUNDLE; console.log("===STATUS===\n" + JSON.stringify(out, null, 2) + "\n===END==="); return; }
  out.app = { id: app.id, name: app.attributes.name, sku: app.attributes.sku };
  const b = await api("/v1/builds?filter[app]=" + app.id + "&sort=-uploadedDate&limit=5");
  out.builds = (JSON.parse(b.b).data || []).map((x) => ({
    id: x.id, version: x.attributes.version,
    processingState: x.attributes.processingState,
    uploadedDate: x.attributes.uploadedDate, expired: x.attributes.expired,
    usesNonExemptEncryption: x.attributes.usesNonExemptEncryption,
  }));
  const g = await api("/v1/betaGroups?filter[app]=" + app.id);
  out.betaGroups = (JSON.parse(g.b).data || []).map((x) => ({
    id: x.id, name: x.attributes.name, isInternalGroup: x.attributes.isInternalGroup,
  }));
  // TestFlight crash feedback (best-effort; needs the tester to have shared it).
  const cr = await api("/v1/apps/" + app.id + "/betaFeedbackCrashSubmissions?limit=5");
  try {
    const j = JSON.parse(cr.b);
    out.crashes = (j.data || []).map((x) => x.attributes);
    if (!j.data) out.crashesRaw = cr.b.slice(0, 800);
  } catch (e) { out.crashesRaw = cr.s + " " + cr.b.slice(0, 300); }
  console.log("===STATUS===\n" + JSON.stringify(out, null, 2) + "\n===END===");
})().catch((e) => { console.error(e); process.exit(1); });
