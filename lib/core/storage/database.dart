import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

part 'database.g.dart';

/// 服务器档案（docs/03 §7.1）。
///
/// 一个档案同时描述 API 与上报入口；`isActive` 标记当前使用的档案。
@DataClassName('ServerProfileRow')
class ServerProfiles extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get name => text()();
  TextColumn get apiBaseUrl => text()();
  TextColumn get reportUrl => text()();
  BoolColumn get allowSelfSigned => boolean().withDefault(const Constant(false))();
  BoolColumn get allowInsecure => boolean().withDefault(const Constant(false))();
  BoolColumn get isDemo => boolean().withDefault(const Constant(false))();
  BoolColumn get isActive => boolean().withDefault(const Constant(false))();
  IntColumn get sortOrder => integer().withDefault(const Constant(0))();
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();
}

/// 设备缓存。
@DataClassName('DeviceRow')
class DeviceRows extends Table {
  IntColumn get id => integer()();
  IntColumn get serverId => integer()();

  @override
  Set<Column> get primaryKey => {serverId, id};

  TextColumn get uniqueId => text().nullable()();
  TextColumn get name => text().nullable()();
  TextColumn get category => text().nullable()();
  TextColumn get status => text().nullable()();
  IntColumn get lastUpdate => integer().nullable()();
  TextColumn get attributes => text().nullable()();
  TextColumn get raw => text().nullable()();
}

/// 位置缓存。保留 7 天；UNIQUE(serverId, deviceId, fixTime) 幂等。
@DataClassName('PositionRow')
class PositionRows extends Table {
  IntColumn get id => integer()();
  IntColumn get serverId => integer()();
  IntColumn get deviceId => integer()();

  @override
  Set<Column> get primaryKey => {serverId, id};

  IntColumn get fixTime => integer()();
  RealColumn get latitude => real()();
  RealColumn get longitude => real()();
  RealColumn get altitude => real().nullable()();
  RealColumn get speed => real().nullable()();
  RealColumn get course => real().nullable()();
  RealColumn get accuracy => real().nullable()();
  RealColumn get battery => real().nullable()();
  TextColumn get attributes => text().nullable()();

  @override
  List<Set<Column>> get uniqueKeys => [
        {serverId, deviceId, fixTime},
      ];
}

/// 事件缓存。保留 30 天；已读状态本地维护。
@DataClassName('EventRow')
class EventRows extends Table {
  IntColumn get id => integer()();
  IntColumn get serverId => integer()();
  IntColumn get deviceId => integer().nullable()();

  @override
  Set<Column> get primaryKey => {serverId, id};

  TextColumn get type => text().nullable()();
  IntColumn get eventTime => integer().nullable()();
  IntColumn get positionId => integer().nullable()();
  IntColumn get geofenceId => integer().nullable()();
  BoolColumn get read => boolean().withDefault(const Constant(false))();
  TextColumn get attributes => text().nullable()();
  TextColumn get raw => text().nullable()();
}

/// 待执行的离线动作队列（指令发送失败重试等）。
@DataClassName('PendingActionRow')
class PendingActions extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get kind => text()();
  TextColumn get payload => text()();
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();
  IntColumn get retries => integer().withDefault(const Constant(0))();
}

/// 跟踪诊断快照：最后成功上报时间与队列量（TRK-09/10、诊断页）。
@DataClassName('TrackingSnapshotRow')
class TrackingSnapshots extends Table {
  IntColumn get id => integer()();
  TextColumn get uniqueId => text()();

  @override
  Set<Column> get primaryKey => {id, uniqueId};

  DateTimeColumn get lastUploadAt => dateTime().nullable()();
  IntColumn get queueSize => integer().withDefault(const Constant(0))();
  DateTimeColumn get updatedAt => dateTime().withDefault(currentDateAndTime)();
}

/// 好友关系缓存（v2：好友体系）。
///
/// 服务端 tc_friends 的镜像 + 5056 消息通道实时更新。
/// 好友身份以 uniqueId 为准（消息协议不暴露 deviceId；
/// 实时广播的 from.id 会回填 [deviceId] 供地图标记复用）。
/// 只有 status=accepted 的好友才可能有最后位置（服务端强制校验）。
@DataClassName('FriendRow')
class FriendRows extends Table {
  IntColumn get serverId => integer()();
  TextColumn get uniqueId => text()();

  @override
  Set<Column> get primaryKey => {serverId, uniqueId};

  IntColumn get deviceId => integer().nullable()(); // 广播 from.id 回填
  TextColumn get name => text().nullable()();
  TextColumn get status => text()(); // accepted | pending_in | pending_out
  BoolColumn get online => boolean().withDefault(const Constant(false))();
  RealColumn get lastLatitude => real().nullable()();
  RealColumn get lastLongitude => real().nullable()();
  IntColumn get lastTime => integer().nullable()(); // ms epoch
  DateTimeColumn get updatedAt => dateTime().withDefault(currentDateAndTime)();
}

