import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/network/api_client.dart';
import '../../../../core/network/api_exceptions.dart';
import '../../data/output_api.dart';
import '../../domain/output_models.dart';

/// 输出 API Provider。
final outputApiProvider = Provider<OutputApi>((ref) {
  final dio = ref.watch(dioProvider);
  return OutputApi(dio: dio);
});

/// 输出面板的界面状态。
class OutputState {
  const OutputState({
    this.players = const <OutputDevice>[],
    this.groups = const <OutputGroup>[],
    this.metrics,
    this.party,
    this.loading = false,
    this.busy = false,
    this.error = '',
    this.notice = '',
    this.lastScan,
  });

  final List<OutputDevice> players;
  final List<OutputGroup> groups;

  /// 指标是诊断面板才需要的，不参与首屏渲染，所以可空。
  final PlaybackMetrics? metrics;

  /// 当前打开的派对状态（没有派对时为 null）。
  final PartyStatus? party;

  /// 首次加载 / 手动刷新中。
  final bool loading;

  /// 正在执行写操作（避免连点重复提交）。
  final bool busy;

  /// 上一次失败的完整原因（403 会带后端的说明，如"当前运行模式不支持网络音箱"）。
  final String error;

  /// 上一次成功的提示（"已发现 2 台设备"等）。
  final String notice;

  /// 最近一次扫描结果，供弹层展示"新增 / 跳过"明细。
  final DiscoveryResult? lastScan;

  /// 按 id 取区域（组）。
  OutputGroup? groupOf(String id) {
    for (final g in groups) {
      if (g.id == id) return g;
    }
    return null;
  }

  /// 按 id 取设备；组里的成员 id 用它映射成名字与能力。
  OutputDevice? playerOf(String id) {
    for (final p in players) {
      if (p.id == id) return p;
    }
    return null;
  }

  /// 精确同步组：全组设备都在线、不待机、且都支持 exact。
  bool exactCapable(String playerId) {
    final p = playerOf(playerId);
    return p != null && p.exactCapable;
  }

  /// 可以加入组的设备（在网、不待机、未在别的组里）。
  ///
  /// 注意：单机组也算"在组里"，所以这里按 [excludeGroupId] 排除的只是
  /// 其他组；调用方要自己决定是否包含单机组里的自己。
  List<OutputDevice> candidatesFor(String excludeGroupId) {
    final taken = <String>{};
    for (final g in groups) {
      if (g.id == excludeGroupId) continue;
      // 单机组不算占用：它的成员本来就"只属于自己"，可以被拉进新组。
      if (g.isSolo) continue;
      taken.addAll(g.memberIds);
    }
    return players
        .where((p) => p.usable && !taken.contains(p.id))
        .toList(growable: false);
  }

  OutputState copyWith({
    List<OutputDevice>? players,
    List<OutputGroup>? groups,
    PlaybackMetrics? metrics,
    PartyStatus? party,
    bool clearParty = false,
    bool? loading,
    bool? busy,
    String? error,
    String? notice,
    DiscoveryResult? lastScan,
  }) => OutputState(
    players: players ?? this.players,
    groups: groups ?? this.groups,
    metrics: metrics ?? this.metrics,
    party: clearParty ? null : (party ?? this.party),
    loading: loading ?? this.loading,
    busy: busy ?? this.busy,
    error: error ?? '',
    notice: notice ?? '',
    lastScan: lastScan ?? this.lastScan,
  );
}

/// 播放输出控制器。
///
/// 数据来源只有两条：`GET /playback`（组 + 状态，全量对齐）与
/// `GET /players`（设备能力与音量）。断线重连后必须全量拉一次，
/// 增量事件只用来触发"再拉一次"，不做本地 diff —— 组 id 会被墓碑表
/// 换成带时间戳的新 id，本地 diff 会把新组当成旧组。
class OutputController extends Notifier<OutputState> {
  late final OutputApi _api;
  Timer? _poll;
  bool _disposed = false;

  @override
  OutputState build() {
    _api = ref.watch(outputApiProvider);
    ref.onDispose(() {
      _disposed = true;
      _poll?.cancel();
      _poll = null;
    });
    // build() 里不能直接改 state，放到微任务里做首次全量对齐。
    Future.microtask(refresh);
    return const OutputState();
  }

  void _set(OutputState next) {
    if (_disposed) return;
    state = next;
  }

