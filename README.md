<p align="center">
  <img src="Resources/AppIcon-1024.png" width="128" height="128" alt="Codex Kimi Usage Bar 图标">
</p>

<h1 align="center">Codex Kimi Usage Bar</h1>

<p align="center">在 macOS 菜单栏和 Touch Bar 中查看 Codex 与 Kimi Code 的实时额度、重置时间和工作状态。</p>

<p align="center"><a href="README_EN.md">English</a> · <a href="CHANGELOG.md">更新记录</a> · <a href="docs/ARCHITECTURE.md">架构说明</a> · <a href="docs/PRIVACY.md">隐私说明</a></p>

> [!IMPORTANT]
> 这是一个面向个人使用的非官方社区项目，与 OpenAI、Kimi 或 Moonshot 没有隶属、赞助或背书关系。Codex 的本机 app-server 接口、Kimi Code 的额度接口以及 Touch Bar 常驻接口都可能随客户端或 macOS 更新而变化。

## 项目简介

Codex Kimi Usage Bar 是一个原生 macOS 菜单栏小工具，针对同时使用 Codex 和 Kimi Code 的用户设计。它不要求用户复制会话 Cookie，也不把额度服务包装成新的登录系统，而是读取本机已经登录的客户端状态，在一个轻量的菜单栏项目中集中展示：

- Codex 与 Kimi Code 的 5 小时额度；
- 服务实际返回的周、月或周期额度；
- 每个额度窗口的下一次重置时间；
- Codex、Kimi 是否正在处理任务的状态小灯；
- 可选的网络状态和 IP 属地国旗环；
- 带 Touch Bar 的 MacBook Pro 上的紧凑用量界面。

应用只运行一个本地进程，不依赖第三方 Swift 包，不创建后台守护进程，也不把提示词、对话内容或完整公网 IP 写入文件。

## 功能

### 菜单栏

- 使用本机已安装的官方 Codex、Kimi Code 应用图标。
- 图标旁显示工作状态小灯和 5 小时剩余百分比。
- 直接显示各服务下一次额度重置时间；若接口没有提供重置时间，则显示“未提供”。
- 展开菜单后可查看 5 小时、周/月额度进度条、积分或重置次数（以服务实际返回的数据为准）。
- 提供“刷新”、打开 Codex 官网、打开 Kimi Code 官网、设置和退出入口。
- 菜单栏图标大小、文字字号和后台同步间隔可在设置中调整。

### Touch Bar

Touch Bar 有两种可选布局，设置变更后即时生效：

1. **紧凑数字**：图标、状态灯、5 小时和周期额度数字集中排列。
2. **双行余量条**：每个服务显示图标、状态灯、两条余量条，以及 `5h:百分比 时间`、`周/月:百分比 日期`。

双行余量条长度可以在设置中调节为 60–110 pt，默认 94 pt；两组服务共用同一个长度。状态灯大小按布局分别支持 6–16.5 pt 和 6–25 pt，两组服务共用同一个尺寸。

点击 Touch Bar 上的 Codex 或 Kimi 图标，会打开对应桌面应用；如果应用已最小化，会恢复窗口并切到前台，不强制全屏。应用切换时复用现有 Touch Bar 内容，避免因切换而闪烁或重建。

### 工作状态灯

Codex 和 Kimi 各有一个小型状态灯：

- 绿色呼吸：正在处理任务；
- 黄色慢闪：等待用户批准或回答；
- 暗白：空闲；
- 红色：明确失败；
- 灰色空心：无法可靠判断；
- 任务完成时柔和彩虹轻闪约 3 秒，再回到待机状态。

系统启用“减少动态效果”时，动画自动退化为静态颜色；睡眠或 Touch Bar 关闭时停止动画。

### IP 属地状态环

可以在设置中打开或关闭 IP 属地状态环。打开后，Touch Bar 左侧显示一个圆形组件：

