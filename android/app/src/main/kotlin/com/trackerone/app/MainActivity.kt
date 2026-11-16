package com.trackerone.app

import com.tencent.bugly.crashreport.CrashReport
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    /// 关闭 Flutter 自动深链（docs/10 §7.1）：
    /// JPush 厂商通道点击会带 n_extra 参数，Flutter 3.29+ 的自动深链
    /// 会在冷启动时尝试用该参数路由，导致白屏。
    /// 深链统一由 app_links + DeepLinkHandler 处理。
    override fun shouldHandleDeeplinking(): Boolean = false

    /// Bugly 崩溃上报桥（0.5.1）：仅同意隐私政策后由 Dart 调 init。
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "observability/bugly",
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "init" -> {
                    val appId = call.argument<String>("appId").orEmpty()
                    val debug = call.argument<Boolean>("debug") ?: false
                    try {
                        CrashReport.initCrashReport(applicationContext, appId, debug)
                        result.success(true)
                    } catch (error: Exception) {
                        // AppId 非法等场景：降级 noop，不阻断启动
                        android.util.Log.w("BuglyReporter", "init failed", error)
                        result.success(false)
                    }
                }
                "close" -> {
                    CrashReport.closeCrashReport()
                    result.success(null)
                }
                "reportError" -> {
                    val name = call.argument<String>("name") ?: "Error"
                    val reason = call.argument<String>("reason").orEmpty()
                    val stack = call.argument<String>("stack").orEmpty()
                    val fatal = call.argument<Boolean>("fatal") ?: false
                    // Bugly 无 fatal 标志：标注进消息文本，控制台可检索 [fatal]。
                    CrashReport.postCatchedException(
                        buildThrowable(name, reason, stack, fatal),
                    )
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }

    /** 把 Dart 栈帧文本解析成 Throwable（Bugly 只收 Java Throwable）。 */
    private fun buildThrowable(
        name: String,
        reason: String,
        stack: String,
        fatal: Boolean = false,
    ): Throwable {
        val prefix = if (fatal) "[fatal] " else ""
        val throwable = Throwable("$prefix$name: $reason")
        // 形如 `#1      Foo.bar (file:///...main.dart:42:5)`（列号可选；路径可能已被脱敏）。
        val framePattern = Regex("""#\d+\s+([^\s(]+)\s+\(([^)]*?\.dart):(\d+)(?::\d+)?""")
        val frames = stack.split('\n')
            .filter { it.isNotBlank() }
            .mapNotNull { line ->
                val match = framePattern.find(line) ?: return@mapNotNull null
                StackTraceElement(
                    "dart",
                    match.groupValues[1],
                    match.groupValues[2].substringAfterLast('/'),
                    match.groupValues[3].toIntOrNull() ?: 0,
                )
            }
        if (frames.isNotEmpty()) {
            throwable.stackTrace = frames.toTypedArray()
        }
        return throwable
    }
}
