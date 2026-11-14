import 'dart:convert';

/// 服务器档案（AUTH-01/02/03）。
///
/// 一个档案同时驱动 REST / WebSocket（[apiBaseUrl]）与位置上报（[reportUrl]）。
class ServerProfile {
  const ServerProfile({
    this.id,
    required this.name,
    required this.apiBaseUrl,
    required this.reportUrl,
    this.allowSelfSigned = false,
    this.allowInsecure = false,
    this.isDemo = false,
    this.isActive = false,
  });

  final int? id;
  final String name;
  final String apiBaseUrl;
  final String reportUrl;

  /// 仅在用户显式开启时允许自签名证书（docs/04 §10：默认强制 HTTPS）。
  final bool allowSelfSigned;

  /// H-3：明文 HTTP 与自签名证书是两件独立的事。
  /// 明文传输需要单独的知情确认（PIPL 要求敏感个人信息加密传输）。
  final bool allowInsecure;

  final bool isDemo;
  final bool isActive;

  /// WebSocket 地址：`wss://host/api/socket`。
  String get socketUrl {
    final uri = Uri.parse(apiBaseUrl);
    final scheme = uri.scheme == 'http' ? 'ws' : 'wss';
    return uri.replace(scheme: scheme, path: '/api/socket').toString();
  }

  ServerProfile copyWith({
    int? id,
    String? name,
    String? apiBaseUrl,
    String? reportUrl,
    bool? allowSelfSigned,
    bool? allowInsecure,
    bool? isDemo,
    bool? isActive,
  }) {
    return ServerProfile(
      id: id ?? this.id,
      name: name ?? this.name,
      apiBaseUrl: apiBaseUrl ?? this.apiBaseUrl,
      reportUrl: reportUrl ?? this.reportUrl,
      allowSelfSigned: allowSelfSigned ?? this.allowSelfSigned,
      allowInsecure: allowInsecure ?? this.allowInsecure,
      isDemo: isDemo ?? this.isDemo,
      isActive: isActive ?? this.isActive,
    );
  }

  /// 是否为不加密的明文连接（UI 需常驻风险提示）。
  bool get isInsecure =>
      Uri.tryParse(apiBaseUrl)?.scheme == 'http' ||
      Uri.tryParse(reportUrl)?.scheme == 'http';

  Map<String, dynamic> toJson() => {
        if (id != null) 'id': id,
        'name': name,
        'apiBaseUrl': apiBaseUrl,
        'reportUrl': reportUrl,
        'allowSelfSigned': allowSelfSigned,
        'allowInsecure': allowInsecure,
        'isDemo': isDemo,
      };

  factory ServerProfile.fromJson(Map<String, dynamic> json) => ServerProfile(
        id: json['id'] is int ? json['id'] as int : null,
        name: json['name']?.toString() ?? '',
        apiBaseUrl: json['apiBaseUrl']?.toString() ?? '',
        reportUrl: json['reportUrl']?.toString() ?? '',
        allowSelfSigned: json['allowSelfSigned'] == true,
        allowInsecure: json['allowInsecure'] == true,
        isDemo: json['isDemo'] == true,
      );

  @override
  bool operator ==(Object other) =>
      other is ServerProfile &&
      other.apiBaseUrl == apiBaseUrl &&
      other.reportUrl == reportUrl;

  @override
  int get hashCode => Object.hash(apiBaseUrl, reportUrl);
}

/// 地址推导失败。
class ServerAddressException implements Exception {
  const ServerAddressException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// 服务器地址推导（AUTH-02，docs/01 §3.1）。
abstract final class ServerAddressDeriver {
  /// 规则：
  /// 1. `https://host` → API 原值；上报 = `https://host:5055`；
  /// 2. `https://host:8082` → API 原值；上报 = `https://host:5055`；
  /// 3. 带路径（反向代理）→ API 保留路径；上报同 host + 5055；
  /// 4. `http://` 明文需要 [allowInsecure] 显式放行。
  static ServerProfile derive({
    required String input,
    String? name,
    bool allowSelfSigned = false,
    bool allowInsecure = false,
  }) {
    final trimmed = input.trim();
    if (trimmed.isEmpty) {
      throw const ServerAddressException('请输入服务器地址');
    }
    final withScheme =
        trimmed.contains('://') ? trimmed : 'https://$trimmed';
    final Uri uri;
    try {
      uri = Uri.parse(withScheme);
    } on FormatException {
      throw ServerAddressException('地址格式不正确：$trimmed');
    }
    if (uri.host.isEmpty) {
      throw ServerAddressException('地址缺少主机名：$trimmed');
    }
    if (uri.scheme == 'http' && !allowInsecure) {
      throw const ServerAddressException('明文 HTTP 不安全，请使用 HTTPS；'
          '如确需使用，请在高级选项中确认风险');
    }
    if (uri.userInfo.isNotEmpty) {
      throw const ServerAddressException('地址中不应包含用户名密码');
    }

    final api = uri
        .removeFragment()
        .removeQueryParameters()
        .toString()
        .replaceAll(RegExp(r'[?#]+$'), '');

    // 上报地址：同 host，端口固定为 Traccar 默认的 5055。
    // 手工拼接而非 Uri.replace：后者会把空 query/fragment 序列化成 "?#"。
    final reportAuthority = uri.hasPort
        ? '${uri.host}:5055'
        : '${uri.host}:5055';
    final report = '${uri.scheme}://$reportAuthority';

    return ServerProfile(
      name: (name == null || name.isEmpty) ? uri.host : name,
      apiBaseUrl: api,
      reportUrl: report,
      allowSelfSigned: allowSelfSigned,
    );
  }

