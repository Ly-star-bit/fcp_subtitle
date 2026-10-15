# fcp-subtitle

给 Final Cut Pro 剪辑师的本地字幕生成工具：音频/视频 → 几秒后生成 `.fcpxml` → 拖进 FCP 就是一条条**可编辑的 Basic Title 字幕**（不是样式锁死的 SRT 封闭式字幕），可以批量改字体、描边、加动画。

- **全程本地离线**：SenseVoice 识别 + Silero VAD 分段，经 [sherpa-onnx](https://github.com/k2-fsa/sherpa-onnx) 推理，素材不上传任何服务器
- **多语言**：中文、英语、粤语、日语、韩语（SenseVoice 支持范围）
- **帧精确**：时间码按分数帧生成，支持 23.976 / 24 / 25 / 29.97 / 30 / 50 / 59.94 / 60 fps；视频素材自动跟随自身的尺寸和帧率（含竖屏）

提供两种形态，按需选用：

| | GUI 应用（`gui/`） | Python CLI + Finder 右键 |
|---|---|---|
| 适合人群 | 剪辑师日常使用 | 喜欢命令行 / 需要脚本化 |
| 安装 | 一个 dmg，拖进应用程序即用 | `uv sync` + 下载模型 |
| 功能 | 批量拖拽、逐句试听校对、AI 查错别字、一键送进 FCP、时间轴预览、智能断句、6 种格式导出 | 单文件转换，参数可控 |
| 依赖 | 无（自包含） | ffmpeg、Python 3.12+ |

## 方式一：原生 GUI 应用

纯 Swift 编写的 macOS 应用（Apple Silicon）。主要功能：

- 批量拖入音频/视频，队列处理
- 识别结果逐句**试听校对**、查找替换、时间轴预览
- **智能断句**：按标点把长句拆成适合屏幕的短字幕
- **AI 校对错别字**（见下文）：接任意 OpenAI 格式的接口，专挑同音错字
- **一键发送到 FCP**：直接唤起 Final Cut Pro 的导入对话框，不用先存文件再手动找
- 导出 6 种格式：FCPXML（可编辑 Basic Title）/ SRT / WebVTT / ASS / LRC / 纯文本
- **纠错词典**：把反复出错的词存成规则，下次识别自动替换
- 合并、拆分、删除、全部替换、应用 AI 校对都能 ⌘Z 撤销；手改的字幕自动保存
- 应用内模型下载，支持代理与国内镜像
- 精简版 dmg（约 14MB，不含模型，首次启动时在「模型管理」里下载）与完整版 dmg（约 180MB，含模型开箱即用）

> **首次打开被拦？** 应用是 ad-hoc 签名、未经公证。macOS 15 及以上：先双击一次，再到「系统设置 → 隐私与安全性」底部点「仍要打开」（右键 →「打开」从 macOS 15 起已无效）；macOS 14：右键 →「打开」。

### 从源码构建

```bash
cd gui
./scripts/fetch_deps.sh        # 下载 sherpa-onnx + 微软官方 onnxruntime 到 gui/Vendor/(校验 SHA-256)
./scripts/test.sh              # 跑单元测试(只装了 Command Line Tools 也能跑)
./scripts/package_app.sh       # 构建并打包 → gui/dist/FCP字幕.dmg（含模型）
./scripts/package_app.sh --no-models   # 精简版 → gui/dist/FCP字幕-精简版.dmg
```

> `fetch_deps.sh` 默认走代理下载，可用 `FCP_SUBTITLE_PROXY` 环境变量覆盖（设为空串则直连）。onnxruntime 用微软官方包而不是 sherpa-onnx 自带的那份：后者在 Apple Silicon 上用不到 int8 点积指令，识别慢约 2.6 倍。`package_app.sh` 可用 `FCP_SUBTITLE_DIST` 指定输出目录。

### AI 校对错别字

SenseVoice 最常见的错误是同音字（「字母」听成「字幕」）。识别完成后点工具栏的 **AI 校对**，把字幕分批发给大模型检查，返回逐条修改建议——**勾选确认后才会应用，不会自动改**。

任何 OpenAI 格式的 `/chat/completions` 接口都能用：OpenAI 本体、DeepSeek、通义、Ollama、one-api 网关等。在弹窗的「接口设置」里填地址、API Key 和模型名，点**测试连接**验证后即可使用。

提示词限定模型只改同音错字、专名误写和明显的标点问题，明确禁止润色语气、改写句子、合并拆分行——时间轴不受任何影响。每条建议若能定位到具体词，可以直接「存为规则」写进纠错词典，以后识别到自动替换。

> API Key 存在应用的 UserDefaults 里（明文），仅本机使用。字幕文本会发送到你填的那个接口——这一步不是本地离线的，介意的话可以填本地 Ollama 地址。

## 方式二：Python CLI + Finder 右键菜单

### 首次安装（共 4 步，只需一次）

```bash
# 1. 系统依赖
brew install ffmpeg

# 2. Python 环境（项目目录下,需要 uv）
uv sync

# 3. 下载模型（SenseVoice ~228MB + Silero VAD ~630KB,存到 models/）
uv run python scripts/download_models.py

# 4. 生成并安装 Finder 右键菜单
uv run python automator/build_workflow.py
# 然后双击生成的 "SenseVoice 转 FCPXML.workflow",点"安装"
```

### 日常使用

**Finder 右键（推荐）**：选中音频/视频文件 → 右键 → 快速操作 → **SenseVoice 转 FCPXML**。同目录出现同名 `.fcpxml`。

**命令行**：

```bash
uv run fcp-subtitle 采访.wav                      # 默认 25fps
uv run fcp-subtitle 采访.m4a --fps 29.97          # 匹配工程帧率
uv run fcp-subtitle 素材.mp4 --font "苹方-简" --font-size 72 -o 字幕.fcpxml
```

全部参数：

| 参数 | 默认值 | 说明 |
|---|---|---|
| `-o, --output` | 输入同目录同名 | 输出 `.fcpxml` 路径 |
| `--fps` | `25` | 时间线帧率：`23.976` / `24` / `25` / `29.97` / `30` / `50` / `59.94` / `60` |
| `--font` | `PingFang SC` | 字幕字体 |
| `--font-size` | `60` | 字号 |
| `--width` / `--height` | `1920` / `1080` | 时间线分辨率 |
| `--provider` | `cpu` | 推理后端：`cpu` / `coreml` |

## 导入 FCP

FCP 中 **File > Import > XML**，选生成的 `.fcpxml`。会新建一个事件，时间线上每句字幕是独立的 Basic Title 片段：全选后复制粘贴到你的工程时间线，即可批量改字体/描边/加动画。

## 常见问题

- **右键跑完没反应？** 看日志 `/tmp/fcp_subtitle.log`。最常见原因是模型没下载或 ffmpeg 没装。
- **字幕和音频对不上？** 用 `--fps` 指定和你 FCP 工程一致的帧率（时间码按帧量化，帧率错了会有细微偏移）。
- **歌曲/带 BGM 素材识别差？** SenseVoice 面向语音训练，唱歌和重伴奏场景准确率会明显下降，建议先做人声分离（如 Demucs / UVR）再喂进来。
- **移动了项目目录？** 重新跑安装第 4 步（workflow 里写死了项目绝对路径）。

## 项目结构

```
src/fcp_subtitle/               Python CLI
  audio.py                      ffmpeg 转码 → 16kHz 单声道 PCM 流
  asr.py                        Silero VAD 分段(拿时间轴) + SenseVoice 识别(拿文字)
  fcpxml.py                     帧精确 FCPXML 生成(分数帧时间码 / gap 填充 / XML 转义)
  cli.py                        命令行入口
  _dylib_fix.py                 修复 sherpa-onnx 1.13.x macOS wheel 缺 onnxruntime dylib 的打包 bug
scripts/download_models.py      模型下载(一次性)
automator/build_workflow.py     生成 Finder 右键快速操作
gui/                            Swift GUI 应用
  Sources/FCPSubtitleCore/      核心库:解码 / 识别 / 断句 / FCPXML & SRT 生成
  Sources/FCPSubtitle/          SwiftUI 界面:批量队列 / 校对 / 预览 / 模型管理
  Sources/fcpsub-cli/           调试用命令行入口
  Tests/                        核心库单元测试(swift-testing)
  scripts/                      fetch_deps.sh(拉推理库) / test.sh(跑测试) / package_app.sh(打 dmg)
models/                         模型文件(gitignore,不入库)
```

## 技术要点

- 时间码用**分数帧**（如 `31/25s`）而非浮点秒——Apple FCPXML DTD 要求，浮点在非整数帧率下会累积漂移
- SenseVoice 本身不带逐句时间戳，时间轴来自 Silero VAD 的语音分段起止点
- Basic Title 的 effect UID 为 FCP 内置固定值，经多个真实导出文件交叉验证
