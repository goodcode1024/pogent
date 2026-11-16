# pogent

**口袋里的全能手机智能体。iOS 27 起，只有一条路。**

pogent 把两个开源项目合成一个 App，并把两边缺的部分补齐：

| 来源 | 拿过来的东西 |
| --- | --- |
| [Poki](https://github.com/JosssphZhou/poki) | `look` / `do` 的读屏与点按、元素稳定编号、例程、分级审批、锁屏交接、状态岛 |
| [Fish Pocket](https://github.com/imsai-sh/fish-pocket) | App 内的 agent 引擎（Node / Python / Git / FFmpeg）、本机系统能力、Bot 团队、插件市场、工作台、远程会话 |

合起来之后多了三样两边都没有的东西：**三级能力路由**、**任务编译成技能**、**统一审批与可回放审计**。

---

## 装完就能用

这一点是这一版的重点：**不填任何 API Key，App 也能真的干活**。

| 有网络、有 Key | 只有端侧模型 | 什么都没有 |
| --- | --- | --- |
| 完整 agent 循环 + 40 个工具 | Apple 智能端侧模型 + 40 个工具 | 本机规则引擎 + 40 个工具 |

离线引擎认得出 40 多种说法，直接映射到工具并真的执行：定闹钟、倒计时、建提醒、加日程、查天气、算数、单位换算、读剪贴板、生成二维码、朗读、查电量、开关手电筒、调亮度、定位、找附近、导航、查联系人、放歌、看图识字、管文件、记忆。认不出就直说，不编答案。

---

## 40 个工具

| 层 | 工具 |
| --- | --- |
| **界面操控**（3） | `look` `do` `launch_app` |
| **系统能力**（24） | `calendar` `reminders` `contacts` `health` `photos` `maps` `music` `compose_message` `clipboard` `notify` `run_shortcut` `home` `speak` `transcribe` `ocr` `scan_code` `see` `device_info` `battery` `hardware` `authenticate` `clock` `location` `weather` |
| **本地工具**（2） | `utility`（算数/换算/日期/正则/JSON/编码/哈希/随机）`media_toolbox`（PDF/二维码/图片） |
| **智能体**（3） | `memory` `spawn_subagent` `connector`（GitHub/Notion/Webhook/RSS） |
| **本机运行时**（6） | `shell` `read_file` `write_file` `list_files` `git` `media` |
| **网页**（2） | `web_fetch` `browser` |

三层能力路由永远优先选**最可靠、最便宜、最可回放**的那一层：系统接口 → 本机命令 → 界面点按。

---

## 界面

六个 Tab，外加从能力中心进入的独立页面：

- **对话** — 计划模式（先出计划、确认后执行）、真实语音输入、消息朗读、会话列表（搜索/置顶/归档/导出）
- **能力** — 14 项本机能力的开关与权限申请、工具清单、六个快捷入口
- **操控** — 读屏镜像、例程、画面差异
- **工作台** — 终端、文件、浏览器
- **Bot** — 独立人设与记忆、群聊、定时
- **设置** — 模型、审批策略、语音、数据、关于

独立页面：语音对话、拍照识字（相机 / 相册 / 文档扫描）、文件浏览器、技能与审计与记忆、连接器。

---

## 为什么只支持 iOS 27

iOS 27 之前，操控手机要靠 XCTest 会话 + WebDriverAgent，还要一条 `10.7.0.1` 的回环隧道和 VPN 才能让 App 访问自己的 runner；装 App 要靠电脑、每 7 天重签；Fish Pocket 那边的操控则要侧载第三方 iCTRL。

iOS 27 有了原生自动化服务，这些前置条件全部消失。pogent 只保留这一条路径，因此：

- 部署目标 `iOS 27.0`，工程里没有一处为旧系统写的 `#available` 回退；
- 没有 `PokiTunnel`、没有 WDA、没有 Mac/Windows 安装器；
- 没有「开发者模式」「信任企业证书」「每周续签」这类设置项；
- 没有 WebView 套壳的官方 Web UI。

删除清单与理由见 [`../pogent-设计与迁移方案.md`](../pogent-设计与迁移方案.md)。

---

## 目录

```
pogent/
├── project.yml                 XcodeGen 工程定义（App + Widget Extension）
├── Shared/                     App 与扩展共用：ActivityAttributes、控制中心 Intent
├── Support/                    Info.plist / entitlements / Assets.xcassets
└── Sources/
    ├── App/                    入口、依赖装配、主题、Tab
    ├── Core/
    │   ├── Agent/              Tool 协议、注册表、运行时、能力路由、技能、离线引擎、子智能体
    │   ├── Device/             屏幕快照、动作、iOS 27 传输层、演示传输层
    │   ├── Native/             权限中心、日历、健康、语音、视觉、设备、时间、位置、天气
    │   ├── Toolbox/            算数/换算/编码/PDF/二维码/图片
    │   ├── Connectors/         GitHub / Notion / Webhook / RSS
    │   ├── Dev/                终端、文件、git、ffmpeg
    │   ├── Web/                抓网页、内置浏览器
    │   ├── Runtime/            内嵌运行时与 shell
    │   ├── Model/              端侧模型、OpenAI 兼容、Keychain
    │   ├── Policy/             审批引擎、审计账本、Live Activity
    │   ├── Bots/               Bot 团队与定时任务
    │   ├── Remote/             远程会话
    │   ├── Plugins/            JS 插件运行时与市场
    │   └── Persistence/        SwiftData：会话、消息、运行、Bot、技能、插件、记忆、连接器、能力
    ├── Features/               对话、能力、操控、工作台、Bot、市场、设置、引导、文件、库
    ├── Platform/               App Intents / 快捷指令
    └── Widgets/                小组件、灵动岛、控制中心控件
```

## 构建

```bash
brew install xcodegen
cd pogent
xcodegen generate
open Pogent.xcodeproj
```

要求 **Xcode 27 / iOS 27 SDK**。签名前把 `project.yml` 里的 bundle id 换成你自己的。

内嵌的 Node 24、Python 3.15、libgit2、FFmpeg 不随仓库分发。需要时把对应 `.framework` 放进 `Frameworks/`，`RuntimeDescriptor` 会自动识别；没有也不影响 App 启动，文件与终端仍有内置的 bash 子集可用。

## 唯一的接入点

`SystemAutomationTransport.send(_:)` 是系统自动化服务的出入口。当前实现会抛 `AutomationError.unavailable`，演示环境用 `DemoAutomationTransport` 顶替。把它换成真实的系统调用（XPC 或系统框架），整条读屏 / 点按链路就活了。

## 状态

- 40 个工具、9 张数据表、6 个 Tab、10 个独立页面。
- 已在 GitHub Actions（macOS runner + Xcode 26.x）真实编译并产出未签名 IPA。
- 产物最低系统为 26.0：runner 上没有 iOS 27 SDK 时会自动下调部署目标。要产出严格 27 的包，需要装有 Xcode 27 的机器。

## 许可证

代码以 MIT 发布。Poki 是 AGPL-3.0，Fish Pocket 的引擎与第三方组件各有许可证；如果你把它们的代码或二进制并入分发，请按各自的许可证处理。
