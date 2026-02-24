# NewBi (B 站第三方 iOS 客户端 MVP)

## 实现概览
- iOS 16+，SwiftUI + MVVM。
- 仅客户端直连，解析公开网页内嵌 JSON（`__INITIAL_STATE__` / `__playinfo__`）。
- 功能：订阅管理、订阅聚合首页、全站搜索、视频详情、原生播放（`durl` + `dash` 本地代理合流）、观看历史。
- 播放解析失败仅提示错误，不回退网页播放器。

## 目录结构
- `Sources/NewBiCore`: 领域模型、协议、解析器、网络层、客户端实现、ViewModel。
- `Tests/NewBiCoreTests`: 关键路径单测与 HTML fixture。
- `NewBiApp`: iOS App 入口、页面、持久化实现（iOS17+ SwiftData / iOS16 文件存储回退）。
- `project.yml`: XcodeGen 配置。
- `Scripts/bootstrap.sh`: 生成 Xcode 工程脚本。

## 本地开发
1. 运行核心测试：
   ```bash
   swift test
   ```
2. 生成 iOS 工程：
   ```bash
   ./Scripts/bootstrap.sh
   ```
3. 在完整 Xcode 环境打开 `NewBi.xcodeproj` 运行。

## 说明
- 当前环境缺少完整 Xcode（仅命令行工具），因此无法在此直接执行 iOS 构建与模拟器运行。
- 解析逻辑基于公开网页结构，若页面结构变化，需要更新 `BiliPublicHTMLParser`。
