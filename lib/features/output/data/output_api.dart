import 'package:dio/dio.dart';

import '../../../config/app_config.dart';
import '../../../core/network/api_exceptions.dart';
import '../domain/output_models.dart';

/// 播放输出 API（`/api/v1/players`、`/groups`、`/playback`）。
///
/// 所有方法都在失败时抛 [ApiException]（与项目其他 Api 一致），
/// 调用方用 `catch (e)` + `e is ApiException` 决定是否弹窗。
/// 注意 403 有两种来源：Bundle 关闭了网络音箱（X-04）、派对模式关闭，
/// 后端都把原因写在 `detail` 里，直接展示给用户即可。
class OutputApi {
  OutputApi({required this.dio});

  final Dio dio;

  String get _base => '${AppConfig.apiPrefix}/players';
  String get _groupBase => '${AppConfig.apiPrefix}/groups';
  String get _playbackBase => '${AppConfig.apiPrefix}/playback';

  // ---------- 设备 ----------

  /// 设备列表（含 EQ、能力、在线、待机）。
  Future<List<OutputDevice>> listPlayers() async {
    try {
      final res = await dio.get<List<dynamic>>(_base);
      return (res.data ?? const [])
          .map((e) => OutputDevice.fromJson(e as Map<String, dynamic>))
          .toList();
    } on DioException catch (e) {
      throw ApiException.fromDioException(e);
    }
  }

  /// 手动触发一轮 mDNS + SSDP 扫描。不受「自动发现」开关影响。
  Future<DiscoveryResult> discoverPlayers() async {
    try {
      final res = await dio.post<Map<String, dynamic>>('$_base/discover');
      return DiscoveryResult.fromJson(res.data ?? const {});
    } on DioException catch (e) {
      throw ApiException.fromDioException(e);
    }
  }

  /// 手动添加设备。DLNA 填 IP / host:port / desc.xml；RAOP 必须带 deviceId。
  Future<OutputDevice> addPlayer({
    required String address,
    required OutputKind kind,
    String name = '',
    String deviceId = '',
    String publicKey = '',
  }) async {
    try {
      final res = await dio.post<Map<String, dynamic>>(
        _base,
        data: {
          'address': address,
          'kind': kind.wire,
          if (name.isNotEmpty) 'name': name,
          if (deviceId.isNotEmpty) 'device_id': deviceId,
          if (publicKey.isNotEmpty) 'public_key': publicKey,
        },
      );
      return OutputDevice.fromJson(res.data ?? const {});
    } on DioException catch (e) {
      throw ApiException.fromDioException(e);
    }
  }

  /// 改名 / 改接管行为（takeover 只对 local 生效：pause / follow）。
  Future<OutputDevice> updatePlayer(
    String id, {
    String? name,
    String? takeover,
  }) async {
    try {
      final res = await dio.put<Map<String, dynamic>>(
        '$_base/$id',
        data: {
          if (name != null) 'name': name,
          if (takeover != null) 'takeover_behavior': takeover,
        },
      );
      return OutputDevice.fromJson(res.data ?? const {});
    } on DioException catch (e) {
      throw ApiException.fromDioException(e);
    }
  }

  /// 删除设备（连同它的单机组）。
  Future<void> deletePlayer(String id) async {
    try {
      await dio.delete<void>('$_base/$id');
    } on DioException catch (e) {
      throw ApiException.fromDioException(e);
    }
  }

  /// 重新连接（重新握手 RTSP / 重新取 desc.xml）。离线设备常用。
  Future<OutputDevice> reconnectPlayer(String id) async {
    try {
      final res = await dio.post<Map<String, dynamic>>('$_base/$id/reconnect');
      return OutputDevice.fromJson(res.data ?? const {});
    } on DioException catch (e) {
      throw ApiException.fromDioException(e);
    }
  }

  /// 设置音量（0-100）与静音。
  Future<OutputDevice> setVolume(
    String id, {
    required int volume,
    bool muted = false,
  }) async {
    try {
      final res = await dio.post<Map<String, dynamic>>(
        '$_base/$id/volume',
        data: {'volume': volume, 'muted': muted},
      );
      return OutputDevice.fromJson(res.data ?? const {});
    } on DioException catch (e) {
      throw ApiException.fromDioException(e);
    }
  }

