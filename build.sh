#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
WORK="$ROOT/work"
SRC="$WORK/QubeVM"
DIST="$ROOT/dist"
UPSTREAM_URL="https://github.com/rhn-1k/QubeVM.git"
UPSTREAM_COMMIT="979d638e5d57ed0c01c4781957ddac5e9697e970"
QEMU_VERSION="11.1.3"
HOST_ABI="arm64-v8a"
GUEST="x86_64-softmmu"

fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || fail "Missing command: $1"; }

for cmd in git make python3 java; do need "$cmd"; done

SDK="${ANDROID_SDK_ROOT:-${ANDROID_HOME:-$HOME/Android/Sdk}}"
NDK="${ANDROID_NDK_HOME:-$SDK/ndk/30.0.14992026}"
[[ -d "$SDK" ]] || fail "Android SDK not found. Set ANDROID_SDK_ROOT."
[[ -d "$NDK" ]] || fail "Android NDK r30 not found at $NDK. Install NDK 30.0.14992026 and set ANDROID_NDK_HOME."
export ANDROID_SDK_ROOT="$SDK"
export ANDROID_HOME="$SDK"
export ANDROID_NDK_HOME="$NDK"
export JAVA_HOME="${JAVA_HOME:-$(dirname "$(dirname "$(readlink -f "$(command -v java)")")")}"
export PATH="$SDK/platform-tools:$SDK/cmdline-tools/latest/bin:$PATH"

mkdir -p "$WORK" "$DIST"
if [[ ! -d "$SRC/.git" ]]; then
  git clone "$UPSTREAM_URL" "$SRC"
fi
git -C "$SRC" fetch --depth 1 origin "$UPSTREAM_COMMIT"
git -C "$SRC" checkout --detach "$UPSTREAM_COMMIT"

JNI="$SRC/qube-android-lib/src/main/jni"
[[ -f "$JNI/Makefile" ]] || fail "Upstream JNI build system missing."
[[ -f "$SRC/gradlew" ]] || fail "Gradle wrapper missing."

export USE_QEMU_VERSION="$QEMU_VERSION"
export BUILD_HOST="$HOST_ABI"
export BUILD_GUEST="$GUEST"
export NDK_ROOT="$NDK"
export NDK_ENV="linux-x86_64"
export NDK_PLATFORM_API=30
export USE_KVM=false
export BUILD_THREADS="${BUILD_THREADS:-$(nproc)}"

printf '\n== Building QEMU %s (%s -> %s) ==\n' "$QEMU_VERSION" "$HOST_ABI" "$GUEST"
make -C "$JNI" qube

printf '\n== Building Android APK ==\n'
cd "$SRC"
chmod +x gradlew
./gradlew --no-daemon :qube-android-x86:assembleRelease

APK="$(find "$SRC/qube-android-x86/build/outputs/apk/release" -maxdepth 1 -type f -name '*.apk' -print -quit)"
[[ -n "$APK" && -f "$APK" ]] || fail "Gradle completed but APK was not found."

mkdir -p "$DIST"
cp "$APK" "$DIST/GhostVM-android-arm64.apk"
printf '\nAPK: %s\n' "$DIST/GhostVM-android-arm64.apk"
printf 'Note: this is the upstream QubeVM frontend under the GhostVM build name; a native GhostVM UI and on-device boot test are still pending.\n'
