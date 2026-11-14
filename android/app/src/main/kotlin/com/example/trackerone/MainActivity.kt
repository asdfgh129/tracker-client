package com.example.trackerone

import io.flutter.embedding.android.FlutterActivity

class MainActivity : FlutterActivity() {
    /// 关闭 Flutter 自动深链（docs/10 §7.1）：
    /// JPush 厂商通道点击会带 n_extra 参数，Flutter 3.29+ 的自动深链
    /// 会在冷启动时尝试用该参数路由，导致白屏。
    /// 深链统一由 app_links + DeepLinkHandler 处理。
    override fun shouldHandleDeeplinking(): Boolean = false
}
