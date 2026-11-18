# TClock

macOS 菜单栏时钟小工具：常驻菜单栏、无 Dock 图标 。时钟是一块可拖动到屏幕任意位置、也可贴四角的无边框浮层面板，支持数字时钟与机械指针表盘两种显示。全部设置即时生效并持久化。

- 技术栈：Swift 6 + SwiftUI + AppKit（纯 AppKit 启动入口）
- 仓库：https://github.com/wdkGitHub/TClock


## 安装

1. 从 GitHub Releases 下载 `TClock-<版本>.dmg`，拖入“应用程序”（Applications）。
2. 工程使用临时签名（`CODE_SIGN_IDENTITY="-"`），未做公证。首次打开可能需要：在“系统设置 › 隐私与安全性”中允许，或执行：

   ```bash
   xattr -dr com.apple.quarantine /Applications/TClock.app
   ```
