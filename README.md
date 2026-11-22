# GhostVM

Android-only x86_64 virtual machine for ARM64 phones.

GhostVM targets **QEMU 11.1.3 / x86_64-softmmu / Android arm64-v8a** using TCG software emulation. It is based on the Android QEMU port in [QubeVM](https://github.com/rhn-1k/QubeVM), with its GPL-3.0 licensing retained.

## Status

This repository currently contains the reproducible native/APK build bootstrap. It is **not yet a verified GhostVM release**. The upstream Android QEMU engine is built as part of the process; the app currently uses the upstream QubeVM Android frontend under the GhostVM application label. A fully GhostVM-native frontend and device validation remain follow-up work.

## Build (Arch Linux)

Install the host dependencies:

```bash
sudo pacman -S --needed base-devel git wget curl unzip zip python cmake ninja meson pkgconf   jdk17-openjdk android-tools rsync patch perl nasm yasm glib2-devel libslirp
```

Install Android SDK command-line tools and accept licenses. Set:

```bash
export ANDROID_SDK_ROOT="$HOME/Android/Sdk"
export ANDROID_NDK_HOME="$ANDROID_SDK_ROOT/ndk/30.0.14992026"
```

Then:

```bash
./build.sh
```

The script checks for SDK/NDK, fetches the pinned upstream source, builds QEMU for ARM64 host + x86_64 guest, and assembles the APK. Output is placed in `dist/`.

## VM expectations

- Host ABI: `arm64-v8a`
- Guest machine: QEMU `x86_64-softmmu`
- Accelerator: TCG / MTTCG (software emulation; Android KVM is not assumed)
- Firmware: upstream QubeVM bundled PC firmware; UEFI availability depends on the firmware assets included by the pinned upstream revision.
- Performance: x86_64 emulation on ARM64 is CPU-intensive and much slower than native execution.

## License

GhostVM build scripts and original project files are GPL-3.0-or-later. QEMU and upstream components retain their respective licenses and notices. See [LICENSE](LICENSE) and the upstream [QubeVM repository](https://github.com/rhn-1k/QubeVM).

Do not redistribute a binary without also providing the corresponding source and notices required by the applicable licenses.