  /// 待机（on=false）或唤醒（on=true）。
  ///
  /// 返回的 standby 只表示"服务端不再推流"，不代表设备真的断电待机。
  Future<OutputDevice> setPower(String id, {required bool on}) async {
    try {
      final res = await dio.post<Map<String, dynamic>>(
        '$_base/$id/power',
        data: {'on': on},
      );
      return OutputDevice.fromJson(res.data ?? const {});
    } on DioException catch (e) {
      throw ApiException.fromDioException(e);
    }
  }

  // ---------- EQ ----------

  Future<EqProfile> getEq(String id) async {
    try {
      final res = await dio.get<Map<String, dynamic>>('$_base/$id/eq');
      return EqProfile.fromJson(res.data);
    } on DioException catch (e) {
      throw ApiException.fromDioException(e);
    }
  }

  /// 保存 EQ：服务端会把增益钳到 ±12dB、重算 preamp 并回填。
  Future<EqProfile> setEq(String id, EqProfile eq) async {
    try {
      final res = await dio.put<Map<String, dynamic>>(
        '$_base/$id/eq',
        data: eq.toJson(),
      );
      return EqProfile.fromJson(res.data);
    } on DioException catch (e) {
      throw ApiException.fromDioException(e);
    }
  }

  Future<List<EqPreset>> listEqPresets(String id) async {
    try {
      final res = await dio.get<List<dynamic>>('$_base/$id/eq/presets');
      return (res.data ?? const [])
          .map((e) => EqPreset.fromJson(e as Map<String, dynamic>))
          .toList();
    } on DioException catch (e) {
      throw ApiException.fromDioException(e);
    }
  }

  // ---------- 组 ----------

  Future<List<OutputGroup>> listGroups() async {
    try {
      final res = await dio.get<List<dynamic>>(_groupBase);
      return (res.data ?? const [])
          .map((e) => OutputGroup.fromJson(e as Map<String, dynamic>))
          .toList();
    } on DioException catch (e) {
      throw ApiException.fromDioException(e);
    }
  }

  Future<OutputGroup> createGroup({
    required List<String> memberIds,
    String name = '',
    String masterId = '',
  }) async {
    try {
      final res = await dio.post<Map<String, dynamic>>(
        _groupBase,
        data: {
          'name': name,
          'member_ids': memberIds,
          if (masterId.isNotEmpty) 'master_id': masterId,
        },
      );
      return OutputGroup.fromJson(res.data ?? const {});
    } on DioException catch (e) {
      throw ApiException.fromDioException(e);
    }
  }

  Future<OutputGroup> getGroup(String id) async {
    try {
      final res = await dio.get<Map<String, dynamic>>('$_groupBase/$id');
      return OutputGroup.fromJson(res.data ?? const {});
    } on DioException catch (e) {
      throw ApiException.fromDioException(e);
    }
  }

  /// 更新区域名称与图标。
  ///
  /// name 去空白后必须为 1~40 个字符；icon 必须在后端白名单内，空串表示
  /// 使用客户端默认图标。名称与图标存在服务端，换设备不丢。
  Future<OutputGroup> updateGroup(
    String id, {
    required String name,
    String icon = '',
  }) async {
    try {
      final res = await dio.put<Map<String, dynamic>>(
        '$_groupBase/$id',
        data: {'name': name, 'icon': icon},
      );
      return OutputGroup.fromJson(res.data ?? const {});
    } on DioException catch (e) {
      throw ApiException.fromDioException(e);
    }
  }

  /// 解散组：成员各自回到单机组。
  Future<void> deleteGroup(String id) async {
    try {
      await dio.delete<void>('$_groupBase/$id');
    } on DioException catch (e) {
      throw ApiException.fromDioException(e);
    }
  }

  /// 切换主控（决定组音量基准；播放中切换不断音）。
  Future<OutputGroup> setMaster(String groupId, String playerId) async {
    try {
      final res = await dio.post<Map<String, dynamic>>(
        '$_groupBase/$groupId/master',
        data: {'player_id': playerId},
      );
      return OutputGroup.fromJson(res.data ?? const {});
    } on DioException catch (e) {
      throw ApiException.fromDioException(e);
    }
  }

  Future<OutputGroup> addMember(String groupId, String playerId) async {
    try {
      final res = await dio.post<Map<String, dynamic>>(
        '$_groupBase/$groupId/members',
        data: {'player_id': playerId},
      );
      return OutputGroup.fromJson(res.data ?? const {});
    } on DioException catch (e) {
      throw ApiException.fromDioException(e);
    }
  }

