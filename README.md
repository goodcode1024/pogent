# pogent

**口袋里的全能手机智能体。iOS 27 起，只有一条路。**

pogent 把两个开源项目合成一个 App：

| 来源 | 拿过来的东西 |
| --- | --- |
| [Poki](https://github.com/JosssphZhou/poki) | `look` / `do` 的读屏与点按、元素稳定编号、例程、分级审批、锁屏与交接、任务状态岛 |
| [Fish Pocket](https://github.com/imsai-sh/fish-pocket) | App 内的 agent 引擎（Node / Python / Git / FFmpeg）、本机系统能力、Bot 团队、插件市场、工作台、远程会话 |

合起来之后多了三样两边都没有的东西：**三级能力路由**、**任务编译成技能**、**统一审批与可回放审计**。

---

## 为什么只支持 iOS 27

iOS 27 之前，操控手机要靠 XCTest 会话 + WebDriverAgent，还要一条 `10.7.0.1` 的回环隧道和 VPN 才能让 App 访问自己的 runner；装 App 要靠电脑、每 7 天重签；Fish Pocket 那边的操控则要侧载第三方 iCTRL。

iOS 27 有了原生自动化服务，这些前置条件全部消失。pogent 只保留这一条路径，因此：

- 部署目标 `iOS 27.0`，工程里没有一处 `#available` 回退；
- 没有 `PokiTunnel`、没有 WDA、没有 Mac/Windows 安装器；
- 没有「开发者模式」「信任企业证书」「每周续签」这类设置项；
- 没有 WebView 套壳的官方 Web UI。

删除清单与理由见 [`../pogent-设计与迁移方案.md`](../pogent-设计与迁移方案.md)。

---

## 目录

```
pogent/
├── project.yml                 XcodeGen 工程定义（App + Widget Extension）
├── Shared/                     App 与扩展共用的 ActivityAttributes
├── Support/                    Info.plist / entitlements
└── Sources/
    ├── App/                    入口、依赖装配、主题、Tab
    ├── Core/
    │   ├── Agent/              Tool 协议、注册表、运行时循环、能力路由、技能编译
    │   ├── Device/             屏幕快照、动作、iOS 27 传输层、演示传输层
    │   ├── Native/             日历、提醒、通讯录、健康、照片、地图、家庭、消息…
    │   ├── Dev/                终端、文件、git、ffmpeg
    │   ├── Web/                抓网页、内置浏览器
    │   ├── Runtime/            内嵌运行时与 shell
    │   ├── Model/              端侧模型、OpenAI 兼容、Keychain
    │   ├── Policy/             审批引擎、审计账本、Live Activity
    │   ├── Bots/               Bot 团队与定时任务
    │   ├── Remote/             远程会话
    │   ├── Plugins/            JS 插件运行时与市场
    │   └── Persistence/        SwiftData 模型
    ├── Features/               对话、操控、工作台、Bot、市场、设置、引导
    ├── Platform/               App Intents / 快捷指令
    └── Widgets/                小组件与灵动岛
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

这是一个可读、可运行结构完整的工程骨架：数据模型、工具、运行时循环、审批、审计、UI 都已接好。但本仓库**没有在 Xcode 里编译过**（生成环境没有 Xcode），首次构建可能需要处理少量签名与 SDK 细节。

## 许可证

代码以 MIT 发布。Poki 是 AGPL-3.0，Fish Pocket 的引擎与第三方组件各有许可证；如果你把它们的代码或二进制并入分发，请按各自的许可证处理。
