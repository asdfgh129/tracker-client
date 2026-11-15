import 'package:flutter_test/flutter_test.dart';
import 'package:trackerone/features/auth/application/session_controller.dart';

void main() {
  group('buildOpenIdAuthUrl（OIDC 授权入口）', () {
    test('points at openid/auth with encoded app redirect', () {
      final uri = buildOpenIdAuthUrl('https://track.example.com');

      expect(uri.scheme, 'https');
      expect(uri.host, 'track.example.com');
      expect(uri.path, '/api/session/openid/auth');
      expect(uri.queryParameters['redirect'], openIdAppRedirectUri);
    });

    test('keeps api base with port intact', () {
      final uri = buildOpenIdAuthUrl('http://192.168.1.10:8082');

      expect(uri.port, 8082);
      expect(uri.path, '/api/session/openid/auth');
      expect(uri.queryParameters['redirect'], 'trackerone://openid/callback');
    });
  });

  group('openIdCodeFromUri（回跳深链解析）', () {
    test('extracts one-time code from valid callback', () {
      final code = openIdCodeFromUri(
        Uri.parse('trackerone://openid/callback?code=Ab12Cd34Ef56Gh78Ij90'),
      );

      expect(code, 'Ab12Cd34Ef56Gh78Ij90');
    });

    test('rejects wrong scheme / host / path', () {
      expect(openIdCodeFromUri(Uri.parse('https://openid/callback?code=x')), isNull);
      expect(openIdCodeFromUri(Uri.parse('trackerone://other/callback?code=x')), isNull);
      expect(openIdCodeFromUri(Uri.parse('trackerone://openid/other?code=x')), isNull);
    });

    test('rejects missing or empty code', () {
      expect(openIdCodeFromUri(Uri.parse('trackerone://openid/callback')), isNull);
      expect(openIdCodeFromUri(Uri.parse('trackerone://openid/callback?code=')), isNull);
    });

    test('redirect target constant matches server whitelist', () {
      // 与 tracker-server OpenIdAppRedirect.APP_REDIRECT_URI 一致（审计要求）。
      expect(openIdAppRedirectUri, 'trackerone://openid/callback');
    });
  });
}
