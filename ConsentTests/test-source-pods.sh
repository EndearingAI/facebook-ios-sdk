#!/usr/bin/env bash
# Copyright (c) Meta Platforms, Inc. and affiliates.
# All rights reserved. Licensed under the root LICENSE file.
set -euo pipefail

sdk_root="$(cd "$(dirname "$0")/.." && pwd)"
consumer_root="${FBSDK_SOURCE_PODS_BUILD_ROOT:-$(mktemp -d "${TMPDIR:-/tmp}/meta-source-pods.XXXXXX")}"
mkdir -p "$consumer_root"
export FBSDK_CONSENT_SDK_ROOT="$sdk_root"
cp "$sdk_root/ConsentTests/StaticConsumer/Podfile" "$consumer_root/Podfile"
xcodegen generate --spec "$sdk_root/ConsentTests/StaticConsumer/project.yml" --project "$consumer_root"
env -u GEM_HOME -u GEM_PATH LANG=en_US.UTF-8 pod install --project-directory="$consumer_root" > "$consumer_root/pod-install.log" 2>&1

for configuration in Debug Release; do
  log="$consumer_root/$configuration.log"
  if ! xcodebuild build -workspace "$consumer_root/MetaStaticConsumer.xcworkspace" \
    -scheme MetaStaticConsumer -configuration "$configuration" -sdk iphonesimulator \
    -destination 'generic/platform=iOS Simulator' -derivedDataPath "$consumer_root/DerivedData" \
    CODE_SIGNING_ALLOWED=NO ARCHS="${FBSDK_SOURCE_PODS_ARCHS:-arm64}" ONLY_ACTIVE_ARCH=YES > "$log" 2>&1; then
    tail -60 "$log" >&2
    exit 1
  fi
  printf '%s source static-library consumer passed: %s\n' "$configuration" "$log"
done