  /// 全量对齐：设备 + 组 + 派对状态一起拉。
  Future<void> refresh({bool silent = false}) async {
    if (!silent) _set(state.copyWith(loading: true, error: ''));
    try {
      final players = await _api.listPlayers();
      final groups = await _api.playback();
      PartyStatus? party;
      final partyId = groups
          .map((g) => g.partyId)
          .firstWhere((id) => id.isNotEmpty, orElse: () => '');
      if (partyId.isNotEmpty) {
        try {
          party = await _api.partyStatus(partyId);
        } on ApiException {
          // 派对可能刚被别处结束：拿不到就当作没有派对，不影响主列表。
          party = null;
        }
      }
      _set(
        state.copyWith(
          players: players,
          groups: groups,
          party: party,
          clearParty: party == null,
          loading: false,
          error: '',
        ),
      );
    } on ApiException catch (e) {
      _set(state.copyWith(loading: false, error: e.message));
    } catch (e) {
      _set(state.copyWith(loading: false, error: '$e'));
    }
  }

  /// 开始轮询（页面可见时调用）。间隔 4s：够跟上音量与状态变化，
  /// 又不会让 SQLite 与 mDNS 侧压力过大。
  void startPolling({Duration interval = const Duration(seconds: 4)}) {
    _poll?.cancel();
    _poll = Timer.periodic(interval, (_) => refresh(silent: true));
  }

  void stopPolling() {
    _poll?.cancel();
    _poll = null;
  }

  /// 统一包装写操作：置 busy、吞掉异常转 error，成功后重拉全量。
  Future<bool> _run(Future<void> Function() action, {String? notice}) async {
    if (state.busy) return false;
    _set(state.copyWith(busy: true, error: '', notice: ''));
    try {
      await action();
      _set(state.copyWith(busy: false, notice: notice ?? ''));
      await refresh(silent: true);
      return true;
    } on ApiException catch (e) {
      _set(state.copyWith(busy: false, error: e.message));
      return false;
    } catch (e) {
      _set(state.copyWith(busy: false, error: '$e'));
      return false;
    }
  }

  Future<bool> discover() async {
    _set(state.copyWith(busy: true, error: '', notice: ''));
    try {
      final res = await _api.discoverPlayers();
      final parts = <String>[];
      if (res.added.isNotEmpty) parts.add('新增 ${res.added.length} 台');
      if (res.updated.isNotEmpty) parts.add('刷新 ${res.updated.length} 台');
      if (res.skipped.isNotEmpty) parts.add('跳过 ${res.skipped.length} 台');
      if (res.errors.isNotEmpty) parts.add('${res.errors.length} 个协议失败');
      _set(
        state.copyWith(
          busy: false,
          lastScan: res,
          notice: parts.isEmpty ? '没有发现新设备' : parts.join('，'),
        ),
      );
      await refresh(silent: true);
      return true;
    } on ApiException catch (e) {
      _set(state.copyWith(busy: false, error: e.message));
      return false;
    }
  }

  Future<bool> addPlayer({
    required String address,
    required OutputKind kind,
    String name = '',
    String deviceId = '',
    String publicKey = '',
  }) => _run(
    () => _api.addPlayer(
      address: address,
      kind: kind,
      name: name,
      deviceId: deviceId,
      publicKey: publicKey,
    ),
    notice: '已添加设备',
  );

  Future<bool> renamePlayer(String id, String name) =>
      _run(() => _api.updatePlayer(id, name: name), notice: '已重命名');

  /// 本机被其他设备接管时的行为：pause（默认）/ follow。
  Future<bool> setTakeover(String id, String takeover) => _run(
    () => _api.updatePlayer(id, takeover: takeover),
    notice: takeover == 'follow' ? '已改为静默跟随' : '已改为暂停本机',
  );

  /// 向组队列追加歌曲；position=next 表示“下一首播放”。
  Future<OutputStatus?> enqueue(
    String groupId,
    List<int> songIds, {
    String position = 'end',
  }) async {
    try {
      final status = await _api.addToQueue(
        groupId,
        songIds,
        position: position,
      );
      await refresh(silent: true);
      return status;
    } on ApiException catch (e) {
      _set(state.copyWith(error: e.message));
      return null;
    }
  }

  /// 把歌曲插到当前曲之后（下一首播放）。
  Future<OutputStatus?> enqueueNext(String groupId, List<int> songIds) async {
    try {
      final status = await _api.enqueueNext(groupId, songIds);
      await refresh(silent: true);
      return status;
    } on ApiException catch (e) {
      _set(state.copyWith(error: e.message));
      return null;
    }
  }

