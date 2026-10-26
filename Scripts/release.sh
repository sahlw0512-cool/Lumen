#!/bin/zsh
# Builds Lumen and packages it as a DMG you can attach to a GitHub release.
#
#   Scripts/release.sh            build the current version
#   Scripts/release.sh 1.1.0      set the version to 1.1.0 first (bumps the build number too)
#
# Output: dist/Lumen-<version>.dmg
set -euo pipefail
cd "${0:A:h}/.."

project=Lumen.xcodeproj/project.pbxproj

if [[ $# -ge 1 ]]; then
  new_version=$1
  if [[ ! $new_version =~ '^[0-9]+(\.[0-9]+){1,2}$' ]]; then
    echo "Version must look like 1.2 or 1.2.3" >&2
    exit 1
  fi
  build=$(( $(grep -m1 -o 'CURRENT_PROJECT_VERSION = [0-9]*' $project | grep -o '[0-9]*$') + 1 ))
  sed -i '' -E "s/MARKETING_VERSION = [^;]+;/MARKETING_VERSION = $new_version;/; s/CURRENT_PROJECT_VERSION = [0-9]+;/CURRENT_PROJECT_VERSION = $build;/" $project
  sed -i '' -E "s/MARKETING_VERSION: \"[^\"]+\"/MARKETING_VERSION: \"$new_version\"/; s/CURRENT_PROJECT_VERSION: \"[0-9]+\"/CURRENT_PROJECT_VERSION: \"$build\"/" project.yml
  echo "Version set to $new_version (build $build)"
fi

version=$(grep -m1 -o 'MARKETING_VERSION = [^;]*' $project | sed 's/.*= //')
derived=build/DerivedData
stage=build/dmg
dmg=dist/Lumen-$version.dmg

echo "Building Lumen $version…"
xcodebuild -project Lumen.xcodeproj -scheme Lumen -configuration Release \
  -derivedDataPath $derived CODE_SIGN_IDENTITY=- clean build | grep -E 'error:|BUILD' || true

app=$derived/Build/Products/Release/Lumen.app
if [[ ! -d $app ]]; then
  echo "Build failed; run the xcodebuild command above without the grep to see why." >&2
  exit 1
fi
codesign --verify --deep --strict $app

echo "Packaging…"
rm -rf $stage && mkdir -p $stage dist
ditto $app $stage/Lumen.app
ln -s /Applications $stage/Applications
rm -f $dmg
hdiutil create -volname "Lumen $version" -srcfolder $stage -fs HFS+ -format UDZO -ov $dmg >/dev/null
rm -rf $stage

echo
echo "Done: $dmg ($(du -h $dmg | cut -f1))"
echo "Publish it: on GitHub open Releases › Draft a new release, use the tag v$version, and attach the DMG."
