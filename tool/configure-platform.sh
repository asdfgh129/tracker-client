#!/usr/bin/env bash
#
# 平台配置自检与补齐（docs/10-setup-runbook.md 第 7 节）。
#
# 设计：**断言式**而非改写式 —— 默认只检查并报告缺失项，
# 不做危险的文本注入（避免把 AndroidManifest 改坏）。
# 需要自动补齐时用 APPLY=1（仅补齐缺失的简单项）。
#
# 用法：
#   tool/configure-platform.sh          # 自检（推荐，CI 也用它）
#   APPLY=1 tool/configure-platform.sh  # 补齐缺失项
#   PLATFORMS=android tool/configure-platform.sh

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

APPLY="${APPLY:-0}"
PLATFORMS="${PLATFORMS:-android,ios}"
FAILED=0

ok()   { printf '  ✓ %s\n' "$*"; }
miss() { printf '  ✗ %s\n' "$*"; FAILED=$((FAILED+1)); }
info() { printf '  · %s\n' "$*"; }

check_contains() { # file pattern description
  if grep -q -- "$2" "$1" 2>/dev/null; then ok "$3"; else miss "$3（缺少：$2）"; fi
}

#############################
# Android
#############################
if [[ "$PLATFORMS" == *android* ]]; then
  echo "==> Android"

  MANIFEST="android/app/src/main/AndroidManifest.xml"
  GRADLE="android/app/build.gradle.kts"
  # 0.4.0 包名定稿后位于 com/trackerone/app（此前 stale 路径导致断言静默跳过）
  MAINACTIVITY="android/app/src/main/kotlin/com/trackerone/app/MainActivity.kt"
  PROGUARD="android/app/proguard-rules.pro"

  if [[ -f "$MANIFEST" ]]; then
    python -c "import xml.dom.minidom,sys; xml.dom.minidom.parse('$MANIFEST')" 2>/dev/null \
      && ok "AndroidManifest.xml 是合法 XML" \
      || miss "AndroidManifest.xml 解析失败"

    for perm in ACCESS_FINE_LOCATION ACCESS_BACKGROUND_LOCATION ACTIVITY_RECOGNITION \
                FOREGROUND_SERVICE_LOCATION POST_NOTIFICATIONS RECEIVE_BOOT_COMPLETED \
                USE_BIOMETRIC CAMERA; do
      check_contains "$MANIFEST" "$perm" "权限 $perm"
    done

    check_contains "$MANIFEST" 'allowNativeHeapPointerTagging="false"' "高德 heap tagging 修复"
    check_contains "$MANIFEST" 'flutter_deeplinking_enabled' "关闭 Flutter 自动深链（JPush 白屏修复）"
    check_contains "$MANIFEST" 'android:scheme="trackerone"' "深链 scheme trackerone://"

    # 合规红线：不应出现与功能无关的敏感权限
    if grep -qE "READ_CONTACTS|READ_SMS|READ_CALL_LOG|QUERY_ALL_PACKAGES|READ_PHONE_STATE" "$MANIFEST" 2>/dev/null; then
      miss "存在与功能无关的敏感权限（最小必要原则，商店会驳回）"
    else
      ok "无多余敏感权限（通讯录/短信/通话/手机状态/全量应用列表）"
    fi
  else
    info "未找到 $MANIFEST（未生成平台工程，先跑 tool/bootstrap.sh）"
  fi

  [[ -f "$GRADLE" ]] && {
    check_contains "$GRADLE" 'minSdk = 24' "minSdk = 24（Android 7.0）"
    check_contains "$GRADLE" 'compileSdk = 37' "compileSdk = 37（permission_handler 14.x 要求）"
    check_contains "$GRADLE" 'isCoreLibraryDesugaringEnabled = true' "core library desugaring"
    check_contains "$GRADLE" 'desugar_jdk_libs' "desugar_jdk_libs 依赖"
    check_contains "$GRADLE" 'JPUSH_APPKEY' "JPush manifestPlaceholder 占位"
    check_contains "$GRADLE" 'com.tencent.bugly' "Bugly 崩溃上报依赖（0.5.1）"
    check_contains "$GRADLE" 'proguard-rules.pro' "release 混淆规则"
  }

  [[ -f "$PROGUARD" ]] && check_contains "$PROGUARD" 'cn.jpush' "ProGuard 保留极光/厂商通道"
  [[ -f "$PROGUARD" ]] && check_contains "$PROGUARD" 'com.tencent.bugly' "ProGuard 保留 Bugly"

  [[ -f "$MAINACTIVITY" ]] \
    && check_contains "$MAINACTIVITY" 'shouldHandleDeeplinking' "MainActivity 关闭自动深链"
  [[ -f "$MAINACTIVITY" ]] \
    && check_contains "$MAINACTIVITY" 'observability/bugly' "MainActivity Bugly 崩溃上报桥"
fi

#############################
# iOS
#############################
if [[ "$PLATFORMS" == *ios* ]]; then
  echo "==> iOS"

  PLIST="ios/Runner/Info.plist"
  PODFILE="ios/Podfile"

  if [[ -f "$PLIST" ]]; then
    python - "$PLIST" <<'PY' && ok "Info.plist 解析通过且无重复键" || miss "Info.plist 有问题"
import plistlib, sys
with open(sys.argv[1], 'rb') as f:
    d = plistlib.load(f)
required = [
    'NSLocationWhenInUseUsageDescription',
    'NSLocationAlwaysAndWhenInUseUsageDescription',
    'NSMotionUsageDescription',
    'NSFaceIDUsageDescription',
    'UIBackgroundModes',
    'BGTaskSchedulerPermittedIdentifiers',
    'CFBundleURLTypes',
]
missing = [k for k in required if k not in d]
if missing:
    print('    缺少：' + ', '.join(missing))
    sys.exit(1)
modes = d['UIBackgroundModes']
if 'location' not in modes or 'remote-notification' not in modes:
    print('    UIBackgroundModes 缺少 location / remote-notification')
    sys.exit(1)
schemes = []
for entry in d['CFBundleURLTypes']:
    schemes += entry.get('CFBundleURLSchemes', [])
if 'trackerone' not in schemes:
    print('    CFBundleURLTypes 缺少 trackerone scheme')
    sys.exit(1)
PY
  else
    info "未找到 $PLIST"
  fi

  [[ -f "$PODFILE" ]] && check_contains "$PODFILE" "platform :ios, '15.0'" "Podfile iOS 15"
  [[ -f "$PODFILE" ]] && check_contains "$PODFILE" "pod 'Bugly'" "Podfile Bugly 崩溃上报（0.5.1）"
fi

#############################
# 汇总
#############################
echo ""
if [[ "$FAILED" -eq 0 ]]; then
  echo "✓ 平台配置自检通过。"
  echo ""
  echo "仍需在 Xcode 手工完成（无法脚本化）："
  echo "  · Runner → Signing & Capabilities → Push Notifications"
  echo "  · Runner → Background Modes → Location updates / Background fetch / Remote notifications"
  echo ""
  echo "Android 发布签名：在 android/gradle.properties 或 CI 环境设置"
  echo "  JPUSH_APPKEY / JPUSH_CHANNEL，并用正式 keystore 替换 debug 签名。"
else
  echo "✗ 有 $FAILED 项未通过。参考 docs/10-setup-runbook.md 第 7 节。" >&2
  exit 1
fi
