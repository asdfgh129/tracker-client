import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'storage/database.dart';
import 'utils/clock.dart';

/// 应用级依赖注入（docs/03 §4：Provider 即依赖容器）。
///
/// 必须在 main() 中 override 的：
/// - [appDatabaseProvider]（drift 实例）
/// - [prefsProvider]（见 storage/preferences.dart）

final appDatabaseProvider = Provider<AppDatabase>((ref) {
  throw UnimplementedError('必须在 main() 中 override appDatabaseProvider');
});

final clockProvider = Provider<Clock>((ref) => const SystemClock());