  /// 调整成员的延迟补偿 / 音量偏移。
  Future<OutputGroup> updateMember(
    String groupId,
    String playerId, {
    int? delayMs,
    int? volumeOffset,
  }) async {
    try {
      final res = await dio.patch<Map<String, dynamic>>(
        '$_groupBase/$groupId/members/$playerId',
        data: {
          if (delayMs != null) 'delay_ms': delayMs,
          if (volumeOffset != null) 'volume_offset': volumeOffset,
        },
      );
      return OutputGroup.fromJson(res.data ?? const {});
    } on DioException catch (e) {
      throw ApiException.fromDioException(e);
    }
  }

  /// 调整成员顺序（必须是该组全部成员 id 的全排列）。
  ///
  /// 顺序只影响列表与"主控候选"提示，不改主控；非法顺序服务端返回 400。
  Future<OutputGroup> reorderMembers(
    String groupId,
    List<String> playerIds,
  ) async {
    try {
      final res = await dio.put<Map<String, dynamic>>(
        '$_groupBase/$groupId/members/order',
        data: {'player_ids': playerIds},
      );
      return OutputGroup.fromJson(res.data ?? const {});
    } on DioException catch (e) {
      throw ApiException.fromDioException(e);
    }
  }

  /// 移出成员。mode=continue 让它继续播自己的内容，stop 立即停止出声。
  Future<void> removeMember(
    String groupId,
    String playerId, {
    String mode = 'continue',
  }) async {
    try {
      await dio.delete<void>(
        '$_groupBase/$groupId/members/$playerId',
        queryParameters: {'mode': mode},
      );
    } on DioException catch (e) {
      throw ApiException.fromDioException(e);
    }
  }

  Future<GroupVolume> getGroupVolume(String groupId) async {
    try {
      final res = await dio.get<Map<String, dynamic>>(
        '$_groupBase/$groupId/volume',
      );
      return GroupVolume.fromJson(res.data ?? const {});
    } on DioException catch (e) {
      throw ApiException.fromDioException(e);
    }
  }

  /// 同步下发组音量；部分设备失败不回滚已成功的成员。
  Future<GroupVolume> setGroupVolume(
    String groupId, {
    required int volume,
    bool muted = false,
  }) async {
    try {
      final res = await dio.post<Map<String, dynamic>>(
        '$_groupBase/$groupId/volume',
        data: {'volume': volume, 'muted': muted},
      );
      return GroupVolume.fromJson(res.data ?? const {});
    } on DioException catch (e) {
      throw ApiException.fromDioException(e);
    }
  }

  /// 把播放（队列 + 位置）从 [fromGroupId] 转移到 [toGroupId]。
  ///
  /// [onlyPlayerId] 非空表示"只在这台音箱上播"：把它从原组拆出来单独成组。
  Future<void> transfer({
    required String fromGroupId,
    required String toGroupId,
    String onlyPlayerId = '',
  }) async {
    try {
      await dio.post<Map<String, dynamic>>(
        '$_groupBase/$toGroupId/transfer',
        data: {
          'from_group_id': fromGroupId,
          if (onlyPlayerId.isNotEmpty) 'only_player_id': onlyPlayerId,
        },
      );
    } on DioException catch (e) {
      throw ApiException.fromDioException(e);
    }
  }

  Future<OutputStatus> getQueue(String groupId) async {
    try {
      final res = await dio.get<Map<String, dynamic>>(
        '$_groupBase/$groupId/queue',
      );
      return OutputStatus.fromJson(res.data);
    } on DioException catch (e) {
      throw ApiException.fromDioException(e);
    }
  }

  /// 整体替换组队列并定位到 [index]（不自动播放）。
  ///
  /// 客户端是队列的编辑者：选歌、拖拽、删除都在本地完成，改完把整条队列
  /// 推给服务端，区域面板和别的客户端才能看到同一份队列。
  Future<OutputStatus> replaceQueue(
    String groupId,
    List<int> songIds, {
    int index = 0,
  }) async {
    try {
      final res = await dio.put<Map<String, dynamic>>(
        '$_groupBase/$groupId/queue',
        data: {'song_ids': songIds, 'index': index},
      );
      return OutputStatus.fromJson(res.data);
    } on DioException catch (e) {
      throw ApiException.fromDioException(e);
    }
  }