  /// M-7：手工填写的单个 URL 校验（API 或上报地址）。
  ///
  /// 与 [derive] 相同的 scheme / host / userInfo 规则，返回规范化字符串。
  static String validateManualUrl(
    String input, {
    required bool allowInsecure,
  }) {
    final trimmed = input.trim();
    if (trimmed.isEmpty) {
      throw const ServerAddressException('地址不能为空');
    }
    final hasScheme = trimmed.contains('://');
    final uri = Uri.tryParse(hasScheme ? trimmed : 'https://$trimmed');
    if (uri == null || uri.host.isEmpty) {
      throw ServerAddressException('地址格式不正确：$trimmed');
    }
    if (uri.scheme != 'http' && uri.scheme != 'https') {
      throw ServerAddressException('仅支持 http/https，收到 ${uri.scheme}');
    }
    if (uri.scheme == 'http' && !allowInsecure) {
      throw const ServerAddressException(
        '明文 HTTP 未加密。请改用 HTTPS；如确需使用，请勾选「允许明文 HTTP」并确认风险',
      );
    }
    if (uri.userInfo.isNotEmpty) {
      throw const ServerAddressException('地址中不应包含用户名密码');
    }
    return uri
        .removeFragment()
        .removeQueryParameters()
        .toString()
        .replaceAll(RegExp(r'[?#]+$'), '');
  }

  /// 二维码 / 深链解析（AUTH-03：URL 或 JSON 都能解析）。
  ///
  /// 支持：
  /// - Traccar Client 格式：`http(s)://host:5055?device=123456`
  /// - 深链格式：`trackerone://server?url=<encoded>`
  /// - JSON：`{"name":..., "apiBaseUrl":..., "reportUrl":...}`
  /// - 纯 URL（会走 [derive]）
  static ({ServerProfile profile, String? deviceUniqueId}) parseImport(
    String raw,
  ) {
    final text = raw.trim();
    if (text.isEmpty) {
      throw const ServerAddressException('二维码内容为空');
    }

    if (text.startsWith('{')) {
      try {
        final json = jsonDecode(text);
        if (json is Map<String, dynamic>) {
          if (json['apiBaseUrl'] is String) {
            // M-7：二维码/深链来源不可信 —— 不继承其 allowSelfSigned /
            // allowInsecure 请求，一律交由用户在表单中显式确认。
            final parsed = ServerProfile.fromJson(json);
            return (
              profile: parsed.copyWith(
                allowSelfSigned: false,
                allowInsecure: false,
              ),
              deviceUniqueId: json['uniqueId']?.toString(),
            );
          }
          // 允许只填 serverUrl 的最小 JSON。
          final serverUrl = json['serverUrl']?.toString() ??
              json['url']?.toString() ??
              json['server']?.toString();
          if (serverUrl != null && serverUrl.isNotEmpty) {
            // M-7：二维码来源不可信，但 Traccar 生态的 QR 常见 http://
            //（5055 上报端点）。处理方式：保留明文但**显式标记**
            // allowInsecure，UI 会以红色警示呈现，用户须自行确认 ——
            // 既不静默接受，也不打断正常导入。
            final profile = derive(
              input: serverUrl,
              name: json['name']?.toString(),
              allowInsecure: serverUrl.startsWith('http://'),
            );
            return (
              profile: profile,
              deviceUniqueId: json['uniqueId']?.toString() ??
                  json['device']?.toString(),
            );
          }
        }
      } on ServerAddressException {
        rethrow;
      } on FormatException {
        throw const ServerAddressException('无法解析二维码内容');
      }
      throw const ServerAddressException('二维码 JSON 缺少服务器地址');
    }

    // 深链：trackerone://server?url=...
    final deepLink = Uri.tryParse(text);
    if (deepLink != null &&
        deepLink.scheme == 'trackerone' &&
        deepLink.host == 'server') {
      final url = deepLink.queryParameters['url'];
      if (url == null || url.isEmpty) {
        throw const ServerAddressException('深链缺少 url 参数');
      }
      return _fromPlainUrl(url);
    }

    if (deepLink != null &&
        (deepLink.scheme == 'http' || deepLink.scheme == 'https')) {
      return _fromPlainUrl(text);
    }

    throw const ServerAddressException('无法识别的服务器地址格式');
  }

  static ({ServerProfile profile, String? deviceUniqueId}) _fromPlainUrl(
    String url,
  ) {
    final uri = Uri.tryParse(url);
    if (uri == null || !uri.hasScheme || uri.host.isEmpty) {
      throw ServerAddressException('地址格式不正确：$url');
    }
    final device = uri.queryParameters['device'] ?? uri.queryParameters['id'];
    // M-7：导入来源不可信。Traccar Client 的 QR 通常是 http://
    // （5055 上报端点），因此保留明文但**显式标记** allowInsecure ——
    // UI 以红色警示呈现，用户须确认；自签名永远不自动放行。
    final insecure = uri.scheme == 'http';
    final profile = ServerAddressDeriver.derive(
      input: url,
      allowInsecure: insecure,
    ).copyWith(allowInsecure: insecure);
    return (profile: profile, deviceUniqueId: device);
  }
}

extension _UriX on Uri {
  /// 去掉查询串。
  ///
  /// 注意：`Uri.replace` 不允许同时传 `query` 与 `queryParameters`。
  Uri removeQueryParameters() => replace(query: '');
}
