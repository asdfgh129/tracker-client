/// 非 IO 平台的证书策略桩。
///
/// 本项目不目标 Web；此文件仅为分析与测试环境提供安全默认值：
/// 不放行任何证书错误。
void certificatePolicyHook(Object client, bool allow) {
  // 非 IO 平台不支持自签名策略；保持默认严格校验。
}
