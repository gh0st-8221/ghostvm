#!/usr/bin/env bash
set -Eeuo pipefail

SRC="$1"
UPSTREAM_COMMIT="979d638e5d57ed0c01c4781957ddac5e9697e970"
if [[ ! -d "$SRC/.git" ]]; then
  mkdir -p "$(dirname "$SRC")"
  git clone https://github.com/rhn-1k/QubeVM.git "$SRC"
fi
git -C "$SRC" fetch --depth 1 origin "$UPSTREAM_COMMIT"
git -C "$SRC" checkout --detach "$UPSTREAM_COMMIT"
JNI="$SRC/qube-android-lib/src/main/jni"
[[ -d "$JNI" ]] || { echo "JNI source directory not found: $JNI" >&2; exit 1; }
cd "$JNI"

fetch() {
  local url="$1" file="$2"
  [[ -s "$file" ]] || curl -fL --retry 3 "$url" -o "$file"
}

# QEMU 11.1.3
fetch https://download.qemu.org/qemu-11.1.3.tar.xz qemu-11.1.3.tar.xz
[[ -d qemu ]] || { tar -xJf qemu-11.1.3.tar.xz; mv qemu-11.1.3 qemu; }
patch -d qemu -p1 --forward < patches/qemu-11.1.3.patch || true

# GLib 2.90.1
fetch https://download.gnome.org/sources/glib/2.90/glib-2.90.1.tar.xz glib-2.90.1.tar.xz
[[ -d glib ]] || { tar -xJf glib-2.90.1.tar.xz; mv glib-2.90.1 glib; }
patch -d glib -p1 --forward < patches/glib-2.90.1.patch || true

# libffi 3.8.0
fetch https://github.com/libffi/libffi/releases/download/v3.8.0/libffi-3.8.0.tar.gz libffi-3.8.0.tar.gz
[[ -d libffi ]] || { tar -xzf libffi-3.8.0.tar.gz; mv libffi-3.8.0 libffi; }

# pixman 0.46.4
fetch https://gitlab.freedesktop.org/pixman/pixman/-/archive/pixman-0.46.4/pixman-pixman-0.46.4.tar.gz pixman-0.46.4.tar.gz
[[ -d pixman ]] || { tar -xzf pixman-0.46.4.tar.gz; mv pixman-pixman-0.46.4 pixman; }

# libslirp 4.9.5 (QEMU subproject)
fetch https://gitlab.freedesktop.org/slirp/libslirp/-/archive/v4.9.5/libslirp-v4.9.5.zip libslirp-v4.9.5.zip
mkdir -p qemu/subprojects
if [[ ! -d qemu/subprojects/libslirp ]]; then
  unzip -q libslirp-v4.9.5.zip -d qemu/subprojects/
  mv qemu/subprojects/libslirp-v4.9.5 qemu/subprojects/libslirp
fi
patch -d qemu/subprojects/libslirp -p1 --forward < patches/libslirp-4.9.5.patch || true

# libepoxy 1.5.10
fetch https://github.com/anholt/libepoxy/archive/refs/tags/1.5.10.zip libepoxy-1.5.10.zip
[[ -d libepoxy ]] || { unzip -q libepoxy-1.5.10.zip; mv libepoxy-1.5.10 libepoxy; }

# virglrenderer, as required by the upstream Android build
if [[ ! -d virglrenderer/.git ]]; then
  git clone --depth 1 https://gitlab.freedesktop.org/virgl/virglrenderer.git virglrenderer
fi
patch -d virglrenderer -p1 --forward < patches/virglrenderer-1.3.0-android-egl.patch || true
# Android uses platform EGL/GLES, not host libdrm. The NDK does not ship
# xf86drm.h; strip DRM-only includes from every virglrenderer C/header source.
# vtest is a host-only test server and must not enter the Android build graph.
python3 - <<'PY'
from pathlib import Path
import re

base = Path("virglrenderer")
for root in (base / "src", base / "vtest"):
    if root.exists():
        for p in root.rglob("*"):
            if p.suffix not in {".c", ".h"}:
                continue
            try:
                original = p.read_text()
            except (UnicodeDecodeError, OSError):
                continue
            cleaned = re.sub(r"^\\s*#\\s*include\\s*[<\\\"]xf86drm\\.h[>\\\"]\\s*\\n?", "", original, flags=re.M)
            if cleaned != original:
                p.write_text(cleaned)

# Remove any root-level Meson inclusion of vtest, allowing either quote style.
meson = base / "meson.build"
if meson.exists():
    original = meson.read_text()
    cleaned = re.sub(r"^\\s*subdir\\(\\s*['\\\"]vtest['\\\"]\\s*\\)\\s*\\n?", "", original, flags=re.M)
    if cleaned != original:
        meson.write_text(cleaned)

# Fail early rather than allowing a stale/unsupported DRM source into Ninja.
remaining = []
for root in (base / "src", base / "vtest"):
    if root.exists():
        for p in root.rglob("*"):
            if p.suffix in {".c", ".h"}:
                try:
                    if "xf86drm.h" in p.read_text():
                        remaining.append(str(p))
                except (UnicodeDecodeError, OSError):
                    pass
if remaining:
    raise SystemExit("Android virglrenderer cleanup failed; xf86drm.h remains in: " + ", ".join(remaining))
if meson.exists() and re.search(r"subdir\\(\\s*['\\\"]vtest['\\\"]\\s*\\)", meson.read_text()):
    raise SystemExit("Android virglrenderer cleanup failed; vtest is still enabled in meson.build")
print("Android virglrenderer cleanup: DRM headers removed; vtest disabled.")
PY
# Force Meson to regenerate targets from the cleaned Android source tree.
rm -rf virglrenderer/build-android
