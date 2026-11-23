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
git -C "$SRC" reset --hard "$UPSTREAM_COMMIT"
JNI="$SRC/qube-android-lib/src/main/jni"
[[ -d "$JNI" ]] || { echo "JNI source directory not found: $JNI" >&2; exit 1; }
cd "$JNI"

# QubeVM's pinned Makefile passes a Meson option removed in virglrenderer
# 1.3.0. Remove that one option line while preserving the continued command.
python3 - <<'PY'
from pathlib import Path

p = Path("Makefile")
lines = p.read_text().splitlines(keepends=True)
matches = [i for i, line in enumerate(lines) if "-Drender-server-mode=" in line]
if len(matches) > 1:
    raise SystemExit(f"Expected at most one obsolete render-server-mode option, found {len(matches)}")
if matches:
    del lines[matches[0]]
    p.write_text("".join(lines))
    print("Removed obsolete virglrenderer render-server-mode option.")
else:
    print("Obsolete virglrenderer render-server-mode option already absent.")
PY

fetch() {
  local url="$1" file="$2"
  [[ -s "$file" ]] || curl -fL --retry 3 "$url" -o "$file"
}

# Apply patches safely on reruns: skip only when the reverse patch proves
# that the complete patch is already present. Fail on genuine mismatches.
apply_patch() {
  local target="$1" patch_file="$2"
  if patch --dry-run --silent -d "$target" -p1 --forward < "$patch_file"; then
    patch -d "$target" -p1 --forward < "$patch_file"
  elif patch --dry-run --silent -d "$target" -p1 -R < "$patch_file"; then
    echo "Patch already applied: $patch_file"
  else
    echo "Patch does not apply cleanly (and is not already applied): $patch_file" >&2
    return 1
  fi
}

# QEMU 11.1.3
fetch https://download.qemu.org/qemu-11.1.3.tar.xz qemu-11.1.3.tar.xz
[[ -d qemu ]] || { tar -xJf qemu-11.1.3.tar.xz; mv qemu-11.1.3 qemu; }
apply_patch qemu patches/qemu-11.1.3.patch

# GLib 2.90.1
fetch https://download.gnome.org/sources/glib/2.90/glib-2.90.1.tar.xz glib-2.90.1.tar.xz
[[ -d glib ]] || { tar -xJf glib-2.90.1.tar.xz; mv glib-2.90.1 glib; }
apply_patch glib patches/glib-2.90.1.patch

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
apply_patch qemu/subprojects/libslirp patches/libslirp-4.9.5.patch

# libepoxy 1.5.10
fetch https://github.com/anholt/libepoxy/archive/refs/tags/1.5.10.zip libepoxy-1.5.10.zip
[[ -d libepoxy ]] || { unzip -q libepoxy-1.5.10.zip; mv libepoxy-1.5.10 libepoxy; }

# virglrenderer, as required by the upstream Android build
# The Android patch is written specifically for upstream virglrenderer 1.3.0.
# Do not build against an unpinned moving branch.
if [[ ! -d virglrenderer/.git ]]; then
  git clone --depth 1 --branch 1.3.0 https://gitlab.freedesktop.org/virgl/virglrenderer.git virglrenderer
else
  git -C virglrenderer reset --hard
  git -C virglrenderer clean -fd
  git -C virglrenderer fetch --depth 1 origin refs/tags/1.3.0:refs/tags/1.3.0
  git -C virglrenderer checkout --force --detach 1.3.0
fi
# The bundled patch's meson.build context drifted from the 1.3.0 release
# tarball. Apply its C-source changes separately, then make the Meson changes
# with exact, checked transformations below.
tmp_patch="$(mktemp)"
sed -n '/^--- pristine\/src\//,$p' patches/virglrenderer-1.3.0-android-egl.patch > "$tmp_patch"
apply_patch virglrenderer "$tmp_patch"
rm -f "$tmp_patch"

python3 - <<'PY'
from pathlib import Path

p = Path("virglrenderer/meson.build")
s = p.read_text()

def replace_once(old: str, new: str) -> None:
    global s
    count = s.count(old)
    if count == 0:
        # Accept an already-patched file on a rerun.
        if new in s:
            return
        raise SystemExit("Expected Meson context not found: " + old.splitlines()[0])
    if count != 1:
        raise SystemExit("Meson context is ambiguous: " + old.splitlines()[0])
    s = s.replace(old, new, 1)

replace_once(
    "with_host_windows = host_machine.system() == 'windows'\n"
    "with_host_darwin = host_machine.system() == 'darwin'\n",
    "with_host_windows = host_machine.system() == 'windows'\n"
    "with_host_darwin = host_machine.system() == 'darwin'\n"
    "with_host_android = host_machine.system() == 'android'\n",
)
# Match the pinned release's libdrm dependency regardless of Meson
# keyword spacing/version formatting; keep the original dependency on hosts.
import re
if "with_host_android" not in s:
    raise SystemExit("Android host detection was not inserted")
