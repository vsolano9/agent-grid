#!/bin/zsh

set -euo pipefail

if (( $# != 1 )); then
  print -u2 'Usage: verify-app-icon.sh <AgentGrid.app>'
  exit 64
fi

app_path=$1
info_plist="$app_path/Contents/Info.plist"

if [[ ! -f $info_plist ]]; then
  print -u2 "Missing app Info.plist: $info_plist"
  exit 65
fi

if ! icon_name=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIconFile' "$info_plist" 2>/dev/null); then
  print -u2 'Missing CFBundleIconFile in the built app.'
  exit 66
fi

icon_name=${icon_name%.icns}.icns
icon_path="$app_path/Contents/Resources/$icon_name"
if [[ ! -f $icon_path ]]; then
  print -u2 "Missing compiled app icon: $icon_path"
  exit 67
fi

assets_path="$app_path/Contents/Resources/Assets.car"
if [[ ! -f $assets_path ]]; then
  print -u2 "Missing compiled asset catalog: $assets_path"
  exit 68
fi

print "Verified compiled app icon: $icon_path"
