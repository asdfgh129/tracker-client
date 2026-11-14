#!/usr/bin/env bash
#
# 插件兼容性补丁（flutter pub get 之后运行）。
#
# 背景（docs/11 §3）：Flutter 3.47 的插件生态存在 compileSdk 不一致：
#   - amap_map 1.0.15 硬编码 compileSdkVersion 35，低于
#     flutter_plugin_android_lifecycle 的 36 → AAR 元数据检查失败。
#     该插件不使用 API 36 符号，压到 36 产物等价。
#   - permission_handler_android / traccar_client_sdk 需要 API 37 符号
#     （如 ACCESS_LOCAL_NETWORK），保持 37；SDK 37 平台需已安装
#     （部分渠道包名为 android-37.0，需改名为 android-37，见 tool/README）。
#
# 处理：只补 amap_map（35 → 36）。
# 注意：直接修改 pub cache，`flutter pub upgrade` 后需重跑本脚本。
# CI 在 pub get 后调用本脚本（见 .github/workflows/ci.yml）。

set -euo pipefail

if ! command -v flutter >/dev/null 2>&1; then
  echo "未找到 flutter" >&2
  exit 1
fi

# Windows：pub cache 默认在 %LOCALAPPDATA%\Pub\Cache；其它平台 ~/.pub-cache。
if [ -n "${LOCALAPPDATA:-}" ] && [ -d "$LOCALAPPDATA/Pub/Cache/hosted" ]; then
  # Git Bash 下 LOCALAPPDATA 是 Windows 路径（反斜杠），glob 需要转换。
  HOSTED="$(cygpath -u "$LOCALAPPDATA/Pub/Cache/hosted" 2>/dev/null || echo "$LOCALAPPDATA/Pub/Cache/hosted")"
else
  HOSTED="$(flutter pub cache dir 2>/dev/null || echo "$HOME/.pub-cache")/hosted"
fi

if [ ! -d "$HOSTED" ]; then
  echo "pub cache 不存在：$HOSTED" >&2
  exit 1
fi

patch_file() { # file, from, to, label
  local file="$1" from="$2" to="$3" label="$4"
  if [ ! -f "$file" ]; then
    echo "  · $label：文件不存在（$file），跳过"
    return 0
  fi
  if grep -q -- "$to" "$file" && ! grep -q -- "$from" "$file"; then
    echo "  ✓ $label：已是目标值"
    return 0
  fi
  sed -i.bak "s/$from/$to/" "$file" && rm -f "$file.bak"
  echo "  ✓ $label：已修补"
}

echo "==> 插件 compileSdk 对齐（35/37 → 36）"

for dir in "$HOSTED"/*/*/; do
  name="$(basename "$dir")"

  case "$name" in
    amap_map-*)
      for f in "$dir/android/build.gradle" "$dir/android/build.gradle.kts"; do
        [ -f "$f" ] && patch_file "$f" "compileSdkVersion 35" "compileSdkVersion 36" "$name"
      done
      ;;
  esac
done

echo "==> 完成"
