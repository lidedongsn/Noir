#!/usr/bin/env bash
# 构建精简版 FFmpeg，输出 Packages/NoirKit/Frameworks/FFmpeg.xcframework。
# 仅启用 MKV / MP4 解封装、系统不支持的音频解码（TrueHD、DTS、Opus）、PGS 字幕解码及所需 parser；
# 视频解码、网络协议、图像缩放与滤镜均由系统负责，不编译。
#
# 用法：scripts/build-ffmpeg.sh [平台...]
#   平台：macos tvos tvos-sim ios ios-sim（默认全部）
set -euo pipefail

FFMPEG_VERSION="9.0.2"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# 工作目录：保留源码与各平台安装结果，便于单独重建某一平台
WORK="$ROOT/.build/ffmpeg"
SRC="$WORK/ffmpeg-$FFMPEG_VERSION"
OUT="$ROOT/Packages/NoirKit/Frameworks/FFmpeg.xcframework"

MACOS_MIN=15.0
TVOS_MIN=18.0
IOS_MIN=18.0

PLATFORMS=("$@")
[[ ${#PLATFORMS[@]} -eq 0 ]] && PLATFORMS=(macos tvos tvos-sim ios ios-sim)

mkdir -p "$WORK"
if [[ ! -d "$SRC" ]]; then
  echo "==> 下载 FFmpeg $FFMPEG_VERSION"
  curl -fL "https://ffmpeg.org/releases/ffmpeg-$FFMPEG_VERSION.tar.xz" -o "$WORK/ffmpeg.tar.xz"
  tar -xf "$WORK/ffmpeg.tar.xz" -C "$WORK"
  rm "$WORK/ffmpeg.tar.xz"
fi

CONFIGURE_FLAGS=(
  --disable-everything
  --disable-programs --disable-doc --disable-debug
  --disable-shared --enable-static --enable-pic
  --disable-autodetect --disable-network
  --disable-avdevice --disable-avfilter --disable-swscale
  # swresample 为 Opus 解码器的依赖
  --enable-avformat --enable-avcodec --enable-avutil --enable-swresample
  --enable-zlib
  # 容器
  --enable-demuxer=matroska,mov
  # 系统不支持的音频格式（TrueHD / DTS 无授权，多声道 Opus 无系统解码器）及 PGS 字幕
  --enable-decoder=truehd,mlp,dca,opus,pgssub
  # parser：补全时间戳、帧边界与码流参数
  --enable-parser=hevc,h264,av1,aac,ac3,mlp,dca,flac,opus
  --enable-bsf=dovi_rpu,hevc_mp4toannexb
)

build_one() {
  local platform="$1" sdk target
  case "$platform" in
    macos)    sdk=macosx;            target="arm64-apple-macos$MACOS_MIN" ;;
    tvos)     sdk=appletvos;         target="arm64-apple-tvos$TVOS_MIN" ;;
    tvos-sim) sdk=appletvsimulator;  target="arm64-apple-tvos$TVOS_MIN-simulator" ;;
    ios)      sdk=iphoneos;          target="arm64-apple-ios$IOS_MIN" ;;
    ios-sim)  sdk=iphonesimulator;   target="arm64-apple-ios$IOS_MIN-simulator" ;;
    *) echo "未知平台 $platform"; exit 1 ;;
  esac

  local sysroot cc build prefix
  sysroot="$(xcrun --sdk "$sdk" --show-sdk-path)"
  cc="$(xcrun --sdk "$sdk" -f clang)"
  build="$WORK/build-$platform"
  prefix="$WORK/install-$platform"
  rm -rf "$build" "$prefix"
  mkdir -p "$build"

  echo "==> 配置 $platform ($target)"
  (
    cd "$build"
    "$SRC/configure" "${CONFIGURE_FLAGS[@]}" \
      --prefix="$prefix" \
      --enable-cross-compile --target-os=darwin --arch=arm64 \
      --cc="$cc" --sysroot="$sysroot" \
      --extra-cflags="-target $target -O3" \
      --extra-ldflags="-target $target" \
      > configure.log
    echo "==> 编译 $platform"
    make -j"$(sysctl -n hw.ncpu)" > make.log 2>&1
    make install > install.log 2>&1
  )
  # 编译中间文件不再需要；失败时保留以便查看日志
  rm -rf "$build"

  # 合并为单个静态库以便打包 xcframework
  libtool -static -o "$prefix/lib/libffmpeg.a" \
    "$prefix/lib/libavformat.a" "$prefix/lib/libavcodec.a" "$prefix/lib/libswresample.a" "$prefix/lib/libavutil.a"

  # 生成头文件与 module map，供 Swift 以 CFFmpeg 模块导入
  cat > "$prefix/include/CFFmpeg.h" <<'EOF'
#include <libavformat/avformat.h>
#include <libavcodec/avcodec.h>
#include <libavcodec/bsf.h>
#include <libavutil/avutil.h>
#include <libavutil/channel_layout.h>
#include <libavutil/dovi_meta.h>
#include <libavutil/mastering_display_metadata.h>
#include <libavutil/opt.h>
#include <libavutil/pixdesc.h>
#include <libavutil/samplefmt.h>
EOF
  cat > "$prefix/include/module.modulemap" <<'EOF'
module CFFmpeg {
  header "CFFmpeg.h"
  export *
  link "z"
}
EOF
}

for p in "${PLATFORMS[@]}"; do build_one "$p"; done

echo "==> 打包 xcframework"
rm -rf "$OUT"
args=()
# 打包所有已构建的平台，单独重建某一平台时保留其余平台
for p in macos tvos tvos-sim ios ios-sim; do
  [[ -f "$WORK/install-$p/lib/libffmpeg.a" ]] || continue
  args+=(-library "$WORK/install-$p/lib/libffmpeg.a" -headers "$WORK/install-$p/include")
done
xcodebuild -create-xcframework "${args[@]}" -output "$OUT"
echo "==> 完成：$OUT"
