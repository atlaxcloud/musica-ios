#!/bin/sh
# pack.sh <free|paid|musica>: the unsigned Release build -> apps/os/out/ios/Atlax-<p>.ipa
# (musica: the Musica app, musica.ts -> Musica-free.ipa).
# Ad-hoc signs every bundle (extensions first) with that profile's entitlements
# (build/<p>/ent, from project.ts / musica.ts) so the signer that installs it
# (~/tools/ios-refresh, plumesign + Apple ID) sees what each target asks for.
set -eu
p=$1
cd "$(dirname "$0")"
name=Atlax; out=Atlax-$p
if [ "$p" = musica ]; then name=Musica; out=Musica-free; fi
app=build/$p/Release-iphoneos/$name.app
test -d "$app"
for ex in "$app"/PlugIns/*.appex; do
  [ -d "$ex" ] || continue
  n=$(basename "$ex" .appex)
  codesign --force --sign - --timestamp=none --entitlements "build/$p/ent/$n.entitlements" "$ex"
done
codesign --force --sign - --timestamp=none --entitlements "build/$p/ent/$name.entitlements" "$app"
echo "== $p: bundles and entitlements"
for b in "$app" "$app"/PlugIns/*.appex; do
  [ -d "$b" ] || continue
  echo "-- $(basename "$b")"
  codesign -d --entitlements - --xml "$b" 2>/dev/null | plutil -convert xml1 -o - - | grep -E '<key>|<string>' || true
done
rm -rf "build/$p/ipa"
mkdir -p "build/$p/ipa/Payload" ../out/ios
cp -R "$app" "build/$p/ipa/Payload/"
rm -f "../out/ios/$out.ipa"
(cd "build/$p/ipa" && zip -qry "../../../../out/ios/$out.ipa" Payload)
ls -la "../out/ios/$out.ipa"