  /// 向组队列追加歌曲。
  ///
  /// [position] 为 `end`（默认，追加到队尾）或 `next`（按传入顺序插到
  /// 当前曲之后，即“下一首播放”）。服务端对未知值返回 400。
  Future<OutputStatus> addToQueue(
    String groupId,
    List<int> songIds, {
    String position = 'end',
  }) async {
    try {
      final res = await dio.post<Map<String, dynamic>>(
        '$_groupBase/$groupId/queue',
        data: {
          'song_ids': songIds,
          if (position.isNotEmpty) 'position': position,
        },
      );
      return OutputStatus.fromJson(res.data);
    } on DioException catch (e) {
      throw ApiException.fromDioException(e);
    }
  }

  /// 把歌曲插到当前曲之后（下一首播放）。
  ///
  /// 等价于 `addToQueue(position: 'next')`；队列为空时服务端从第一首
  /// 开始（不自动播放）。
  Future<OutputStatus> enqueueNext(String groupId, List<int> songIds) =>
      addToQueue(groupId, songIds, position: 'next');

  /// 组传输控制。action: play / pause / stop / next / prev / seek / repeat / shuffle。
  Future<OutputStatus> transport(
    String groupId, {
    required String action,
    double? position,
    String? repeat,
    bool? shuffle,
  }) async {
    try {
      final res = await dio.post<Map<String, dynamic>>(
        '$_groupBase/$groupId/transport',
        data: {
          'action': action,
          if (position != null) 'position': position,
          if (repeat != null) 'repeat': repeat,
          if (shuffle != null) 'shuffle': shuffle,
        },
      );
      return OutputStatus.fromJson(res.data);
    } on DioException catch (e) {
      throw ApiException.fromDioException(e);
    }
  }

  // ---------- 全量对齐 / 指标 ----------

  /// 全部组状态。断线重连后必须调一次做全量对齐，不能只依赖增量事件。
  Future<List<OutputGroup>> playback() async {
    try {
      final res = await dio.get<List<dynamic>>(_playbackBase);
      return (res.data ?? const [])
          .map((e) => OutputGroup.fromJson(e as Map<String, dynamic>))
          .toList();
    } on DioException catch (e) {
      throw ApiException.fromDioException(e);
    }
  }

  Future<PlaybackMetrics> metrics() async {
    try {
      final res = await dio.get<Map<String, dynamic>>('$_playbackBase/metrics');
      return PlaybackMetrics.fromJson(res.data ?? const {});
    } on DioException catch (e) {
      throw ApiException.fromDioException(e);
    }
  }

  // ---------- 派对 ----------

  Future<PartyStatus> partyStatus(String partyId) async {
    try {
      final res = await dio.get<Map<String, dynamic>>(
        '$_playbackBase/party/$partyId',
      );
      return PartyStatus.fromJson(res.data ?? const {});
    } on DioException catch (e) {
      throw ApiException.fromDioException(e);
    }
  }

  /// 创建派对。每个成员组各自解码，各占一个解码槽位；关闭派对返回 403。
  Future<PartyStatus> createParty({
    required List<String> groupIds,
    String name = '',
  }) async {
    try {
      final res = await dio.post<Map<String, dynamic>>(
        '$_playbackBase/party',
        data: {'name': name, 'group_ids': groupIds},
      );
      // 创建只返回 Party（无 members），补一次状态查询让 UI 直接可用。
      final id = res.data?['id'] as String? ?? '';
      if (id.isEmpty) return PartyStatus.fromJson(res.data ?? const {});
      // 必须 await：直接 return 会让 try/catch 抓不到这次请求的异常。
      return await partyStatus(id);
    } on DioException catch (e) {
      throw ApiException.fromDioException(e);
    }
  }

  /// action: join（带 groupId）/ leave（带 groupId + mode）/ end。
  Future<void> partyGroups(
    String partyId, {
    required String action,
    String groupId = '',
    String mode = '',
  }) async {
    try {
      await dio.post<Map<String, dynamic>>(
        '$_playbackBase/party/$partyId/groups',
        data: {
          'action': action,
          if (groupId.isNotEmpty) 'group_id': groupId,
          if (mode.isNotEmpty) 'mode': mode,
        },
      );
    } on DioException catch (e) {
      throw ApiException.fromDioException(e);
    }
  }

  /// action: play / pause / stop，作用于派对内全部组。
  Future<void> partyTransport(String partyId, String action) async {
    try {
      await dio.post<Map<String, dynamic>>(
        '$_playbackBase/party/$partyId/transport',
        data: {'action': action},
      );
    } on DioException catch (e) {
      throw ApiException.fromDioException(e);
    }
  }

