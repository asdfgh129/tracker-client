import Bugly
import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    registerBuglyChannel(with: engineBridge.pluginRegistry)
  }

  /// Bugly 崩溃上报桥（0.5.1）：仅同意隐私政策后由 Dart 调 init。
  ///
  /// 内联在 AppDelegate（而非独立 Swift 文件）以零改动 Xcode 工程文件。
  /// 撤回同意：iOS SDK 无 disable/反初始化 API —— Dart 侧立即停止上报
  /// （enabled=false）；原生崩溃自动上报随进程生命周期，属已知边界。
  private func registerBuglyChannel(with registry: FlutterPluginRegistry) {
    let registrar = registry.registrar(forPlugin: "BuglyReporter")
    let channel = FlutterMethodChannel(
      name: "observability/bugly",
      binaryMessenger: registrar.messenger()
    )
    channel.setMethodCallHandler { call, result in
      switch call.method {
      case "init":
        let args = call.arguments as? [String: Any] ?? [:]
        let appId = args["appId"] as? String ?? ""
        let debug = args["debug"] as? Bool ?? false
        let config = BuglyConfig()
        config.debugMode = debug
        config.reportLogLevel = .warning
        Bugly.start(withAppId: appId, config: config)
        result(true)
      case "close":
        // iOS SDK 无 disable API；Dart 侧 enabled=false 即停 Dart 异常上报。
        result(nil)
      case "reportError":
        let args = call.arguments as? [String: Any] ?? [:]
        let name = args["name"] as? String ?? "Error"
        let reason = args["reason"] as? String ?? ""
        let stack = (args["stack"] as? String ?? "")
          .split(separator: "\n")
          .map(String.init)
        Bugly.reportException(withName: name, reason: reason, callStack: stack)
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }
}