if "libdrm_dep = declare_dependency()" not in s:
    pattern = re.compile(r"(?m)^(?P<indent>[ \t]*)libdrm_dep\s*=\s*dependency\(\s*['\"]libdrm['\"].*\)\s*$")
    matches = list(pattern.finditer(s))
    if len(matches) != 1:
        raise SystemExit(f"Expected exactly one libdrm dependency assignment, found {len(matches)}")
    m = matches[0]
    indent = m.group("indent")
    original = m.group(0).strip()
    guarded = (
        f"{indent}if with_host_android\n"
        f"{indent}  # Android uses platform EGL/GLES and has no host libdrm dependency.\n"
        f"{indent}  libdrm_dep = declare_dependency()\n"
        f"{indent}else\n"
        f"{indent}  {original}\n"
        f"{indent}endif"
    )
    s = s[:m.start()] + guarded + s[m.end():]
replace_once(
    "epoxy_dep = dependency('epoxy', version: '>= 1.5.4')\n",
    "if with_host_android\n"
    "  # Android builds epoxy directly with the NDK; pkg-config is unavailable.\n"
    "  epoxy_dep = declare_dependency(compile_args: [], link_args: ['-lepoxy'], version: '1.5.10')\n"
    "else\n"
    "  epoxy_dep = dependency('epoxy', version: '>= 1.5.4')\n"
    "endif\n",
)
replace_once(
    "if cc.has_header('epoxy/egl.h', dependencies: epoxy_dep) and epoxy_dep.get_variable(pkgconfig: 'epoxy_has_egl') == '1'\n"
    "      if with_host_windows or with_host_darwin\n",
    "if cc.has_header('epoxy/egl.h', dependencies: epoxy_dep) and (with_host_android or epoxy_dep.get_variable(pkgconfig: 'epoxy_has_egl') == '1')\n"
    "      if with_host_windows or with_host_darwin or with_host_android\n",
)
replace_once(
    "if cc.has_header('epoxy/glx.h', dependencies: epoxy_dep) and epoxy_dep.get_variable(pkgconfig: 'epoxy_has_glx') == '1'\n",
    "if not with_host_android and cc.has_header('epoxy/glx.h', dependencies: epoxy_dep) and epoxy_dep.get_variable(pkgconfig: 'epoxy_has_glx') == '1'\n",
)
replace_once(
    "if not with_host_windows\n   subdir('vtest')\nendif\n",
    "if not with_host_windows and not with_host_android\n   subdir('vtest')\nendif\n",
)

p.write_text(s)
print("Android virglrenderer Meson configuration applied.")
PY

# Android uses platform EGL/GLES, not host libdrm. The NDK does not ship
# xf86drm.h; strip DRM-only includes from every virglrenderer C/header source.
# vtest is a host-only test server and must not enter the Android build graph.
python3 - <<'PY'
from pathlib import Path

base = Path("virglrenderer")
for root in (base / "src", base / "vtest"):
    if root.exists():
        for p in root.rglob("*"):
            if p.suffix not in {".c", ".h"}:
                continue
            try:
                lines = p.read_text().splitlines(keepends=True)
            except (UnicodeDecodeError, OSError):
                continue
            cleaned = [line for line in lines if not ("#include" in line and "xf86drm.h" in line)]
            if cleaned != lines:
                p.write_text("".join(cleaned))

meson = base / "meson.build"
if meson.exists():
    lines = meson.read_text().splitlines(keepends=True)
    cleaned = [line for line in lines if not ("subdir" in line and "vtest" in line)]
    if cleaned != lines:
        meson.write_text("".join(cleaned))

remaining = []
for root in (base / "src", base / "vtest"):
    if root.exists():
        for p in root.rglob("*"):
            if p.suffix in {".c", ".h"}:
                try:
                    if any(
                        line.lstrip().startswith("#include") and "xf86drm.h" in line
                        for line in p.read_text().splitlines()
                    ):
                        remaining.append(str(p))
                except (UnicodeDecodeError, OSError):
                    pass
if remaining:
    raise SystemExit("Android cleanup failed; xf86drm.h remains: " + ", ".join(remaining))
if meson.exists() and any("subdir" in line and "vtest" in line for line in meson.read_text().splitlines()):
    raise SystemExit("Android cleanup failed; vtest is still enabled in meson.build")
print("Android virglrenderer cleanup: DRM headers removed; vtest disabled.")
PY
# Force Meson to regenerate targets from the cleaned Android source tree.
rm -rf virglrenderer/build-android