- 圆心显示由网络出口地区转换得到的 macOS 原生国旗 emoji；
- 外环表示网络状态，检测时轻微旋转，网络异常时改变颜色；
- 轻点圆环可以立即重新检测；
- 不显示、不保存具体公网 IP，只保留用于显示国旗的两位地区代码；
- 代理切换后，地区和国旗可能随出口网络变化。

这里使用的是系统自带的 Apple Color Emoji，不需要下载或打包第三方国旗图标库。

### 稳定性与恢复

- 设置入口统一到一个 SwiftUI 设置窗口，避免重复窗口和“需要关闭两次”的问题。
- 菜单栏齿轮关闭菜单后，会通过主线程兜底打开设置页，即使 macOS 没有触发菜单关闭回调也不会丢失入口。
- 登录、开盖和屏幕唤醒后会尝试恢复 Touch Bar 内容。
- Touch Bar 常驻功能不可用时，菜单栏额度显示仍可独立运行。

## 技术栈

- **语言与构建**：Swift 5.10、Swift Package Manager、macOS 14 SDK。
- **AppKit**：`NSStatusItem`、`NSMenu`、`NSWindow`、`NSTouchBar`、`NSWorkspace`，负责菜单栏、窗口、Touch Bar 和应用前台切换。
- **SwiftUI**：设置页、菜单栏展开内容和原生控件布局；通过 `NSHostingView` 嵌入 AppKit 菜单和 Touch Bar 周边 UI。
- **Combine**：把额度、活动状态、设置变化和菜单栏重绘绑定起来，避免手工轮询 UI。
- **Foundation / URLSession**：本地进程通信、Kimi Code 与 IP 属地请求、时间和数据解析。网络会话使用 ephemeral 配置，不使用持久 URL 缓存和 Cookie 存储。
- **Security**：使用 macOS 钥匙串保存用户主动输入的 Kimi Code API Key。
- **ServiceManagement**：使用 `SMAppService` 管理登录时自动启动。
- **QuartzCore / Core Animation**：绘制余量条、状态环和小灯动画，并在减少动态效果时关闭动画。
- **Objective-C runtime**：运行时探测并调用 Touch Bar 系统模态 selector；系统不支持时自动回退到公开 AppKit 路径。
- **第三方依赖**：无。

## 实现方式

### Codex 额度

应用定位本机 `codex` 可执行文件，启动：

```text
codex app-server --stdio
```

随后通过标准输入输出发送 newline-delimited JSON-RPC 请求 `account/rateLimits/read`，把响应转换为统一的 `UsageSnapshot`。应用只取计划、剩余比例、重置时间、积分和重置次数等额度字段，不读取对话正文。

### Kimi Code 额度

Kimi Code 优先使用应用钥匙串中的 API Key；没有 API Key 时读取本机 Kimi Code CLI 的登录凭证。应用调用 Kimi Code 官方额度接口，按本机区域选择 `api.kimi.com` 或 `api.kimi.ai`，同时兼容 5 小时、周、月 Code 和会员月总量等不同返回窗口。

如果本机 CLI 访问令牌过期，应用会在 CLI 凭证目录建立文件锁，按 Kimi Code 的 OAuth refresh 流程更新同一份凭证，避免与 CLI 并发刷新。请求超时或返回格式变化时，只显示错误，不终止菜单栏进程。

### 工作状态

- Codex：增量读取本机可访问的任务日志，只提取任务开始、完成、中断等生命周期标记。
- Kimi：读取 `event.session.work_changed` 等状态事件，区分工作中、等待处理和结束状态。
- 多会话按“等待 > 工作 > 最近结束状态”合并；云端、其他设备和无法访问的会话不会被伪造为可确定状态。
- 日志只在文件变动时重新解析，并用短暂合并和兜底检查降低开销。

### Touch Bar

普通应用 Touch Bar 使用公开的 `NSTouchBar` API。常驻显示则通过运行时探测 AppKit 的系统模态 selector，在 Codex 位于前台且系统支持时建立模态会话。系统控制条、手动重连和应用切换都复用同一个控制器，避免重复创建会话；左侧系统关闭入口不会作为应用内容显示。