  // ---------- 设置 ----------

  Future<PlayerOutputSetting> getOutputSetting() async {
    try {
      final res = await dio.get<Map<String, dynamic>>(
        '${AppConfig.apiPrefix}/settings/player-output',
      );
      return PlayerOutputSetting.fromJson(res.data ?? const {});
    } on DioException catch (e) {
      throw ApiException.fromDioException(e);
    }
  }

  Future<PlayerOutputSetting> updateOutputSetting(
    PlayerOutputSetting setting,
  ) async {
    try {
      final res = await dio.put<Map<String, dynamic>>(
        '${AppConfig.apiPrefix}/settings/player-output',
        data: setting.toJson(),
      );
      return PlayerOutputSetting.fromJson(res.data ?? const {});
    } on DioException catch (e) {
      throw ApiException.fromDioException(e);
    }
  }

  Future<PlayerDiscoverySetting> getDiscoverySetting() async {
    try {
      final res = await dio.get<Map<String, dynamic>>(
        '${AppConfig.apiPrefix}/settings/player-discovery',
      );
      return PlayerDiscoverySetting.fromJson(res.data ?? const {});
    } on DioException catch (e) {
      throw ApiException.fromDioException(e);
    }
  }

  Future<PlayerDiscoverySetting> updateDiscoverySetting(
    PlayerDiscoverySetting setting,
  ) async {
    try {
      final res = await dio.put<Map<String, dynamic>>(
        '${AppConfig.apiPrefix}/settings/player-discovery',
        data: setting.toJson(),
      );
      return PlayerDiscoverySetting.fromJson(res.data ?? const {});
    } on DioException catch (e) {
      throw ApiException.fromDioException(e);
    }
  }

  Future<PlayerOutputAllowlist> getOutputAllowlist() async {
    try {
      final res = await dio.get<Map<String, dynamic>>(
        '${AppConfig.apiPrefix}/settings/player-output-allowlist',
      );
      return PlayerOutputAllowlist.fromJson(res.data ?? const {});
    } on DioException catch (e) {
      throw ApiException.fromDioException(e);
    }
  }

  /// 条目支持 CIDR 与单个 IP；非法条目后端返回 400。
  Future<PlayerOutputAllowlist> updateOutputAllowlist(
    List<String> entries,
  ) async {
    try {
      final res = await dio.put<Map<String, dynamic>>(
        '${AppConfig.apiPrefix}/settings/player-output-allowlist',
        data: {'entries': entries},
      );
      return PlayerOutputAllowlist.fromJson(res.data ?? const {});
    } on DioException catch (e) {
      throw ApiException.fromDioException(e);
    }
  }

  // ---------- 交叉淡化 / ReplayGain ----------

  Future<CrossfadeSetting> getCrossfadeSetting() async {
    try {
      final res = await dio.get<Map<String, dynamic>>(
        '${AppConfig.apiPrefix}/settings/crossfade',
      );
      return CrossfadeSetting.fromJson(res.data ?? const {});
    } on DioException catch (e) {
      throw ApiException.fromDioException(e);
    }
  }

  Future<CrossfadeSetting> updateCrossfadeSetting(
    CrossfadeSetting setting,
  ) async {
    try {
      final res = await dio.put<Map<String, dynamic>>(
        '${AppConfig.apiPrefix}/settings/crossfade',
        data: setting.toJson(),
      );
      return CrossfadeSetting.fromJson(res.data ?? const {});
    } on DioException catch (e) {
      throw ApiException.fromDioException(e);
    }
  }

  Future<ReplayGainSetting> getReplayGainSetting() async {
    try {
      final res = await dio.get<Map<String, dynamic>>(
        '${AppConfig.apiPrefix}/settings/replaygain',
      );
      return ReplayGainSetting.fromJson(res.data ?? const {});
    } on DioException catch (e) {
      throw ApiException.fromDioException(e);
    }
  }

  Future<ReplayGainSetting> updateReplayGainSetting(
    ReplayGainSetting setting,
  ) async {
    try {
      final res = await dio.put<Map<String, dynamic>>(
        '${AppConfig.apiPrefix}/settings/replaygain',
        data: setting.toJson(),
      );
      return ReplayGainSetting.fromJson(res.data ?? const {});
    } on DioException catch (e) {
      throw ApiException.fromDioException(e);
    }
  }
}
