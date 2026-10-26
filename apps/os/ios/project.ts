/**
 * Atlax for iOS: the Xcode project, as an XcodeGen spec, for one of two profiles.
 *
 *   bun apps/os/ios/project.ts free   -> ios/project.json + ios/build/free/ent/*.entitlements
 *   bun apps/os/ios/project.ts paid   -> same, paid
 *   xcodegen generate --spec project.json   (CI: .github/workflows/ios.yml)
 *
 * free: what a free Apple ID can sign (the PC's sideload tool installs it over USB).
 * paid: everything, for a Developer account / TestFlight.
 *
 * Env (CI): ATX_BUILD = CFBundleVersion (the workflow's run number, so every
 * build is newer than the last); ATX_SIGN=1 + ATX_TEAM = signed for real with
 * Xcode's automatic signing (TestFlight), instead of unsigned for pack.sh.
 * Both share the Info.plist (usage strings, background modes: plist keys, not
 * entitlements) and the App Group every target talks through.
 */
import { mkdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";

const DIR = import.meta.dir;
export const GROUP = "group.cloud.atlax";
export const BUNDLE = "cloud.atlax.app";
const SIGN = process.env.ATX_SIGN === "1";
const TEAM = process.env.ATX_TEAM ?? "";

type Profile = "free" | "paid";

/** Targets: name, bundle suffix, sources, NSExtension, which profiles carry it. */
const EXTENSIONS = [
  {
    name: "AtlaxBroadcast", suffix: "broadcast", src: "Broadcast", profiles: ["free", "paid"],
    ext: { NSExtensionPointIdentifier: "com.apple.broadcast-services-upload", NSExtensionPrincipalClass: "$(PRODUCT_MODULE_NAME).SampleHandler", RPBroadcastProcessMode: "RPBroadcastProcessModeSampleBuffer" },
  },
  {
    name: "AtlaxShare", suffix: "share", src: "Share", profiles: ["free", "paid"],
    ext: {
      NSExtensionPointIdentifier: "com.apple.share-services", NSExtensionPrincipalClass: "$(PRODUCT_MODULE_NAME).ShareViewController",
      NSExtensionAttributes: { NSExtensionActivationRule: { NSExtensionActivationSupportsFileWithMaxCount: 20, NSExtensionActivationSupportsImageWithMaxCount: 20, NSExtensionActivationSupportsMovieWithMaxCount: 5, NSExtensionActivationSupportsWebURLWithMaxCount: 1, NSExtensionActivationSupportsText: true } },
    },
  },
  {
    // A File Provider lives on the App Group, which a free Apple ID can't
    // register (Apple error 35), and it would be one more App ID out of 10/week.
    name: "AtlaxFiles", suffix: "files", src: "Files", profiles: ["paid"],
    ext: { NSExtensionPointIdentifier: "com.apple.fileprovider-nonui", NSExtensionPrincipalClass: "$(PRODUCT_MODULE_NAME).FileProviderExtension", NSExtensionFileProviderSupportsEnumeration: true, NSExtensionFileProviderDocumentGroup: GROUP },
  },
  {
    name: "AtlaxWidget", suffix: "widget", src: "Widget", profiles: ["free", "paid"],
    ext: { NSExtensionPointIdentifier: "com.apple.widgetkit-extension" },
  },
  {
    // The AutoFill entitlement is Developer-account only: a free signature that
    // carries it fails to install, so the free IPA leaves the target out.
    name: "AtlaxAutoFill", suffix: "autofill", src: "AutoFill", profiles: ["paid"],
    ext: {
      NSExtensionPointIdentifier: "com.apple.authentication-services-credential-provider-ui", NSExtensionPrincipalClass: "$(PRODUCT_MODULE_NAME).CredentialProviderViewController",
      NSExtensionAttributes: { ASCredentialProviderExtensionShowsConfigurationUI: false, ASCredentialProviderExtensionCapabilities: { ProvidesPasswords: true } },
    },
  },
] as const;

/** Entitlements per target and profile (written next to the build, applied by pack.sh). */
export function entitlements(p: Profile, target: string): Record<string, unknown> {
  // Free Apple ID: no App Group (plumesign can't register it), each target keeps its own container.
  const e: Record<string, unknown> = p === "paid" ? { "com.apple.security.application-groups": [GROUP] } : {};
  if (p === "paid" && target === "Atlax") {
    e["aps-environment"] = SIGN ? "production" : "development";
    e["com.apple.developer.usernotifications.time-sensitive"] = true;
    e["com.apple.developer.nfc.readersession.formats"] = ["TAG", "NDEF"];
  }
  if (p === "paid" && target === "AtlaxAutoFill") e["com.apple.developer.authentication-services.autofill-credential-provider"] = true;
  return e;
}

const USAGE = {
  NSCameraUsageDescription: "Atlax usa la fotocamera per scansionare i QR di abbinamento e per le videochiamate.",
  NSMicrophoneUsageDescription: "Atlax usa il microfono per chiamate, note vocali e comandi vocali.",
  NSPhotoLibraryUsageDescription: "Atlax legge le foto che scegli di inviare alle tue macchine Atlax.",
  NSPhotoLibraryAddUsageDescription: "Atlax salva nelle Foto le immagini e le registrazioni che ricevi.",
  NSLocationWhenInUseUsageDescription: "Atlax usa la posizione per capire se sei a casa (rete locale) o fuori (hub).",
  NSLocationAlwaysAndWhenInUseUsageDescription: "Atlax usa la posizione anche in background per automazioni e per tenere vivo il collegamento quando cambi rete.",
  NSContactsUsageDescription: "Atlax sincronizza i contatti con il tuo spazio Atlax.",
  NSCalendarsFullAccessUsageDescription: "Atlax sincronizza i calendari con Atlax Calendar.",
  NSCalendarsUsageDescription: "Atlax sincronizza i calendari con Atlax Calendar.",
  NSRemindersFullAccessUsageDescription: "Atlax sincronizza i promemoria con le tue liste Atlax.",
  NSRemindersUsageDescription: "Atlax sincronizza i promemoria con le tue liste Atlax.",
  NSBluetoothAlwaysUsageDescription: "Atlax usa il Bluetooth per trovare e collegare dispositivi vicini.",
  NSBluetoothPeripheralUsageDescription: "Atlax usa il Bluetooth per farsi trovare dalle tue macchine Atlax.",
  NSLocalNetworkUsageDescription: "Atlax cerca le tue macchine Atlax nella rete locale per lo schermo, i file e la musica.",
  NSMotionUsageDescription: "Atlax usa i sensori di movimento per automazioni e attività.",
  NSSpeechRecognitionUsageDescription: "Atlax trascrive la voce per i comandi e le note vocali.",
  NSFaceIDUsageDescription: "Atlax usa Face ID per sbloccare password e dati protetti.",
  NFCReaderUsageDescription: "Atlax legge tag NFC per abbinamenti e automazioni.",
};

function appInfo(): Record<string, unknown> {
  return {
    CFBundleDisplayName: "Atlax",
    CFBundleShortVersionString: "$(MARKETING_VERSION)",
    CFBundleVersion: "$(CURRENT_PROJECT_VERSION)",
    LSRequiresIPhoneOS: true,
    UILaunchScreen: {},
    UIApplicationSceneManifest: { UIApplicationSupportsMultipleScenes: false },
    UIRequiresFullScreen: true,
    UIStatusBarHidden: false,
    UIUserInterfaceStyle: "Dark",
    // Long press on the icon (Router.go handles the type after "cloud.atlax.").
    UIApplicationShortcutItems: [
      { UIApplicationShortcutItemType: "cloud.atlax.screen", UIApplicationShortcutItemTitle: "Trasmetti schermo", UIApplicationShortcutItemIconSymbolName: "dot.radiowaves.left.and.right" },
      { UIApplicationShortcutItemType: "cloud.atlax.desktop", UIApplicationShortcutItemTitle: "Apri desktop", UIApplicationShortcutItemIconSymbolName: "desktopcomputer" },
      { UIApplicationShortcutItemType: "cloud.atlax.chat", UIApplicationShortcutItemTitle: "Chiedi all'agente", UIApplicationShortcutItemIconSymbolName: "sparkles" },
      { UIApplicationShortcutItemType: "cloud.atlax.mail", UIApplicationShortcutItemTitle: "Posta", UIApplicationShortcutItemIconSymbolName: "envelope" },
      { UIApplicationShortcutItemType: "cloud.atlax.agenda", UIApplicationShortcutItemTitle: "Calendario", UIApplicationShortcutItemIconSymbolName: "calendar" },
    ],
    UISupportedInterfaceOrientations: ["UIInterfaceOrientationPortrait", "UIInterfaceOrientationLandscapeLeft", "UIInterfaceOrientationLandscapeRight"],
    "UISupportedInterfaceOrientations~ipad": ["UIInterfaceOrientationPortrait", "UIInterfaceOrientationPortraitUpsideDown", "UIInterfaceOrientationLandscapeLeft", "UIInterfaceOrientationLandscapeRight"],
    CFBundleURLTypes: [{ CFBundleURLName: "cloud.atlax.pair", CFBundleURLSchemes: ["atlax-screen", "atlax"] }],
    NSBonjourServices: ["_atlax._tcp"],
    CFBundleDevelopmentRegion: "it",
    LSApplicationQueriesSchemes: ["comgooglemaps", "comgooglemaps-x-callback"],
    UIBackgroundModes: ["audio", "location", "fetch", "processing", "remote-notification", "bluetooth-central", "bluetooth-peripheral", "voip"],
    NSSupportsLiveActivities: true,
    NSSupportsLiveActivitiesFrequentUpdates: true,
    BGTaskSchedulerPermittedIdentifiers: ["cloud.atlax.app.refresh", "cloud.atlax.app.processing"],
    UIFileSharingEnabled: true,
    LSSupportsOpeningDocumentsInPlace: true,
    ITSAppUsesNonExemptEncryption: false,
    ...USAGE,
  };
}

export function spec(p: Profile) {
  const exts = EXTENSIONS.filter((e) => (e.profiles as readonly string[]).includes(p));
  const targets: Record<string, unknown> = {
    Atlax: {
      type: "application",
      platform: "iOS",
      sources: ["App", "Shared"],
      info: { path: `build/${p}/info/Atlax.plist`, properties: appInfo() },
      dependencies: exts.map((e) => ({ target: e.name })),
      settings: {
        base: {
          ...entitlementsFile(p, "Atlax"),
          PRODUCT_BUNDLE_IDENTIFIER: BUNDLE,
          PRODUCT_NAME: "Atlax",
          SWIFT_OBJC_BRIDGING_HEADER: "App/Bridging.h",
          HEADER_SEARCH_PATHS: "$(SRCROOT)/../out/ios",
          LIBRARY_SEARCH_PATHS: "$(SRCROOT)/../out/ios",
          OTHER_LDFLAGS: "-latlax",
          // App/Assets.xcassets (icon.py draws it); actool writes CFBundleIcons.
          ASSETCATALOG_COMPILER_APPICON_NAME: "AppIcon",
        },
      },
    },
  };
  for (const e of exts) {
    targets[e.name] = {
      type: "app-extension",
      platform: "iOS",
      sources: [e.src, "Shared"],
      info: { path: `build/${p}/info/${e.name}.plist`, properties: { CFBundleDisplayName: "Atlax", CFBundleShortVersionString: "$(MARKETING_VERSION)", CFBundleVersion: "$(CURRENT_PROJECT_VERSION)", NSExtension: e.ext } },
      settings: { base: { ...entitlementsFile(p, e.name), PRODUCT_BUNDLE_IDENTIFIER: `${BUNDLE}.${e.suffix}`, PRODUCT_NAME: e.name, APPLICATION_EXTENSION_API_ONLY: true } },
    };
  }
  return {
    name: "Atlax",
    options: { bundleIdPrefix: "cloud.atlax", deploymentTarget: { iOS: "16.0" } },
    settings: {
      base: {
        SWIFT_VERSION: "5.0",
        TARGETED_DEVICE_FAMILY: "1,2",
        MARKETING_VERSION: "0.1",
        CURRENT_PROJECT_VERSION: process.env.ATX_BUILD ?? "1",
        ENABLE_BITCODE: false,
        ...(SIGN
          ? { CODE_SIGN_STYLE: "Automatic", DEVELOPMENT_TEAM: TEAM }
          : { CODE_SIGNING_ALLOWED: false, CODE_SIGNING_REQUIRED: false, CODE_SIGN_IDENTITY: "" }),
        DEAD_CODE_STRIPPING: true,
      },
    },
    targets,
  };
}

if (import.meta.main) {
  const p = process.argv[2] as Profile;
  if (p !== "free" && p !== "paid") throw new Error("usage: bun project.ts free|paid");
  const s = spec(p);
  writeFileSync(join(DIR, "project.json"), JSON.stringify(s, null, 2));
  const ent = join(DIR, "build", p, "ent");
  mkdirSync(ent, { recursive: true });
  for (const t of Object.keys(s.targets)) writeFileSync(join(ent, `${t}.entitlements`), plist(entitlements(p, t)));
  console.log(`ios ${p}: ${Object.keys(s.targets).join(", ")}`);
}

/** Signed builds: Xcode signs each target with its entitlements (unsigned ones get them from pack.sh). */
function entitlementsFile(p: Profile, target: string): Record<string, string> {
  return SIGN ? { CODE_SIGN_ENTITLEMENTS: `build/${p}/ent/${target}.entitlements` } : {};
}

/** A small XML plist writer (strings, booleans, arrays of strings). */
export function plist(o: Record<string, unknown>): string {
  const v = (x: unknown): string =>
    typeof x === "boolean" ? (x ? "<true/>" : "<false/>")
    : Array.isArray(x) ? `<array>${x.map(v).join("")}</array>`
    : `<string>${String(x).replace(/&/g, "&amp;").replace(/</g, "&lt;")}</string>`;
  const body = Object.entries(o).map(([k, x]) => `\t<key>${k}</key>\n\t${v(x)}`).join("\n");
  return `<?xml version="1.0" encoding="UTF-8"?>\n<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n<plist version="1.0">\n<dict>\n${body}\n</dict>\n</plist>\n`;
}