  Future<bool> reconnectPlayer(String id) =>
      _run(() => _api.reconnectPlayer(id), notice: '已重新连接');

  Future<bool> deletePlayer(String id) =>
      _run(() => _api.deletePlayer(id), notice: '已删除设备');

  /// 待机 / 唤醒。待机成员会立刻从组内分发与同步环中摘除。
  Future<bool> setPower(String id, {required bool on}) =>
      _run(() => _api.setPower(id, on: on), notice: on ? '已唤醒' : '已待机');

  Future<bool> setVolume(String id, int volume, {bool muted = false}) =>
      _run(() => _api.setVolume(id, volume: volume, muted: muted));

  Future<bool> createGroup(List<String> memberIds, {String name = ''}) => _run(
    () => _api.createGroup(memberIds: memberIds, name: name),
    notice: '已创建同步组',
  );

  Future<bool> deleteGroup(String id) =>
      _run(() => _api.deleteGroup(id), notice: '已解散同步组');

  /// 更新区域名称与图标（`PUT /groups/{id}`）。
  Future<bool> renameGroup(
    String id, {
    required String name,
    String icon = '',
  }) =>
      _run(() => _api.updateGroup(id, name: name, icon: icon), notice: '已更新区域');

  /// 把 [fromGroupId] 的全部成员并入 [toGroupId]。
  ///
  /// 后端没有“合并组”端点，合并 = 逐个 `POST /groups/{to}/members`。
  /// 逐个提交意味着中途失败会留下部分合并；这里不假装原子，错误原样上报。
  Future<bool> mergeGroups({
    required String fromGroupId,
    required String toGroupId,
  }) async {
    if (state.busy) return false;
    if (fromGroupId == toGroupId) return true;
    final from = state.groupOf(fromGroupId);
    final to = state.groupOf(toGroupId);
    if (from == null || to == null) return false;

    _set(state.copyWith(busy: true, error: '', notice: ''));
    try {
      final existing = to.memberIds.toSet();
      for (final member in from.members) {
        if (existing.contains(member.playerId)) continue;
        await _api.addMember(toGroupId, member.playerId);
      }
      _set(state.copyWith(busy: false, notice: '已合并区域'));
      await refresh(silent: true);
      return true;
    } on ApiException catch (e) {
      _set(state.copyWith(busy: false, error: e.message));
      return false;
    } catch (e) {
      _set(state.copyWith(busy: false, error: '$e'));
      return false;
    }
  }

  Future<bool> setMaster(String groupId, String playerId) =>
      _run(() => _api.setMaster(groupId, playerId), notice: '已切换主控');

  Future<bool> addMember(String groupId, String playerId) =>
      _run(() => _api.addMember(groupId, playerId), notice: '已加入同步组');

  Future<bool> removeMember(
    String groupId,
    String playerId, {
    String mode = 'continue',
  }) => _run(
    () => _api.removeMember(groupId, playerId, mode: mode),
    notice: mode == 'stop' ? '已移出并停止' : '已移出同步组',
  );

  Future<bool> updateMember(
    String groupId,
    String playerId, {
    int? delayMs,
    int? volumeOffset,
  }) => _run(
    () => _api.updateMember(
      groupId,
      playerId,
      delayMs: delayMs,
      volumeOffset: volumeOffset,
    ),
    notice: '已更新成员参数',
  );

  /// 成员顺序：传全排列，服务端拒绝非法顺序（400）。
  Future<bool> reorderMembers(String groupId, List<String> playerIds) =>
      _run(() => _api.reorderMembers(groupId, playerIds), notice: '已调整成员顺序');

  /// 组音量：部分设备失败也算成功（后端不回滚已成功的成员），
  /// 失败明细通过返回值里 members[].error 展示。
  Future<GroupVolume?> setGroupVolume(
    String groupId,
    int volume, {
    bool muted = false,
  }) async {
    if (state.busy) return null;
    _set(state.copyWith(busy: true, error: ''));
    try {
      final v = await _api.setGroupVolume(
        groupId,
        volume: volume,
        muted: muted,
      );
      _set(state.copyWith(busy: false));
      if (v.failed.isNotEmpty) {
        _set(
          state.copyWith(
            notice:
                '${v.failed.length} 台设备音量下发失败：'
                '${v.failed.map((m) => m.playerId).join('、')}',
          ),
        );
      }
      await refresh(silent: true);
      return v;
    } on ApiException catch (e) {
      _set(state.copyWith(busy: false, error: e.message));
      return null;
    }
  }

