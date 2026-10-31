#!/usr/bin/env bash
# This stage runs in Dockerfile.kernel; all writes stay in this run's work volume.
set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${BUILD_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}"
WORK="${BUILD_WORK_DIR:-/work}"
# shellcheck disable=SC1090
source "${CONFIG_FILE:-$ROOT/config/build.env}"
SOURCE_LOCK="${SOURCE_REVISION_LOCK_FILE:-$ROOT/config/source-revisions.lock.tsv}"
PREPARED_DIR="${BUILD_PREPARED_INPUTS_DIR:-$WORK/prepared}"
ORBITAL_SOURCE_DIR="${ORBITAL_SOURCE_DIR_OVERRIDE:-}"
mkdir -p "$WORK/sources" "$WORK/state"
if [[ -e "$PREPARED_DIR" ]]; then
    echo "Prepared-input destination already exists; refusing to overwrite: $PREPARED_DIR" >&2
    exit 1
fi
mkdir -p "$PREPARED_DIR"
trap 'echo "Input preparation failed at line $LINENO" >&2' ERR

while IFS=$'\t' read -r component repository revision version license; do
    [[ "$component" != component ]] || continue
    [[ "$component" =~ ^[a-z][a-z0-9-]*$ && "$revision" =~ ^[0-9a-f]{40}$ ]]
    [[ "$repository" == https://* ]]
    if [[ "$component" == orbital && -n "$ORBITAL_SOURCE_DIR" ]]; then
        actual="$(git -C "$ORBITAL_SOURCE_DIR" rev-parse HEAD)"
        [[ "$actual" == "$revision" ]] || {
            echo "Orbital revision mismatch: expected $revision, got $actual" >&2
            exit 1
        }
        continue
    fi
    dir="$WORK/sources/$component"
    if [[ ! -d "$dir/.git" ]]; then
        if [[ -n "$(find "$dir" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]]; then
            echo "Refusing to initialize source checkout over non-empty directory: $dir" >&2
            exit 1
        fi
        git -c init.defaultBranch=main init "$dir"
        git -C "$dir" remote add origin "$repository"
    fi
    [[ "$(git -C "$dir" remote get-url origin)" == "$repository" ]]
    git -C "$dir" fetch --depth 1 origin "$revision"
    git -C "$dir" reset --hard FETCH_HEAD
    git -C "$dir" clean -fdx
    [[ "$(git -C "$dir" rev-parse HEAD)" == "$revision" ]]
done < "$SOURCE_LOCK"

kernel="$WORK/sources/kernel"
for patch in "$ROOT"/kernel-patches/*.patch; do
    git -C "$kernel" apply --check "$patch"
    git -C "$kernel" apply "$patch"
done
cp "$WORK/sources/pmaports/device/community/linux-postmarketos-qcom-sdm845/config-postmarketos-qcom-sdm845.aarch64" "$kernel/.config"
# Keep the release string matched to the packaged modules despite local patches.
"$kernel/scripts/config" --file "$kernel/.config" --disable LOCALVERSION_AUTO
export KCONFIG_NOTIMESTAMP=1 KBUILD_BUILD_USER=orbital KBUILD_BUILD_HOST=builder
KBUILD_BUILD_TIMESTAMP="$(git -C "$kernel" show -s --format=%cI HEAD)"
export KBUILD_BUILD_TIMESTAMP
make -C "$kernel" ARCH=arm64 LLVM=1 CROSS_COMPILE=aarch64-linux-gnu- LOCALVERSION= olddefconfig
make -C "$kernel" ARCH=arm64 LLVM=1 CROSS_COMPILE=aarch64-linux-gnu- LOCALVERSION= syncconfig
release="$(make -s -C "$kernel" ARCH=arm64 LLVM=1 CROSS_COMPILE=aarch64-linux-gnu- LOCALVERSION= kernelrelease)"
[[ "$release" == "$KERNEL_RELEASE" ]] || { echo "Kernel release mismatch: $release" >&2; exit 1; }
make -C "$kernel" -j"${BUILD_JOBS:-2}" ARCH=arm64 LLVM=1 CROSS_COMPILE=aarch64-linux-gnu- LOCALVERSION= Image.gz modules qcom/sdm845-oneplus-enchilada.dtb
make -C "$kernel" ARCH=arm64 LLVM=1 CROSS_COMPILE=aarch64-linux-gnu- LOCALVERSION= INSTALL_MOD_PATH="$PREPARED_DIR/kernel/usr" INSTALL_MOD_STRIP=1 modules_install
kernel_image="$kernel/arch/arm64/boot/Image.gz"
[[ -f "$kernel_image" ]] || kernel_image="$kernel/arch/arm64/boot/vmlinuz"
[[ -f "$kernel_image" ]] || { echo "No gzip kernel image was produced" >&2; exit 1; }
install -D -m 0644 "$kernel_image" "$PREPARED_DIR/kernel/boot/vmlinuz"
install -m 0644 "$kernel/arch/arm64/boot/dts/qcom/sdm845-oneplus-enchilada.dtb" "$PREPARED_DIR/kernel/boot/sdm845-oneplus-enchilada.dtb"
rm -f "$PREPARED_DIR/kernel/usr/lib/modules/$release/build" "$PREPARED_DIR/kernel/usr/lib/modules/$release/source"

export PKG_CONFIG_LIBDIR="/usr/lib/aarch64-linux-gnu/pkgconfig:/usr/share/pkgconfig"
export PKG_CONFIG_SYSROOT_DIR=/ LDFLAGS="-L/usr/lib/aarch64-linux-gnu"
prefix="$WORK/helper-prefix"
meson setup "$WORK/qrtr-build" "$WORK/sources/qrtr" --cross-file "$ROOT/config/helpers-cross.ini" \
    --prefix="$prefix" --libdir=lib -Ddefault_library=static -Dqrtr-ns=disabled -Dsystemd-service=disabled
meson compile -C "$WORK/qrtr-build"
meson install -C "$WORK/qrtr-build"
qrtr_library="$(find "$prefix/lib" -maxdepth 1 -type f -name 'libqrtr.so.*.*' | head -n 1)"
[[ -n "$qrtr_library" ]] || { echo "libqrtr shared library was not produced" >&2; exit 1; }
qrtr_soname="$(aarch64-linux-gnu-readelf -d "$qrtr_library" | sed -n 's/.*SONAME.*\[\(.*\)\].*/\1/p')"
[[ "$qrtr_soname" == libqrtr.so.* ]] || { echo "unexpected libqrtr SONAME: $qrtr_soname" >&2; exit 1; }
install -D -m 0755 "$qrtr_library" "$PREPARED_DIR/qrtr/lib/$(basename "$qrtr_library")"
ln -sfn "$(basename "$qrtr_library")" "$PREPARED_DIR/qrtr/lib/$qrtr_soname"
printf '%s\n' "$qrtr_soname" > "$PREPARED_DIR/qrtr/soname"
export PKG_CONFIG_PATH="$prefix/lib/pkgconfig"
meson setup "$WORK/tqftpserv-build" "$WORK/sources/tqftpserv" --cross-file "$ROOT/config/helpers-cross.ini"
meson compile -C "$WORK/tqftpserv-build"
make -C "$WORK/sources/pd-mapper" CC=aarch64-linux-gnu-gcc \
    CFLAGS="-O2 -I$prefix/include" LDFLAGS="-L$prefix/lib -L/usr/lib/aarch64-linux-gnu -lqrtr -llzma"
# Upstream commits generated QMI C/H; don't require a floating qmic tool.
make -C "$WORK/sources/rmtfs" -o qmi_rmtfs.c CC=aarch64-linux-gnu-gcc \
    CFLAGS="-O2 -I$prefix/include" LDFLAGS="-L$prefix/lib -L/usr/lib/aarch64-linux-gnu -lqrtr -ludev -lpthread"
for helper in tqftpserv pd-mapper rmtfs; do
    binary="$WORK/sources/$helper/$helper"
    [[ "$helper" != tqftpserv ]] || binary="$WORK/tqftpserv-build/tqftpserv"
    install -D -m 0755 "$binary" "$PREPARED_DIR/$helper/$helper"
    aarch64-linux-gnu-readelf -h "$binary" | grep -q AArch64
    aarch64-linux-gnu-readelf -d "$binary" | grep -q "NEEDED.*$qrtr_soname"
done
{
    printf 'component\trepository\tcommit\tversion\tlicense\n'
    while IFS=$'\t' read -r component repository revision version license; do
        [[ "$component" != component ]] || continue
        printf '%s\t%s\t%s\t%s\t%s\n' \
            "$component" "$repository" "$revision" "$version" "$license"
    done < "$SOURCE_LOCK"
} > "$PREPARED_DIR/source-revisions.lock.tsv"
mkdir -p "$PREPARED_DIR/patches"
for patch in "$ROOT"/kernel-patches/*.patch; do
    [[ -f "$patch" ]] || continue
    install -m 0644 "$patch" "$PREPARED_DIR/patches/$(basename "$patch")"
done
cd "$PREPARED_DIR"
find . -type f -print0 | LC_ALL=C sort -z | xargs -0 sha256sum > "$WORK/state/prepared.sha256"
cp "$WORK/state/prepared.sha256" "$PREPARED_DIR/prepared.sha256"
echo "Source kernel, matching modules and helpers prepared"