## 数据与隐私

- Codex Usage：由本机 Codex app-server 读取；不保存 Cookie、访问令牌或对话内容。
- Kimi Code：API Key 仅保存于 macOS 钥匙串；CLI 凭证由 Kimi Code 自己管理，应用只在额度读取和续期所需范围内使用。
- IP 属地：通过网络检测服务取得地区代码，只保留地区代码用于显示国旗和状态，不保存具体 IP。
- 设置：使用 `UserDefaults` 保存界面偏好、Touch Bar 布局、刷新间隔和开关状态。
- 网络：Kimi Code 额度和 IP 属地功能会发起相应的 HTTPS 请求；额度请求使用无持久缓存、无 Cookie 的 URLSession。
- 应用不包含遥测、广告、崩溃分析 SDK 或第三方统计服务。

详见 [隐私说明](docs/PRIVACY.md)。

## 系统要求

- macOS 14.0 或更高版本。
- 已安装并登录 Codex 桌面客户端。
- 若要读取 Kimi Code 额度，需要已登录 Kimi Code，或在设置中保存有效 API Key。
- Touch Bar 功能需要带 Touch Bar 的 MacBook Pro；其他 Mac 仍可使用菜单栏功能。

## 从源码构建

```bash
git clone https://github.com/adityajha2005/codex-usage-bar.git
cd codex-usage-bar
./build-app.sh dist
open "dist/Codex Kimi Usage Bar.app"
```

默认 `build-app.sh` 构建 `arm64` 与 `x86_64` 通用包。只构建当前架构：

```bash
CODEX_USAGE_ARCHS="$(uname -m)" ./build-app.sh dist
```

本机 Apple Silicon 开发环境也提供 `build-local.sh`，它使用已安装的 Swift 编译器和 macOS SDK：

```bash
./build-local.sh /tmp/codex-kimi-build
"/tmp/codex-kimi-build/Codex Kimi Usage Bar.app/Contents/MacOS/CodexUsageBar" --self-test
```

常用只读检查：

```bash
"Codex Kimi Usage Bar.app/Contents/MacOS/CodexUsageBar" --self-test
"Codex Kimi Usage Bar.app/Contents/MacOS/CodexUsageBar" --activity-status
"Codex Kimi Usage Bar.app/Contents/MacOS/CodexUsageBar" --ip-region-status
codesign --verify --deep --strict "Codex Kimi Usage Bar.app"
```

## 仓库结构

```text
Sources/CodexUsageBar/
├── main.swift                # 数据模型、客户端、菜单栏、设置和 Touch Bar 控制器
├── AppLauncher.swift         # 打开并激活 Codex / Kimi Code
├── TouchBarLayout.swift      # 两种布局、余量条和共享颜色规则
├── WorkActivity.swift        # 本地任务状态读取与合并
├── WorkStatusLightView.swift # 状态灯绘制和动画
└── IPRegionIndicator.swift   # 地区国旗和网络状态环
Resources/                    # 应用图标与资源
docs/                         # 架构、隐私和 Touch Bar 说明
```

## 已知限制

- Codex app-server 不是面向第三方应用承诺稳定性的公开 SDK，接口变化可能影响额度读取。
- Kimi Code 的额度字段会随套餐变化；应用只显示实际返回的窗口，不补造缺失数据。
- Touch Bar 常驻依赖未公开 AppKit selector，不适合提交 Mac App Store，macOS 更新后可能需要适配。
- 系统或硬件层面的 Touch Bar 黑屏、自动调暗和睡眠行为不由应用控制。
- 本项目不替代 Codex 或 Kimi Code 官方客户端，也不保证云端或其他设备的工作状态可见。

## 许可证

代码和原创项目资源采用 [MIT License](LICENSE)。商标及非官方项目说明见 [NOTICE.md](NOTICE.md)。