/// 事件列表主查询索引：`WHERE server_id = ? ORDER BY event_time DESC`
/// （列表、补拉、未读计数共用）。位置表已有 UNIQUE(server, device, fix) 索引。
final _eventServerTimeIndex = Index(
  'event_server_time',
  'CREATE INDEX event_server_time ON event_rows (server_id, event_time)',
);

@DriftDatabase(
  tables: [
    ServerProfiles,
    DeviceRows,
    PositionRows,
    EventRows,
    PendingActions,
    TrackingSnapshots,
    FriendRows,
  ],
)
class AppDatabase extends _$AppDatabase {
  AppDatabase(super.connection);

  AppDatabase.open(String path) : super(_openConnection(path));

  @override
  int get schemaVersion => 4;

  @override
  MigrationStrategy get migration => MigrationStrategy(
        onCreate: (m) async {
          await m.createAll();
          await m.create(_eventServerTimeIndex);
        },
        onUpgrade: (m, from, to) async {
          // v2：好友表（好友体系新增）。
          if (from < 2) {
            await m.createTable(friendRows);
          }
          // v3：档案显式记录「允许明文 HTTP」（H-3 同意结果需要持久化）。
          if (from < 3) {
            await m.addColumn(serverProfiles, serverProfiles.allowInsecure);
          }
          // v4：事件列表/补拉按 serverId + eventTime 建索引。
          if (from < 4) {
            await m.create(_eventServerTimeIndex);
          }
        },
      );

  static LazyDatabase _openConnection(String path) {
    return LazyDatabase(() async {
      final dir = await getApplicationDocumentsDirectory();
      await Directory(dir.path).create(recursive: true);
      final file = File(p.join(dir.path, path));
      return NativeDatabase.createInBackground(file);
    });
  }

  // ---- 保留策略（docs/03 §7.1：位置 7 天、事件 30 天）----

  Future<void> purgePositions({int keepDays = 7}) {
    final cutoff = DateTime.now().toUtc().subtract(Duration(days: keepDays));
    return (delete(positionRows)
          ..where((tbl) => tbl.fixTime.isSmallerThanValue(cutoff.millisecondsSinceEpoch)))
        .go();
  }

  Future<void> purgeEvents({int keepDays = 30}) {
    final cutoff = DateTime.now().toUtc().subtract(Duration(days: keepDays));
    return (delete(eventRows)
          ..where(
            (tbl) =>
                tbl.eventTime.isNotNull() &
                tbl.eventTime.isSmallerThanValue(cutoff.millisecondsSinceEpoch),
          ))
        .go();
  }

  /// 定期清理入口：应用启动与前台恢复时调用，失败不影响业务。
  Future<void> purgeExpired() async {
    try {
      await purgePositions();
      await purgeEvents();
    } on Object {
      // 缓存清理失败不阻断启动。
    }
  }

  // ---- 服务器档案 ----

  Future<List<ServerProfileRow>> allProfiles() =>
      (select(serverProfiles)..orderBy([(t) => OrderingTerm.asc(t.sortOrder)]))
          .get();

  Future<ServerProfileRow?> activeProfile() =>
      (select(serverProfiles)..where((t) => t.isActive)).getSingleOrNull();

  /// 响应式：当前激活档案（路由守卫与网络层依赖）。
  Stream<ServerProfileRow?> watchActiveProfile() =>
      (select(serverProfiles)..where((t) => t.isActive)).watchSingleOrNull();

  /// 响应式：设备列表（离线优先读取缓存）。
  Stream<List<DeviceRow>> watchDevices(int serverId) =>
      (select(deviceRows)..where((t) => t.serverId.equals(serverId))).watch();

  /// 响应式：事件列表（最多 [limit] 条，按时间倒序）。
  Stream<List<EventRow>> watchEvents(int serverId, {int limit = 200}) =>
      (select(eventRows)
            ..where((t) => t.serverId.equals(serverId))
            ..orderBy([(t) => OrderingTerm.desc(t.eventTime)])
            ..limit(limit))
          .watch();

  Future<int> insertProfile(ServerProfilesCompanion entry) =>
      into(serverProfiles).insert(entry);

  Future<void> updateProfile(ServerProfileRow row) =>
      update(serverProfiles).replace(row);

  Future<void> deleteProfile(int id) =>
      (delete(serverProfiles)..where((t) => t.id.equals(id))).go();

