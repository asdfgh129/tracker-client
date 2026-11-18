import 'package:flutter_test/flutter_test.dart';
import 'package:trackerone/domain/failures.dart';
import 'package:trackerone/features/history/application/history_controller.dart';

void main() {
  final now = DateTime(2026, 11, 18, 10, 30);

  test('lastDays(7) covers seven whole days', () {
    final range = HistoryRange.lastDays(7, now: () => now);
    expect(range.from, DateTime(2026, 11, 12));
    expect(range.to, DateTime(2026, 11, 19));
  });

  test('long ranges are segmented into at most two-day chunks', () {
    final segments = HistoryRange.lastDays(7, now: () => now).segment();
    expect(segments, hasLength(4));
    for (final segment in segments) {
      expect(segment.span <= const Duration(days: 2), isTrue);
    }
    expect(segments.first.from, DateTime(2026, 11, 12));
    expect(segments.last.to, DateTime(2026, 11, 19));
  });

  test('custom range rejects end before start', () {
    expect(
      () => HistoryRange.custom(
        DateTime(2026, 11, 19),
        DateTime(2026, 11, 18),
      ),
      throwsA(isA<ConfigFailure>()),
    );
  });

  test('today and yesterday are disjoint single-day ranges', () {
    final today = HistoryRange.today(now: () => now);
    final yesterday = HistoryRange.yesterday(now: () => now);
    expect(today.from, DateTime(2026, 11, 18));
    expect(today.to, DateTime(2026, 11, 19));
    expect(yesterday.from, DateTime(2026, 11, 17));
    expect(yesterday.to, today.from);
  });
}
