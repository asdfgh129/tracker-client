import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trackerone/domain/entities/models.dart';
import 'package:trackerone/features/devices/application/devices_controller.dart';

/// P2 回归：实时事件进料必须有上限且按 id 去重（长时间挂机不涨内存）。
void main() {
  DeviceEvent event(int id) =>
      DeviceEvent(id: id, deviceId: 1, type: 'alarm');

  test('absorb caps the feed at maxItems', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final notifier = container.read(eventsFeedProvider.notifier);

    notifier.absorb([for (var i = 0; i < 250; i++) event(i)]);

    final feed = container.read(eventsFeedProvider);
    expect(feed, hasLength(EventsFeedNotifier.maxItems));
    // 超出部分从尾部裁掉，只保留最近进料的前 200 条。
    expect(feed.first.id, 0);
    expect(feed.last.id, EventsFeedNotifier.maxItems - 1);
  });

  test('absorb deduplicates replayed event ids', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final notifier = container.read(eventsFeedProvider.notifier);

    notifier.absorb([event(1), event(2)]);
    notifier.absorb([event(2), event(3)]);

    final feed = container.read(eventsFeedProvider);
    expect(feed.map((e) => e.id), [3, 1, 2]);
  });
}