  /// 激活档案并取消其它档案的激活态（v1 单活）。
  Future<void> activateProfile(int id) async {
    await transaction(() async {
      await (update(serverProfiles)..where((t) => t.isActive))
          .write(const ServerProfilesCompanion(isActive: Value(false)));
      await (update(serverProfiles)..where((t) => t.id.equals(id)))
          .write(const ServerProfilesCompanion(isActive: Value(true)));
    });
  }

  // ---- 设备 ----

  Future<void> upsertDevices(int serverId, Iterable<DeviceRowsCompanion> rows) =>
      batch((batch) {
        batch.insertAll(
          deviceRows,
          rows,
          mode: InsertMode.replace,
        );
      });

  Future<List<DeviceRow>> devicesFor(int serverId) =>
      (select(deviceRows)..where((t) => t.serverId.equals(serverId))).get();

  Future<DeviceRow?> device(int serverId, int id) =>
      (select(deviceRows)
            ..where((t) => t.serverId.equals(serverId) & t.id.equals(id)))
          .getSingleOrNull();

  Future<void> clearDevices(int serverId) =>
      (delete(deviceRows)..where((t) => t.serverId.equals(serverId))).go();

  /// 全量快照替换：服务器上已删除的设备必须同步移除，不能只 upsert。
  Future<void> replaceDevices(
    int serverId,
    Iterable<DeviceRowsCompanion> rows,
  ) async {
    await transaction(() async {
      await clearDevices(serverId);
      await upsertDevices(serverId, rows);
    });
  }

  // ---- 位置 ----

  Future<void> upsertPositions(int serverId, Iterable<PositionRowsCompanion> rows) =>
      batch((batch) {
        batch.insertAll(
          positionRows,
          rows,
          mode: InsertMode.insertOrIgnore, // (serverId, deviceId, fixTime) 幂等
        );
      });

  Future<List<PositionRow>> latestPositions(int serverId) {
    // 每个设备取最新 fixTime 的位置（docs/03 §15.2 快照语义）。
    return customSelect(
      'SELECT p.* FROM position_rows p '
      'JOIN (SELECT device_id, MAX(fix_time) AS max_fix FROM position_rows '
      '      WHERE server_id = ? GROUP BY device_id) m '
      'ON p.device_id = m.device_id AND p.fix_time = m.max_fix '
      'WHERE p.server_id = ?',
      variables: [Variable<int>(serverId), Variable<int>(serverId)],
      readsFrom: {positionRows},
    ).map((row) => positionRows.map(row.data)).get();
  }

  Future<List<PositionRow>> historyPositions(
    int serverId,
    int deviceId,
    DateTime from,
    DateTime to,
  ) =>
      (select(positionRows)
            ..where(
              (t) =>
                  t.serverId.equals(serverId) &
                  t.deviceId.equals(deviceId) &
                  t.fixTime.isBiggerOrEqualValue(from.millisecondsSinceEpoch) &
                  t.fixTime.isSmallerOrEqualValue(to.millisecondsSinceEpoch),
            )
            ..orderBy([(t) => OrderingTerm.asc(t.fixTime)]))
          .get();

  Future<void> clearPositions(int serverId) =>
      (delete(positionRows)..where((t) => t.serverId.equals(serverId))).go();

  // ---- 事件 ----

  Future<void> upsertEvents(int serverId, Iterable<EventRowsCompanion> rows) =>
      batch((batch) {
        batch.insertAll(eventRows, rows, mode: InsertMode.insertOrIgnore);
      });

  Future<List<EventRow>> eventsFor(
    int serverId, {
    int? deviceId,
    bool onlyUnread = false,
    int limit = 200,
  }) {
    final query = select(eventRows)
      ..where((t) => t.serverId.equals(serverId))
      ..orderBy([(t) => OrderingTerm.desc(t.eventTime)])
      ..limit(limit);
    if (deviceId != null) {
      query.where((t) => t.deviceId.equals(deviceId));
    }
    if (onlyUnread) {
      query.where((t) => t.read.equals(false));
    }
    return query.get();
  }

  Future<void> markEventRead(int serverId, int id, {bool read = true}) =>
      (update(eventRows)
            ..where((t) => t.serverId.equals(serverId) & t.id.equals(id)))
          .write(EventRowsCompanion(read: Value(read)));

  Future<int> unreadCount(int serverId) async {
    final countExpr = eventRows.id.count();
    final query = selectOnly(eventRows)
      ..addColumns([countExpr])
      ..where(eventRows.serverId.equals(serverId) & eventRows.read.equals(false));
    final row = await query.getSingle();
    return row.read(countExpr) ?? 0;
  }

  Future<void> clearEvents(int serverId) =>
      (delete(eventRows)..where((t) => t.serverId.equals(serverId))).go();

  // ---- 离线动作 ----

