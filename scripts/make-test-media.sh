#!/usr/bin/env bash
# 生成测试片源至 TestMedia/（依赖带 libx265 与 libx264 的 ffmpeg）。
# 音频为声道识别信号：第 k 秒仅第 k 个声道有信号，频率随声道序号递增，用于校验声道映射。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/TestMedia"
TMP="$OUT/.parts"
DUR=10
mkdir -p "$OUT" "$TMP"

ff() { ffmpeg -hide_banner -loglevel error -y "$@"; }

# 生成 N 声道识别信号（48 kHz，s32 无损中间格式）
channel_ident() {
  local layout="$1" n="$2" out="$3" exprs=""
  for ((k = 0; k < n; k++)); do
    local freq=$((300 + k * 100))
    exprs+="0.5*sin(2*PI*$freq*t)*eq(floor(mod(t\\,$n))\\,$k)"
    ((k < n - 1)) && exprs+="|"
  done
  ff -f lavfi -i "aevalsrc=exprs='$exprs':s=48000:c=$layout:d=$DUR" -c:a pcm_s32le "$out"
}

# 字幕源文件：第 1–3 秒与第 5–7 秒各一条
make_subtitles() {
  cat > "$1/eng.srt" <<'SRT'
1
00:00:01,000 --> 00:00:03,000
First <i>line</i>

2
00:00:05,000 --> 00:00:07,000
Second line
SRT
  cat > "$1/chs.ass" <<'ASS'
[Script Info]
ScriptType: v4.00+
PlayResX: 1920
PlayResY: 1080

[V4+ Styles]
Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
Style: Default,PingFang SC,70,&H00FFFFFF,&H000000FF,&H00000000,&H80000000,0,0,0,0,100,100,0,0,1,3,1,2,20,20,40,1
Style: Sign,PingFang SC,50,&H0000FFFF,&H000000FF,&H00000000,&H00000000,1,0,0,0,100,100,0,0,1,2,0,8,20,20,40,1

[Events]
Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
Dialogue: 0,0:00:01.00,0:00:03.00,Default,,0,0,0,,第一行字幕\N第二行
Dialogue: 0,0:00:05.00,0:00:07.00,Sign,,0,0,0,,{\pos(960,200)\fad(200,200)}招牌文字
ASS
}

echo "==> 生成视频轨"
# 4K HDR10：BT.2020 + PQ + 母版显示器信息
ff -f lavfi -i "testsrc2=s=3840x2160:r=24000/1001:d=$DUR" \
  -vf "format=yuv420p10le,setparams=color_primaries=bt2020:color_trc=smpte2084:colorspace=bt2020nc" \
  -c:v libx265 -preset ultrafast -tag:v hvc1 \
  -x265-params "log-level=error:hdr10=1:repeat-headers=1:colorprim=bt2020:transfer=smpte2084:colormatrix=bt2020nc:master-display=G(13250,34500)B(7500,3000)R(34000,16000)WP(15635,16450)L(10000000,50):max-cll=1000,400" \
  -color_primaries bt2020 -color_trc smpte2084 -colorspace bt2020nc \
  "$TMP/v-hdr10.mkv"

# 1080p HLG
ff -f lavfi -i "testsrc2=s=1920x1080:r=50:d=$DUR" \
  -vf "format=yuv420p10le,setparams=color_primaries=bt2020:color_trc=arib-std-b67:colorspace=bt2020nc" \
  -c:v libx265 -preset ultrafast -tag:v hvc1 \
  -x265-params "log-level=error:colorprim=bt2020:transfer=arib-std-b67:colormatrix=bt2020nc" \
  -color_primaries bt2020 -color_trc arib-std-b67 -colorspace bt2020nc \
  "$TMP/v-hlg.mkv"

# 1080p SDR HEVC 8-bit 与 H.264
ff -f lavfi -i "testsrc2=s=1920x1080:r=24:d=$DUR" -pix_fmt yuv420p \
  -c:v libx265 -preset ultrafast -x265-params log-level=error -tag:v hvc1 "$TMP/v-sdr-hevc.mkv"
ff -f lavfi -i "testsrc2=s=1920x1080:r=24:d=$DUR" -pix_fmt yuv420p \
  -c:v h264_videotoolbox -b:v 8M "$TMP/v-sdr-h264.mkv"

echo "==> 生成音频源"
channel_ident 7.1 8 "$TMP/a-71.wav"
channel_ident 5.1 6 "$TMP/a-51.wav"
channel_ident stereo 2 "$TMP/a-20.wav"

