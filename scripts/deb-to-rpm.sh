#!/usr/bin/env bash
# scripts/deb-to-rpm.sh
# 用法: bash scripts/deb-to-rpm.sh <input.deb> [output.rpm]
set -euo pipefail

DEB_IN="${1:?usage: deb-to-rpm.sh <input.deb> [output.rpm]}"
RPM_OUT="${2:-}"
DEB_IN="$(readlink -f "$DEB_IN")"
if [ -n "$RPM_OUT" ]; then
  RPM_OUT="$(readlink -f "$RPM_OUT")"
fi

WORK_DIR="$(mktemp -d -t deb2rpm.XXXXXX)"
trap 'rm -rf "$WORK_DIR"' EXIT

cp "$DEB_IN" "$WORK_DIR/input.deb"
cd "$WORK_DIR"

dpkg-deb -e input.deb control
mkdir root
dpkg-deb -x input.deb root

NAME="$(awk -F': ' '/^Package:/{print $2}' control/control | head -1)"
VERSION="$(awk -F': ' '/^Version:/{print $2}' control/control | head -1)"
ARCH="$(awk -F': ' '/^Architecture:/{print $2}' control/control | head -1)"
SUMMARY="$(awk -F': ' '/^Description:/{print $2}' control/control | head -1)"
HOMEPAGE="$(awk -F': ' '/^Homepage:/{print $2}' control/control | head -1)"
MAINTAINER="$(awk -F': ' '/^Maintainer:/{print $2}' control/control | head -1)"

# deb 版本可能是 5.5.6+slim1
BASE_VERSION="${VERSION%%+*}"
if [[ "$VERSION" == *+* ]]; then
  ITERATION="${VERSION#*+}"
else
  ITERATION="1"
fi

# 架构映射：只有 x64 实际会用到
case "$ARCH" in
  amd64) ARCH="x86_64" ;;
  arm64) ARCH="aarch64" ;;
esac

# Debian 依赖名 → RPM 依赖名
map_dep() {
  case "$1" in
    libgtk-3-0)         echo "gtk3" ;;
    libnotify4)         echo "libnotify" ;;
    libnss3)            echo "nss" ;;
    libxss1)            echo "libXScrnSaver" ;;
    libxtst6)           echo "libXtst" ;;
    xdg-utils)          echo "xdg-utils" ;;
    libatspi2.0-0)      echo "at-spi2-core" ;;
    libappindicator3-1) echo "libappindicator-gtk3" ;;
    libuuid1)           echo "libuuid" ;;
    libsecret-1-0)      echo "libsecret" ;;
    libasound2)         echo "alsa-lib" ;;
    libgbm1)            echo "mesa-libgbm" ;;
    libdrm2)            echo "libdrm" ;;
    libxkbcommon0)      echo "libxkbcommon" ;;
    libpango-1.0-0)     echo "pango" ;;
    libcairo2)          echo "cairo" ;;
    libcups2)           echo "cups-libs" ;;
    libexpat1)          echo "expat" ;;
    libfontconfig1)     echo "fontconfig" ;;
    libfreetype6)       echo "freetype" ;;
    *) echo "" ;;
  esac
}

DEPS=()
DEP_LINE="$(grep -E '^Depends:' control/control | head -1 | cut -d' ' -f2- || true)"
IFS=',' read -ra RAW_DEPS <<< "$DEP_LINE"
for d in "${RAW_DEPS[@]}"; do
  d="$(echo "$d" | xargs)"
  d="${d%% *}"
  d="${d%%(*}"
  [ -z "$d" ] && continue
  mapped="$(map_dep "$d")"
  [ -n "$mapped" ] && DEPS+=("$mapped")
done

if [ ${#DEPS[@]} -gt 0 ]; then
  mapfile -t DEPS < <(printf '%s\n' "${DEPS[@]}" | sort -u)
fi

FPM_DEP_ARGS=()
for dep in "${DEPS[@]}"; do
  FPM_DEP_ARGS+=( --depends "$dep" )
done

SCRIPT_ARGS=()
[ -f control/preinst ]  && SCRIPT_ARGS+=( --before-install control/preinst )
[ -f control/postinst ] && SCRIPT_ARGS+=( --after-install  control/postinst )
[ -f control/prerm ]    && SCRIPT_ARGS+=( --before-remove  control/prerm )
[ -f control/postrm ]   && SCRIPT_ARGS+=( --after-remove   control/postrm )

if [ -z "$RPM_OUT" ]; then
  RPM_OUT="$(dirname "$DEB_IN")/${NAME}-${BASE_VERSION}-${ITERATION}.${ARCH}.rpm"
fi

echo "==> Building RPM: $RPM_OUT"
fpm -s dir -t rpm \
  -n "$NAME" \
  -v "$BASE_VERSION" \
  --iteration "$ITERATION" \
  -a "$ARCH" \
  --rpm-summary "$SUMMARY" \
  --description "$SUMMARY" \
  --url "${HOMEPAGE:-https://workbuddy.cn/}" \
  --license "Proprietary" \
  --vendor "Tencent" \
  --maintainer "${MAINTAINER:-LeisureLinux <AlbertXu@FreeLAMP.com>}" \
  "${FPM_DEP_ARGS[@]}" \
  "${SCRIPT_ARGS[@]}" \
  -C root \
  -p "$RPM_OUT" \
  --force \
  .

echo "==> Done"
ls -lh "$RPM_OUT"
