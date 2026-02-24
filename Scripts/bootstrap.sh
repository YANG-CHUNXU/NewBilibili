#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

if ! command -v xcodegen >/dev/null 2>&1; then
  echo "xcodegen 未安装，请先执行: brew install xcodegen"
  exit 1
fi

xcodegen generate

echo "已生成 /Users/ycx/Develop/NewBi/NewBi.xcodeproj"
echo "下一步：在有完整 Xcode 的环境中打开工程并运行 iOS 模拟器。"
