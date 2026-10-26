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

/** The icon: a white beamed pair of notes on black, 1024 RGB without alpha (supersampled 4x4). */
function icon() {
  const S = 1024, SS = 4, dx = -28, dy = 8;
  const t = (25 * Math.PI) / 180, c = Math.cos(t), s = Math.sin(t);
  const head = (x: number, y: number, cx: number, cy: number) => {
    const u = (x - cx) * c - (y - cy) * s, v = (x - cx) * s + (y - cy) * c;
    return (u / 96) ** 2 + (v / 70) ** 2 <= 1;
  };
  const inside = (x: number, y: number) => {
    x -= dx; y -= dy;
    if (head(x, y, 380, 700) || head(x, y, 700, 640)) return true;
    if (x >= 440 && x <= 476 && y >= 300 && y <= 700) return true;
    if (x >= 760 && x <= 796 && y >= 240 && y <= 640) return true;
    if (x >= 440 && x <= 796) { const top = 300 - ((x - 440) / 356) * 60; return y >= top && y <= top + 92; }
    return false;
  };
  const raw = Buffer.alloc(S * (1 + S * 3));
  for (let y = 0; y < S; y++) {
    raw[y * (1 + S * 3)] = 0;
    for (let x = 0; x < S; x++) {
      let n = 0;
      for (let i = 0; i < SS; i++) for (let j = 0; j < SS; j++) if (inside(x + (i + 0.5) / SS, y + (j + 0.5) / SS)) n++;
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
  if (process.argv[2] === "icon") icon();
  else {
    writeFileSync(join(DIR, "musica.json"), JSON.stringify(spec(), null, 2));
    const ent = join(DIR, "build", "musica", "ent");
    mkdirSync(ent, { recursive: true });
    writeFileSync(join(ent, "Musica.entitlements"), plist({}));
    console.log("musica: Musica");
  }
}
