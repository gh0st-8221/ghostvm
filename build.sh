#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
WORK="$ROOT/work"
SRC="$WORK/QubeVM"
DIST="$ROOT/dist"
UPSTREAM_URL="https://github.com/rhn-1k/QubeVM.git"
UPSTREAM_COMMIT="979d638e5d57ed0c01c4781957ddac5e9697e970"
export USE_QEMU_VERSION="11.1.3"
export BUILD_HOST="arm64-v8a"
export BUILD_GUEST="x86_64-softmmu"
export USE_KVM=false
export NDK_ENV="linux-x86_64"
export BUILD_THREADS="${BUILD_THREADS:-$(nproc)}"

fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
for cmd in git make python3 java curl tar patch unzip rsync; do
  command -v "$cmd" >/dev/null 2>&1 || fail "Missing command: $cmd. On Arch Linux install it with: sudo pacman -S rsync (on Ubuntu: sudo apt-get install rsync)."
done

# virglrenderer generates Gallium sources with Python PyYAML.
if ! python3 -c "import yaml" >/dev/null 2>&1; then
  fail "Python module PyYAML is missing. On Arch Linux install it with: sudo pacman -S python-yaml (on Ubuntu: sudo apt-get install python3-yaml)."
fi

SDK="${ANDROID_SDK_ROOT:-${ANDROID_HOME:-$HOME/Android/Sdk}}"
NDK="${ANDROID_NDK_HOME:-$SDK/ndk/30.0.16248370}"
[[ -d "$SDK" ]] || fail "Android SDK not found. Set ANDROID_SDK_ROOT."
[[ -d "$NDK" ]] || fail "Android NDK r30 (30.0.16248370) not found: $NDK"
export ANDROID_SDK_ROOT="$SDK" ANDROID_HOME="$SDK"
export ANDROID_NDK_HOME="$NDK" NDK_ROOT="$NDK"
export PATH="$SDK/platform-tools:$SDK/cmdline-tools/latest/bin:$NDK:$PATH"

mkdir -p "$WORK" "$DIST"
if [[ ! -d "$SRC/.git" ]]; then git clone "$UPSTREAM_URL" "$SRC"; fi
git -C "$SRC" fetch --depth 1 origin "$UPSTREAM_COMMIT"
git -C "$SRC" checkout --detach "$UPSTREAM_COMMIT"

JNI="$SRC/qube-android-lib/src/main/jni"
[[ -f "$JNI/Makefile" ]] || fail "Upstream JNI Makefile missing."
[[ -f "$SRC/gradlew" ]] || fail "Gradle wrapper missing."

# Prepare all upstream sources automatically. Safe to re-run: downloaded archives
# and extracted source trees are kept under work/QubeVM.
printf '\\n== Preparing pinned QEMU sources and dependencies ==\\n'
bash "$ROOT/scripts/prepare-upstream.sh" "$SRC"

for dep in qemu glib libffi pixman libepoxy virglrenderer; do
  [[ -d "$JNI/$dep" ]] || fail "Dependency preparation did not produce $dep."
done

printf '\n== Building QEMU 11.1.3 for ARM64 Android (x86_64 guest, TCG) ==\n'
make -C "$JNI" qube

printf '\n== Building release APK ==\n'
cd "$SRC"
chmod +x gradlew

# Ensure Android raw resources exist before AGP generates the library R class.
# The upstream syncQemuValues task may not run early enough with newer AGP.
VALUES_DIR="$SRC/qube-android-lib/qemu-values/$USE_QEMU_VERSION"
RAW_DIR="$SRC/qube-android-lib/src/main/res/raw"
[[ -d "$VALUES_DIR" ]] || fail "QEMU values directory not found: $VALUES_DIR"
mkdir -p "$RAW_DIR"
cp -f "$VALUES_DIR"/*.txt "$RAW_DIR"/
[[ -n "$(find "$RAW_DIR" -maxdepth 1 -type f -name '*.txt' -print -quit)" ]] || fail "No QEMU raw resource files were copied."
printf 'Installed QEMU Android resources from %s\n' "$VALUES_DIR"

./gradlew --no-daemon -PqemuVersion="$USE_QEMU_VERSION" :qube-android-x86:assembleRelease

APK="$(find "$SRC/qube-android-x86/build/outputs/apk/release" -maxdepth 1 -type f -name '*.apk' -print -quit)"
[[ -n "$APK" && -f "$APK" ]] || fail "APK not found after Gradle build."
cp "$APK" "$DIST/GhostVM-android-arm64.apk"
printf 'APK ready: %s\n' "$DIST/GhostVM-android-arm64.apk"
