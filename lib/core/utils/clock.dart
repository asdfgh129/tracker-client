/// 时间抽象（docs/03 §16 可测试性设计）。
///
/// 业务代码不要直接调用 `DateTime.now()`，统一注入 [Clock]，
/// 测试时用 [FixedClock] 驱动，避免时间相关逻辑的脆测试。
abstract interface class Clock {
  DateTime now();
}

/// 生产实现。
class SystemClock implements Clock {
  const SystemClock();

  @override
  DateTime now() => DateTime.now().toUtc();
}

/// 固定时钟，测试用。
class FixedClock implements Clock {
  FixedClock(DateTime initial) : _now = initial;

  DateTime _now;

  @override
  DateTime now() => _now;

  /// 测试中直接设定当前时间。
  void set(DateTime value) => _now = value;

  void advance(Duration duration) => _now = _now.add(duration);
}

/// 简易节流器：用于「周期刷新 UI」而不是无脑 Timer。
///
/// 非线程安全（Dart 单线程模型内使用）。
class Throttle {
  Throttle(this.interval, {Clock? clock}) : _clock = clock ?? const SystemClock();

  final Duration interval;
  final Clock _clock;
  DateTime? _last;

  /// 距上次放行是否已超过间隔。
  bool get ready {
    final last = _last;
    return last == null || _clock.now().difference(last) >= interval;
  }

  /// 若允许则记录本次并返回 true。
  bool tryFire() {
    if (!ready) return false;
    _last = _clock.now();
    return true;
  }
}