  /// 区域选择器里的行内音量：不占用全局 busy，避免拖动 A 区域时
  /// 把 B 区域的提交挡掉。防抖由调用方（滑杆）负责。
  Future<GroupVolume?> setZoneVolume(String groupId, int volume) async {
    try {
      final v = await _api.setGroupVolume(groupId, volume: volume);
      if (v.failed.isNotEmpty) {
        _set(
          state.copyWith(
            notice:
                '${v.failed.length} 台设备音量下发失败：'
                '${v.failed.map((m) => m.playerId).join('、')}',
          ),
        );
      }
      await refresh(silent: true);
      return v;
    } on ApiException catch (e) {
      _set(state.copyWith(error: e.message));
      return null;
    }
  }

  Future<GroupVolume?> groupVolume(String groupId) async {
    try {
      return await _api.getGroupVolume(groupId);
    } on ApiException catch (e) {
      _set(state.copyWith(error: e.message));
      return null;
    }
  }

  /// 播放转移：把 [fromGroupId] 的队列与位置转到 [toGroupId]。
  Future<bool> transfer({
    required String fromGroupId,
    required String toGroupId,
    String onlyPlayerId = '',
  }) => _run(
    () => _api.transfer(
      fromGroupId: fromGroupId,
      toGroupId: toGroupId,
      onlyPlayerId: onlyPlayerId,
    ),
    notice: '已转移播放',
  );

  Future<OutputStatus?> transport(
    String groupId,
    String action, {
    double? position,
    String? repeat,
    bool? shuffle,
  }) async {
    try {
      final st = await _api.transport(
        groupId,
        action: action,
        position: position,
        repeat: repeat,
        shuffle: shuffle,
      );
      await refresh(silent: true);
      return st;
    } on ApiException catch (e) {
      _set(state.copyWith(error: e.message));
      return null;
    }
  }

  // ---------- EQ ----------

  Future<List<EqPreset>?> eqPresets(String playerId) async {
    try {
      return await _api.listEqPresets(playerId);
    } on ApiException catch (e) {
      _set(state.copyWith(error: e.message));
      return null;
    }
  }

  Future<EqProfile?> eq(String playerId) async {
    try {
      return await _api.getEq(playerId);
    } on ApiException catch (e) {
      _set(state.copyWith(error: e.message));
      return null;
    }
  }

  Future<bool> setEq(String playerId, EqProfile eq) =>
      _run(() => _api.setEq(playerId, eq), notice: '已保存 EQ');

  // ---------- 指标 ----------

  Future<void> loadMetrics() async {
    try {
      final m = await _api.metrics();
      _set(state.copyWith(metrics: m));
    } on ApiException catch (e) {
      _set(state.copyWith(error: e.message));
    }
  }

  // ---------- 派对 ----------

  Future<bool> createParty(List<String> groupIds, {String name = ''}) async {
    if (state.busy) return false;
    _set(state.copyWith(busy: true, error: ''));
    try {
      final st = await _api.createParty(groupIds: groupIds, name: name);
      _set(state.copyWith(busy: false, party: st, notice: '已开启派对'));
      await refresh(silent: true);
      return true;
    } on ApiException catch (e) {
      _set(state.copyWith(busy: false, error: e.message));
      return false;
    }
  }

  Future<bool> partyJoin(String groupId) async {
    final party = state.party;
    if (party == null) return false;
    return _run(
      () => _api.partyGroups(party.id, action: 'join', groupId: groupId),
      notice: '已加入派对',
    );
  }

  Future<bool> partyLeave(String groupId, {String mode = 'continue'}) async {
    final party = state.party;
    if (party == null) return false;
    return _run(
      () => _api.partyGroups(
        party.id,
        action: 'leave',
        groupId: groupId,
        mode: mode,
      ),
      notice: '已退出派对',
    );
  }

  Future<bool> endParty() async {
    final party = state.party;
    if (party == null) return false;
    final ok = await _run(
      () => _api.partyGroups(party.id, action: 'end'),
      notice: '派对已结束',
    );
    if (ok) _set(state.copyWith(clearParty: true));
    return ok;
  }

  Future<bool> partyTransport(String action) async {
    final party = state.party;
    if (party == null) return false;
    return _run(() => _api.partyTransport(party.id, action));
  }

  void clearError() => _set(state.copyWith(error: ''));
  void clearNotice() => _set(state.copyWith(notice: ''));
}

final outputControllerProvider =
    NotifierProvider<OutputController, OutputState>(OutputController.new);
