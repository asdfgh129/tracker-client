import 'package:flutter_test/flutter_test.dart';
import 'package:trackerone/domain/failures.dart';
import 'package:trackerone/features/auth/application/session_controller.dart';

/// P1 回归：离线只读会话不得放行任何 API 调用（写操作尤其）。
void main() {
  test('readOnly session rejects api() access', () {
    const state = SessionState(
      phase: SessionPhase.anonymous,
      offline: true,
      readOnly: true,
    );
    expect(() => state.api(), throwsA(isA<UnauthorizedFailure>()));
  });
}
