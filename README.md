<p align="center">
  <img src="Apps/macOS/Assets.xcassets/AppIcon.appiconset/icon_256.png" width="128" height="128" alt="墨影 Noir 图标">
</p>

<h1 align="center">墨影 Noir</h1>

<p align="center">
  面向 Apple 平台的极简本地视频播放器，把 4K HDR 高码率片源原样、正确地播放出来。
</p>

<p align="center">
  <img src="https://img.shields.io/badge/macOS-15%2B-000000?logo=apple&logoColor=white" alt="macOS 15+">
  <img src="https://img.shields.io/badge/Swift-6-F05138?logo=swift&logoColor=white" alt="Swift 6">
  <img src="https://img.shields.io/badge/Apple%20Silicon-M2%2B-555555" alt="Apple Silicon M2+">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-blue" alt="MIT License"></a>
</p>

## 特性

- **原画质 HDR**：VideoToolbox 硬件解码，HDR10 / HLG 经 EDR 输出，色域、传输函数与 HDR 静态元数据完整传递
- **无损多声道**：TrueHD、DTS-HD MA 软解为多声道 LPCM，声道位置严格对应；AC3 / E-AC3 交给系统处理
- **字幕**：内封 PGS、SRT、ASS、Timed Text；自动加载同名外挂字幕，识别 GBK / Big5 编码，默认选择中文
- **精确跳转**：落点精确到目标帧，音画同步
- **极简界面**：播放时只有画面，控件按需浮现、自动隐藏；信息面板一键查看编码、动态范围与音频路径

## 平台状态

| 平台 | 状态 |
|---|---|
| macOS | 可用 |
| tvOS | 播放内核可编译，应用规划中 |
| iOS / iPadOS | 播放内核可编译，应用规划中 |

计划中：杜比视界、HTTP 与局域网播放、Apple TV 匹配内容与功放多声道输出。

## 环境要求

- Xcode 16.4，macOS 15 及以上
- 最低硬件：Apple M2 Mac、Apple TV 4K（第三代，2022）
- 构建工具：[XcodeGen](https://github.com/yonaskolb/XcodeGen)；生成测试片源需带 libx265 与 libx264 的 ffmpeg

## 构建

```sh
scripts/build-ffmpeg.sh       # 构建 FFmpeg xcframework（macOS / tvOS / iOS）
scripts/make-test-media.sh    # 生成测试片源至 TestMedia/
xcodegen generate             # 生成 Noir.xcodeproj
open Noir.xcodeproj           # 运行 NoirMac
```

## 测试

```sh
cd Packages/NoirKit && swift test
```

测试依赖 `TestMedia/` 下的片源，需先执行 `scripts/make-test-media.sh`。

## 架构

解码与渲染优先使用系统能力，FFmpeg 仅用于解封装及系统不支持的音频格式。

| 环节 | 实现 |
|---|---|
| 数据读取 | `ByteSource` 抽象；FFmpeg 不启用任何协议，经自定义 `AVIOContext` 读取 |
| 解封装 | FFmpeg libavformat（MKV / MP4 / MOV） |
| 视频 | 压缩帧以零拷贝方式封装为 `CMSampleBuffer`，经 `VTDecompressionSession` 硬件解码并按显示顺序重排，保持数帧解码余量后交给 `AVSampleBufferVideoRenderer` 按时送显，输出 HDR / EDR |
| 色彩 | 色域、传输函数、矩阵、母版显示信息与内容亮度写入格式描述；容器缺失时回退到 SPS VUI |
| 音频 · 直通 | AC3 / E-AC3 压缩码流提交系统渲染器，保留杜比全景声 |
| 音频 · AudioToolbox | AAC、FLAC、ALAC、MP3、单声道 / 立体声 Opus 解码为 LPCM |
| 音频 · FFmpeg | TrueHD、DTS 系列、多声道 Opus 解码为 LPCM |
| 字幕 | 内封 PGS 经 FFmpeg 解码为图像；SRT、ASS、Timed Text 自行解析，CoreText 渲染 ASS 常用样式；自动加载同名外挂 `.srt` / `.ass`，默认选择中文字幕 |
| 同步 | `AVSampleBufferRenderSynchronizer` 统一时钟；跳转时目标之前的帧仅解码不显示，音频按目标时间裁剪 |

FFmpeg 构建配置：matroska / mov 解封装；truehd、mlp、dca、opus、pgssub 解码器；所需 parser；swresample。

## 目录结构

```
Packages/NoirKit/            播放内核（Swift Package，macOS / tvOS / iOS 共用）
  Sources/NoirEngine/
    Source/                  数据源
    FFmpeg/                  解封装与 FFmpeg 桥接
    Video/                   视频格式描述、参数集解析、硬件解码
    Audio/                   音频解码与声道映射
    Media/                   CMSampleBuffer 构造
    Subtitle/                字幕解析、PGS 解码与渲染
    Playback/                播放会话与 PlayerController
    Model/                   媒体信息与播放统计
  Tests/NoirEngineTests/     单元测试与集成测试
Apps/macOS/                  macOS 应用（SwiftUI）
scripts/                     FFmpeg 构建、测试片源生成
project.yml                  XcodeGen 工程配置
```

## 使用（macOS）

打开文件：拖入窗口，或按 ⌘O。外挂字幕可直接拖入窗口加载。

沙盒下应用只能读取用户选择的文件。如需自动加载同名外挂字幕（如 `电影.chs.ass`），在字幕菜单中选择「自动加载同名字幕…」并授权影片所在文件夹，授权会被保存。

### 快捷键

| 按键 | 功能 |
|---|---|
| 空格 | 播放 / 暂停 |
| ← / → | 后退 / 前进 10 秒 |
| S | 显示 / 隐藏字幕 |
| I | 信息面板 |
| F | 全屏 |
| ⌘O | 打开文件 |

## 许可证

本项目以 [MIT 许可证](LICENSE) 发布。

构建时静态链接 [FFmpeg](https://ffmpeg.org)（LGPL 2.1 或更高版本，未启用 GPL 组件）。仓库不包含 FFmpeg 源码与二进制，由 `scripts/build-ffmpeg.sh` 从官方下载构建；分发编译后的应用时需遵守 LGPL 的相应要求。