  Future<int> enqueuePendingAction(PendingActionsCompanion entry) =>
      into(pendingActions).insert(entry);

  Future<List<PendingActionRow>> pendingActionRows({
    int limit = 50,
    int maxRetries = 5,
  }) =>
      (select(pendingActions)
            ..where((t) => t.retries.isSmallerThanValue(maxRetries))
            ..orderBy([(t) => OrderingTerm.asc(t.createdAt)])
            ..limit(limit))
          .get();

  Future<void> incrementRetries(int id) {
    return customUpdate(
      'UPDATE pending_actions SET retries = retries + 1 WHERE id = ?',
      variables: [Variable<int>(id)],
      updates: {pendingActions},
    );
  }

  Future<void> removePendingAction(int id) =>
      (delete(pendingActions)..where((t) => t.id.equals(id))).go();

  /// 指令发件箱积压量（kind=command.send 且未超重试上限；诊断页展示）。
  /// kind 常量与 CommandOutbox.kind 保持一致（避免 feature→core 循环依赖）。
  Future<int> commandOutboxCount() async {
    final countExpr = pendingActions.id.count();
    final query = selectOnly(pendingActions)
      ..addColumns([countExpr])
      ..where(pendingActions.kind.equals('command.send') &
          pendingActions.retries.isSmallerThanValue(5));
    final row = await query.getSingle();
    return row.read(countExpr) ?? 0;
  }

  // ---- 跟踪快照 ----

  Future<void> saveTrackingSnapshot(TrackingSnapshotsCompanion entry) =>
      into(trackingSnapshots).insertOnConflictUpdate(entry);

  Future<TrackingSnapshotRow?> trackingSnapshot(
    int serverId,
    String uniqueId,
  ) =>
      (select(trackingSnapshots)
            ..where(
              (t) => t.id.equals(serverId) & t.uniqueId.equals(uniqueId),
            ))
          .getSingleOrNull();

  Future<void> clearTrackingSnapshots(int serverId) =>
      (delete(trackingSnapshots)..where((t) => t.id.equals(serverId))).go();

  // ---- 好友（v2）----

  /// 响应式好友列表（好友页 / 地图好友图层共用）。
  Stream<List<FriendRow>> watchFriends(int serverId) =>
      (select(friendRows)
            ..where((t) => t.serverId.equals(serverId))
            ..orderBy([(t) => OrderingTerm.asc(t.uniqueId)]))
          .watch();

  Future<List<FriendRow>> friendsFor(int serverId) =>
      (select(friendRows)..where((t) => t.serverId.equals(serverId))).get();

  /// friends.list 快照 / 消息推送的全量覆盖（幂等 replace）。
  Future<void> upsertFriends(
    int serverId,
    Iterable<FriendRowsCompanion> rows,
  ) =>
      batch((batch) {
        batch.insertAll(friendRows, rows, mode: InsertMode.replace);
      });

  /// 实时广播位置更新（幂等覆盖单行；同时回填 deviceId）。
  Future<void> updateFriendPosition(
    int serverId,
    String uniqueId, {
    int? deviceId,
    required double latitude,
    required double longitude,
    required int lastTime,
  }) =>
      (update(friendRows)
            ..where(
              (t) => t.serverId.equals(serverId) & t.uniqueId.equals(uniqueId),
            ))
          .write(FriendRowsCompanion(
        deviceId: deviceId == null ? const Value.absent() : Value(deviceId),
        lastLatitude: Value(latitude),
        lastLongitude: Value(longitude),
        lastTime: Value(lastTime),
        updatedAt: Value(DateTime.now().toUtc()),
      ));

  Future<void> clearFriends(int serverId) =>
      (delete(friendRows)..where((t) => t.serverId.equals(serverId))).go();

  /// friends.list 全量快照替换：删除已解除好友关系的残留行。
  Future<void> replaceFriends(
    int serverId,
    Iterable<FriendRowsCompanion> rows,
  ) async {
    await transaction(() async {
      await clearFriends(serverId);
      await upsertFriends(serverId, rows);
    });
  }

  // ---- 数据删除（CN-09：本地数据删除入口）----

  Future<void> wipeServerData(int serverId) async {
    await transaction(() async {
      await clearDevices(serverId);
      await clearPositions(serverId);
      await clearEvents(serverId);
      await clearFriends(serverId);
    });
  }

  /// 退出登录 / 注销账号时清空全部本地缓存（不含档案本身）。
  Future<void> wipeAllCache() async {
    await transaction(() async {
      await delete(deviceRows).go();
      await delete(positionRows).go();
      await delete(eventRows).go();
      await delete(pendingActions).go();
      await delete(trackingSnapshots).go();
      await delete(friendRows).go();
    });
  }
}
