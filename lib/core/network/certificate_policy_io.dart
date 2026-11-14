import 'dart:io';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';

/// IO 平台实现：按档案配置放行自签名证书（仅用户显式开启时调用）。
///
/// 安全说明（docs/04 §10）：默认强制 HTTPS 证书校验；放行仅作用于该档案
/// 的 Dio 实例，并需要在 UI 上提示风险。
void certificatePolicyHook(Dio client, bool allow) {
  if (!allow) return;
  final adapter = client.httpClientAdapter;
  if (adapter is IOHttpClientAdapter) {
    adapter.createHttpClient = () {
      final httpClient = HttpClient();
      httpClient.badCertificateCallback = (cert, host, port) => true;
      return httpClient;
    };
  }
}
