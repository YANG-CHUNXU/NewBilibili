# NewBi

一个面向 iOS 的 B 站第三方客户端 MVP，目标是验证「公开页面解析 + 原生播放器」这条最小可行链路。

## 特性

- iOS 16+，SwiftUI + MVVM 架构。
- 订阅管理：支持输入 UID 或空间链接添加订阅。
- 订阅聚合：首页拉取已订阅 UP 主最新视频。
- 搜索：关键词搜索，支持第 1~3 页。
- 视频详情：标题、UP、分 P、公开统计数据。
- 原生播放：支持 `durl` 与 `dash`，包含多路回退与兼容性重试策略。
- 观看历史：记录最近播放项与进度秒数，可一键清空。
- 登录态导入：在「订阅」页导入 `SESSDATA`，用于提升公开接口可用性。

## 技术实现

### 数据来源

- 优先解析公开网页内嵌 JSON（如 `__INITIAL_STATE__` / `__playinfo__`）。
- 关键场景具备公开 API 回退（如搜索、订阅、播放地址）。
- 请求层会自动注入必要的 `Referer` / `Origin` / `User-Agent`。

### 播放策略

- 优先可被 AVFoundation 直接消费的流（优先规避 `flv/f4v`）。
- 对 `dash` 轨道按编码兼容性排序（优先 AVC），并提供多档清晰度切换。
- 播放失败时按策略自动重试（切备用 URL、降清晰度、禁用外置音频、代理兜底）。
- 失败后展示可读错误码与技术细节，不回退网页播放器。

### 持久化

- 默认：文件存储（`Application Support/NewBi/subscriptions.json`、`history.json`）。
- 可选：iOS 17+ 通过环境变量 `NEWBI_ENABLE_SWIFTDATA=1` 启用 SwiftData。
- `SESSDATA` 使用 Keychain 存储（`kSecAttrAccessibleWhenUnlockedThisDeviceOnly`）。

## 项目结构

- `NewBiApp/`：iOS 应用层（入口、页面、环境装配、持久化实现）。
- `Sources/NewBiCore/`：核心模块（模型、协议、网络、解析器、客户端、ViewModel）。
- `Tests/NewBiCoreTests/`：核心测试与 HTML Fixtures。
- `project.yml`：XcodeGen 工程描述。
- `Scripts/bootstrap.sh`：生成 Xcode 工程脚本。
- `Scripts/manual_acceptance_checklist.md`：手工验收清单。

## 环境要求

- macOS（推荐使用完整 Xcode 环境）。
- XcodeGen（用于从 `project.yml` 生成工程）。
- iOS 16+ 模拟器或真机。

安装 XcodeGen：

```bash
brew install xcodegen
```

## 快速开始

1. 生成 Xcode 工程

```bash
./Scripts/bootstrap.sh
```

2. 打开并运行

- 打开 `NewBi.xcodeproj`
- 选择 `NewBi` Scheme
- 选择 iOS 模拟器后运行

3. （可选）启用 SwiftData

- 在 Scheme -> Run -> Arguments -> Environment Variables 中添加：
  - `NEWBI_ENABLE_SWIFTDATA=1`

## 测试

```bash
swift test
```

说明：

- 在完整 Xcode / XCTest 运行时环境下可执行。
- 若当前机器仅安装精简命令行工具，可能出现 `no such module 'XCTest'`。

## 使用说明（MVP）

1. 进入「订阅」页，添加 UID 或空间链接。
2. （可选）在同页导入 `SESSDATA`。
3. 前往「首页」点击刷新查看聚合视频。
4. 进入详情后选择分 P 播放。
5. 返回「订阅」页查看观看历史。

## 已知限制

- 解析依赖 B 站公开页面结构；若页面改版，解析器需要同步更新。
- 公开接口可能触发频控/风控，已实现部分回退，但不保证所有场景稳定可用。
- 当前为 MVP，尚未覆盖登录体系、互动能力、弹幕、离线缓存等完整能力。

## 开发命令速查

```bash
# 生成 Xcode 工程
./Scripts/bootstrap.sh

# 运行核心测试
swift test
```
