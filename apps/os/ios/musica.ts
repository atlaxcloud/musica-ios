/**
 * Musica for iOS: an app of its own (cloud.atlax.musica), only the music player.
 * Plain Swift, no Zig, no extensions, no App Group: it shares only the look
 * (Shared/Brand.swift + Shared/Mark.swift) with the Atlax app.
 *
 *   bun apps/os/ios/musica.ts        -> ios/musica.json + ios/build/musica/ent/Musica.entitlements
 *   bun apps/os/ios/musica.ts icon   -> Musica/Assets.xcassets/AppIcon.appiconset/AppIcon.png (committed)
 *   xcodegen generate --spec musica.json && xcodebuild -scheme Musica ...   (CI: .github/workflows/ios.yml)
 *   sh pack.sh musica               -> apps/os/out/ios/Musica-free.ipa (artifact "Musica-ipa")
 *
 * The PC's ios-refresh signs it with the free Apple ID like Atlax (apps.json "Musica", artifact "musica").
 */
import { mkdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { deflateSync } from "node:zlib";
import { plist } from "./project";

const DIR = import.meta.dir;
export const MUSICA = "cloud.atlax.musica";

function info(): Record<string, unknown> {
  return {
    CFBundleDisplayName: "Musica",
    CFBundleShortVersionString: "$(MARKETING_VERSION)",
    CFBundleVersion: "$(CURRENT_PROJECT_VERSION)",
    CFBundleDevelopmentRegion: "it",
    LSRequiresIPhoneOS: true,
    UILaunchScreen: {},
    UIApplicationSceneManifest: { UIApplicationSupportsMultipleScenes: false },
    UIUserInterfaceStyle: "Dark",
    UISupportedInterfaceOrientations: ["UIInterfaceOrientationPortrait"],
    "UISupportedInterfaceOrientations~ipad": ["UIInterfaceOrientationPortrait", "UIInterfaceOrientationLandscapeLeft", "UIInterfaceOrientationLandscapeRight"],
    // Plays with the screen locked; the lock screen and the headphones drive it (MPRemoteCommandCenter).
    UIBackgroundModes: ["audio"],
    ITSAppUsesNonExemptEncryption: false,
  };
}

export function spec() {
  return {
    name: "Musica",
    options: { bundleIdPrefix: "cloud.atlax", deploymentTarget: { iOS: "16.0" } },
    settings: {
      base: {
        SWIFT_VERSION: "5.0",
        TARGETED_DEVICE_FAMILY: "1,2",
        MARKETING_VERSION: "0.1",
        CURRENT_PROJECT_VERSION: process.env.ATX_BUILD ?? "1",
        ENABLE_BITCODE: false,
        CODE_SIGNING_ALLOWED: false, CODE_SIGNING_REQUIRED: false, CODE_SIGN_IDENTITY: "",
        DEAD_CODE_STRIPPING: true,
      },
    },
    targets: {
      Musica: {
        type: "application",
        platform: "iOS",
        sources: ["Musica", "Shared/Brand.swift", "Shared/Mark.swift"],
        info: { path: "build/musica/info/Musica.plist", properties: info() },
        settings: { base: { PRODUCT_BUNDLE_IDENTIFIER: MUSICA, PRODUCT_NAME: "Musica", ASSETCATALOG_COMPILER_APPICON_NAME: "AppIcon" } },
      },
    },
  };
}

/**
 * The icon: the Atlax mark (the master "A a montagna") turned a quarter clockwise,
 * so its apex points right and the A becomes a play button. White on black,
 * 1024 RGB without alpha, supersampled 4x4, nonzero fill like icon.ts.
 */
async function icon() {
  // Loaded only here: the CI mirror carries apps/os/ios alone, without apps/brand.
  const { ATLAX_PATH } = await import("../../brand/atlax-mark");
  const S = 1024, SS = 4, H = 540, DX = 26; // mark length along the play axis; optical nudge right
  type P = [number, number];
  const polys: P[][] = [];
  {
    const tok = ATLAX_PATH.match(/[a-zA-Z]|-?\d*\.?\d+/g)!;
    let i = 0, cmd = "", x = 0, y = 0, sx = 0, sy = 0, cur: P[] = [];
    const num = () => Number(tok[i++]);
    while (i < tok.length) {
      if (/[a-zA-Z]/.test(tok[i])) cmd = tok[i++];
      const rel = cmd === cmd.toLowerCase(), c = cmd.toLowerCase();
      if (c === "z") { if (cur.length) polys.push(cur); cur = []; x = sx; y = sy; continue; }
      if (c === "m") { if (cur.length) polys.push(cur); x = (rel ? x : 0) + num(); y = (rel ? y : 0) + num(); sx = x; sy = y; cur = [[x, y]]; cmd = rel ? "l" : "L"; }
      else if (c === "l") { x = (rel ? x : 0) + num(); y = (rel ? y : 0) + num(); cur.push([x, y]); }
      else if (c === "c") {
        const ox = rel ? x : 0, oy = rel ? y : 0;
        const x1 = ox + num(), y1 = oy + num(), x2 = ox + num(), y2 = oy + num(), x3 = ox + num(), y3 = oy + num();
        for (let k = 1; k <= 24; k++) { const t = k / 24, u = 1 - t; cur.push([u * u * u * x + 3 * u * u * t * x1 + 3 * u * t * t * x2 + t * t * t * x3, u * u * u * y + 3 * u * u * t * y1 + 3 * u * t * t * y2 + t * t * t * y3]); }
        x = x3; y = y3;
      } else throw new Error(`path command ${cmd}`);
    }
    if (cur.length) polys.push(cur);
  }
  // Path units are y-up: path y (apex = max) becomes icon x, path x becomes icon y.
  let x0 = Infinity, y0 = Infinity, x1 = -Infinity, y1 = -Infinity;
  for (const p of polys) for (const [x, y] of p) { x0 = Math.min(x0, x); x1 = Math.max(x1, x); y0 = Math.min(y0, y); y1 = Math.max(y1, y); }
  const k = H / (y1 - y0), ox = (S - H) / 2 + DX, oy = (S - (x1 - x0) * k) / 2;
  const edges: [number, number, number, number, number][] = [];
  for (const p of polys) for (let j = 0; j < p.length; j++) {
    const a = p[j], b = p[(j + 1) % p.length];
    const ax = (ox + (a[1] - y0) * k) * SS, ay = (oy + (a[0] - x0) * k) * SS;
    const bx = (ox + (b[1] - y0) * k) * SS, by = (oy + (b[0] - x0) * k) * SS;
    if (ay === by) continue;
    edges.push(ay < by ? [ax, ay, bx, by, 1] : [bx, by, ax, ay, -1]);
  }
  const acc = new Uint16Array(S * S), BW = S * SS, cov = new Int32Array(BW + 1);
  for (let sy = 0; sy < S * SS; sy++) {
    const fy = sy + 0.5, xs: [number, number][] = [];
    for (const [ax, ay, bx, by, d] of edges) if (fy >= ay && fy < by) xs.push([ax + ((fy - ay) / (by - ay)) * (bx - ax), d]);
    if (!xs.length) continue;
    xs.sort((p, q) => p[0] - q[0]);
    let wind = 0;
    for (let j = 0; j < xs.length - 1; j++) {
      wind += xs[j][1];
      if (wind === 0) continue;
      const a = Math.max(0, Math.round(xs[j][0])), b = Math.min(BW, Math.round(xs[j + 1][0]));
      if (b > a) { cov[a]++; cov[b]--; }
    }
    const row = Math.floor(sy / SS) * S;
    let run = 0;
    for (let x = 0; x < BW; x++) { run += cov[x]; cov[x] = 0; if (run > 0) acc[row + ((x / SS) | 0)]++; }
    cov[BW] = 0;
  }
  const raw = Buffer.alloc(S * (1 + S * 3));
  for (let y = 0; y < S; y++) {
    raw[y * (1 + S * 3)] = 0;
    for (let x = 0; x < S; x++) {
      const n = acc[y * S + x];
      const o = y * (1 + S * 3) + 1 + x * 3;
      raw[o] = raw[o + 1] = raw[o + 2] = Math.round((n * 255) / (SS * SS));
    }
  }
  const CRC = new Int32Array(256).map((_, n) => { let c = n; for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1; return c; });
  const crc = (b: Buffer) => { let c = -1; for (const x of b) c = CRC[(c ^ x) & 0xff] ^ (c >>> 8); return (c ^ -1) >>> 0; };
  const chunk = (tp: string, d: Buffer) => {
    const len = Buffer.alloc(4); len.writeUInt32BE(d.length);
    const td = Buffer.concat([Buffer.from(tp, "latin1"), d]);
    const k = Buffer.alloc(4); k.writeUInt32BE(crc(td));
    return Buffer.concat([len, td, k]);
  };
  const ihdr = Buffer.alloc(13);
  ihdr.writeUInt32BE(S, 0); ihdr.writeUInt32BE(S, 4); ihdr[8] = 8; ihdr[9] = 2;
  const png = Buffer.concat([Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]), chunk("IHDR", ihdr), chunk("IDAT", deflateSync(raw, { level: 9 })), chunk("IEND", Buffer.alloc(0))]);
  writeFileSync(join(DIR, "Musica", "Assets.xcassets", "AppIcon.appiconset", "AppIcon.png"), png);
  console.log(`Musica AppIcon.png ${png.length} bytes`);
}

if (import.meta.main) {
  if (process.argv[2] === "icon") await icon();
  else {
    writeFileSync(join(DIR, "musica.json"), JSON.stringify(spec(), null, 2));
    const ent = join(DIR, "build", "musica", "ent");
    mkdirSync(ent, { recursive: true });
    writeFileSync(join(ent, "Musica.entitlements"), plist({}));
    console.log("musica: Musica");
  }
}