echo "==> 封装测试片源"
mux() { # 视频 音频 输出 编码参数...
  local v="$1" a="$2" o="$3"; shift 3
  ff -i "$TMP/$v" -i "$TMP/$a" -map 0:v -map 1:a -c:v copy "$@" -shortest "$OUT/$o"
}
# FFmpeg 的 TrueHD 编码器最多支持 5.1
mux v-hdr10.mkv    a-51.wav hdr10-hevc-truehd51.mkv -c:a truehd -strict -2
mux v-hlg.mkv      a-51.wav hlg-hevc-eac351.mkv     -c:a eac3 -b:a 640k
mux v-sdr-hevc.mkv a-51.wav sdr-hevc-dts51.mkv      -c:a dca -strict -2 -b:a 1509k
mux v-sdr-hevc.mkv a-71.wav sdr-hevc-flac71.mkv     -c:a flac -sample_fmt s32
mux v-sdr-hevc.mkv a-51.wav sdr-hevc-opus51.mkv     -c:a libopus -b:a 384k -mapping_family 1
mux v-sdr-hevc.mkv a-20.wav sdr-hevc-opus20.mkv     -c:a libopus -b:a 192k
mux v-sdr-hevc.mkv a-20.wav sdr-hevc-alac20.mkv     -c:a alac
mux v-sdr-h264.mkv a-51.wav sdr-h264-ac351.mkv      -c:a ac3 -b:a 640k
mux v-sdr-h264.mkv a-51.wav sdr-h264-aac51.mp4      -c:a aac -b:a 384k

# 多音轨：TrueHD 5.1 + E-AC3 5.1 + AAC 2.0，带语言标记，用于音轨切换
ff -i "$TMP/v-hdr10.mkv" -i "$TMP/a-51.wav" -i "$TMP/a-51.wav" -i "$TMP/a-20.wav" \
  -map 0:v -map 1:a -map 2:a -map 3:a -c:v copy \
  -c:a:0 truehd -strict -2 -c:a:1 eac3 -b:a:1 640k -c:a:2 aac -b:a:2 192k \
  -metadata:s:a:0 language=eng -metadata:s:a:0 title="TrueHD 5.1" \
  -metadata:s:a:1 language=jpn -metadata:s:a:1 title="E-AC3 5.1" \
  -metadata:s:a:2 language=chi -metadata:s:a:2 title="AAC 2.0" \
  -shortest "$OUT/hdr10-multi-audio.mkv"

# H.264 连续 B 帧与金字塔结构（重排序深），用于验证解码输出按显示顺序排列
ff -f lavfi -i "testsrc2=s=1920x1080:r=24:d=$DUR" -i "$TMP/a-20.wav" -pix_fmt yuv420p \
  -c:v libx264 -profile:v high -x264-params "bframes=8:b-pyramid=normal:b-adapt=0:ref=3:log-level=error" \
  -c:a aac -b:a 128k -shortest "$OUT/sdr-h264-bpyramid.mp4"

# 2.39:1 宽银幕，用于验证窗口比例锁定
ff -f lavfi -i "testsrc2=s=1920x804:r=24:d=$DUR" -i "$TMP/a-20.wav" -pix_fmt yuv420p \
  -c:v libx265 -preset ultrafast -x265-params log-level=error -tag:v hvc1 -c:a aac -b:a 128k \
  -shortest "$OUT/scope-239.mkv"

echo "==> 生成字幕片源"
make_subtitles "$TMP"
# 内封字幕：英文 SRT + 简体中文 ASS（默认）
ff -i "$TMP/v-sdr-hevc.mkv" -i "$TMP/a-20.wav" -i "$TMP/eng.srt" -i "$TMP/chs.ass" \
  -map 0:v -map 1:a -map 2:s -map 3:s -c:v copy -c:a aac -b:a 128k -c:s copy \
  -metadata:s:s:0 language=eng -metadata:s:s:1 language=chi -metadata:s:s:1 title="简体中文" \
  -disposition:s:0 0 -disposition:s:1 default \
  -shortest "$OUT/subs-srt-ass.mkv"
# MP4 Timed Text
ff -i "$TMP/v-sdr-h264.mkv" -i "$TMP/a-20.wav" -i "$TMP/eng.srt" \
  -map 0:v -map 1:a -map 2:s -c:v copy -c:a aac -b:a 128k -c:s mov_text -metadata:s:s:0 language=eng \
  -shortest "$OUT/subs-movtext.mp4"

rm -rf "$TMP"
ls -lh "$OUT"
