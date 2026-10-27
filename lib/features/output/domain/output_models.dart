/// 播放输出（设备 / 同步组 / 派对）的领域模型。
///
/// 字段名严格对齐后端 `internal/player` 的 JSON 输出，注意两种命名风格并存：
///
/// - `player.Player` 没有 json tag，key 是 Go 导出名（`ID` / `Caps` / `EQ`…），
///   只有 `standby` 是小写。所以解析时两种都要认，否则后端哪天补 tag
///   就会静默变成"所有设备都叫空名字"。
/// - 组、状态、指标这些新结构都有 json tag，key 是 snake_case。
///
/// 刻意不复用 player 特性里的播放器模型：那是"本机播放器"的界面状态，
/// 这里是"远端输出端"的设备事实（能力、在线、同步等级），混用会让
/// 「本机正在播的这首」和「客厅音箱的音量」互相覆盖。
library;

/// 设备类型。
enum OutputKind {
  local,
  raop,
  raat,
  dlna;

  static OutputKind parse(String? raw) {
    switch (raw) {
      case 'raop':
        return OutputKind.raop;
      case 'raat':
        return OutputKind.raat;
      case 'dlna':
        return OutputKind.dlna;
      default:
        return OutputKind.local; // 未知 kind 回退 local（旧服务端兼容）
    }
  }

  String get wire => name;

  String get label => switch (this) {
    OutputKind.local => '本机',
    OutputKind.raop => 'AirPlay',
    OutputKind.raat => 'RAAT',
    OutputKind.dlna => 'DLNA',
  };

  /// 是否走服务端推流（决定能不能进精确同步组）。
  bool get isNetwork => this != OutputKind.local;
}

/// 同步等级：precise 采样级（RAAT 共享时钟 ±1ms）、exact 靠 RTP 时间戳
/// 对齐（±20ms）、aligned 只能对齐起播。
enum SyncTier {
  precise,
  exact,
  aligned;

  static SyncTier parse(String? raw) {
    switch (raw) {
      case 'aligned':
        return SyncTier.aligned;
      case 'precise':
        return SyncTier.precise;
      default:
        return SyncTier.exact; // 未知值安全回退 exact（含旧服务端 null）
    }
  }

  String get label => switch (this) {
    SyncTier.precise => '采样级同步',
    SyncTier.exact => '精确同步',
    SyncTier.aligned => '起播对齐',
  };
}

/// 信号路径等级：决定区域行三色指示点。
///
/// 后端 `internal/player/signal_path.go` 的取值；未知值返回 null，避免未来
/// 新增等级时被误显示成某一种颜色。
enum SignalPathKind {
  lossless,
  enhanced,
  lossy;

  static SignalPathKind? parse(String? raw) {
    switch (raw) {
      case 'lossless':
        return SignalPathKind.lossless;
      case 'enhanced':
        return SignalPathKind.enhanced;
      case 'lossy':
        return SignalPathKind.lossy;
      default:
        return null;
    }
  }

  String get label => switch (this) {
    SignalPathKind.lossless => '无损直通',
    SignalPathKind.enhanced => '经 DSP',
    SignalPathKind.lossy => '有损转码',
  };
}

/// 信号链路中的一段（后端固定五段：源 / 解码 / DSP / 输出 / 设备）。
class SignalStage {
  const SignalStage({required this.name, required this.detail});

  final String name;
  final String detail;

  factory SignalStage.fromJson(Map<String, dynamic> json) => SignalStage(
    name: json['name'] is String ? json['name'] as String : '',
    detail: json['detail'] is String ? json['detail'] as String : '',
  );
}

/// 区域信号路径（GET /playback 的 `signal_path`）。
///
/// 只读诊断，不参与播放控制。旧服务端没有该字段时
/// [OutputGroup.signalPath] 为 null，UI 必须隐藏指示点。
class SignalPath {
  const SignalPath({required this.kind, this.stages = const <SignalStage>[]});

  final SignalPathKind kind;
  final List<SignalStage> stages;

  bool get isEmpty => stages.isEmpty;

  /// 解析失败（字段缺失 / kind 未知 / 类型不对）返回 null，不抛异常。
  static SignalPath? fromJson(dynamic json) {
    if (json is! Map) return null;
    final rawKind = json['kind'];
    final kind = SignalPathKind.parse(rawKind is String ? rawKind : null);
    if (kind == null) return null;

    final stages = <SignalStage>[];
    final rawStages = json['stages'];
    if (rawStages is List) {
      for (final raw in rawStages) {
        if (raw is Map) {
          stages.add(SignalStage.fromJson(Map<String, dynamic>.from(raw)));
        }
      }
    }
    return SignalPath(kind: kind, stages: stages);
  }
}

/// 播放状态机取值（后端 transport.State）。
class PlayState {
  static const idle = 'idle';
  static const buffering = 'buffering';
  static const playing = 'playing';
  static const paused = 'paused';
  static const error = 'error';
}

/// 设备能力。
class DeviceCaps {
  const DeviceCaps({
    this.codecs = const <String>[],
    this.maxSampleRate = 0,
    this.channels = 0,
    this.bitDepth = 0,
    this.supportsVolume = true,
    this.supportsSeek = true,
    this.latencyMs = 0,
    this.syncTier = SyncTier.exact,
    this.needsPassword = false,
    this.deviceId = '',
  });

  final List<String> codecs;
  final int maxSampleRate;
  final int channels;
  final int bitDepth;
  final bool supportsVolume;
  final bool supportsSeek;

  /// 设备固有缓冲（RAOP 默认 2000ms），用于时间轴对齐。
  final int latencyMs;
  final SyncTier syncTier;

  /// 设备要求密码（mDNS TXT pw=true），第一版直接跳过。
  final bool needsPassword;
  final String deviceId;

  factory DeviceCaps.fromJson(Map<String, dynamic>? json) {
    if (json == null) return const DeviceCaps();
    return DeviceCaps(
      codecs:
          (json['codecs'] as List?)?.map((e) => e.toString()).toList() ??
          const <String>[],
      maxSampleRate: (json['max_sample_rate'] as num?)?.toInt() ?? 0,
      channels: (json['channels'] as num?)?.toInt() ?? 0,
      bitDepth: (json['bit_depth'] as num?)?.toInt() ?? 0,
      supportsVolume: json['supports_volume'] as bool? ?? true,
      supportsSeek: json['supports_seek'] as bool? ?? true,
      latencyMs: (json['latency_ms'] as num?)?.toInt() ?? 0,
      syncTier: SyncTier.parse(json['sync_tier'] as String?),
      needsPassword: json['needs_password'] as bool? ?? false,
      deviceId: json['device_id'] as String? ?? '',
    );
  }
}

/// EQ 曲线（10 段 + preamp）。频段顺序 31/62/…/16k Hz。
class EqProfile {
  const EqProfile({
    this.enabled = false,
    this.preset = '',
    this.bands = const <double>[],
    this.preamp = 0,
  });

  final bool enabled;

  /// 上一次从预设套用的 id，仅用于 UI 高亮；服务端不记录"当前用哪个预设"。
  final String preset;
  final List<double> bands;

  /// 服务端按最大正增益算出的前级衰减（dB，≤0），前端直接用。
  final double preamp;

  /// 是否等价于不处理（决定该组要不要强制走服务端解码管线）。
  bool get isFlat {
    if (!enabled) return true;
    return bands.every((b) => b == 0);
  }

  factory EqProfile.fromJson(Map<String, dynamic>? json) {
    if (json == null) return const EqProfile();
    return EqProfile(
      enabled: json['enabled'] as bool? ?? false,
      preset: json['preset'] as String? ?? '',
      bands:
          (json['bands'] as List?)
              ?.map((e) => (e as num).toDouble())
              .toList() ??
          const <double>[],
      preamp: (json['preamp'] as num?)?.toDouble() ?? 0,
    );
  }

  Map<String, dynamic> toJson() => {
    'enabled': enabled,
    'preset': preset,
    'bands': bands,
    'preamp': preamp,
  };

  EqProfile copyWith({
    bool? enabled,
    String? preset,
    List<double>? bands,
    double? preamp,
  }) => EqProfile(
    enabled: enabled ?? this.enabled,
    preset: preset ?? this.preset,
    bands: bands ?? this.bands,
    preamp: preamp ?? this.preamp,
  );
}

/// 一台输出设备。
class OutputDevice {
  const OutputDevice({
    required this.id,
    required this.kind,
    required this.name,
    this.address = '',
    this.model = '',
    this.online = false,
    this.standby = false,
    this.volume = 0,
    this.muted = false,
    this.takeover = '',
    this.caps = const DeviceCaps(),
    this.eq = const EqProfile(),
  });

  final String id;
  final OutputKind kind;
  final String name;
  final String address;
  final String model;
  final bool online;

  /// 待机：服务端不再向它推流，成员已从分发与同步环里摘除。
  /// 只表示"我们没在推"，不代表设备真的断电。
  final bool standby;
  final int volume;
  final bool muted;

  /// local 设备被别的控制器接管时的行为：pause（默认）/ follow。
  final String takeover;
  final DeviceCaps caps;
  final EqProfile eq;

  /// 能作为播放目标：在线且不在待机。
  bool get usable => online && !standby;

  /// 能进精确同步组：在线、不待机、且设备本身支持精确对齐
  /// （precise 采样级同步也满足——比 exact 更强）。
  bool get exactCapable => usable && caps.syncTier != SyncTier.aligned;

  /// 名字兜底：mDNS 偶尔只给服务名。
  String get displayName => name.isNotEmpty ? name : id;

  factory OutputDevice.fromJson(Map<String, dynamic> json) {
    String pick(String lower, String upper) =>
        json[lower] as String? ?? json[upper] as String? ?? '';
    return OutputDevice(
      id: pick('id', 'ID'),
      kind: OutputKind.parse(
        json['kind'] as String? ?? json['Kind'] as String?,
      ),
      name: pick('name', 'Name'),
      address: pick('address', 'Address'),
      model: pick('model', 'Model'),
      online: json['online'] as bool? ?? json['Online'] as bool? ?? false,
      standby: json['standby'] as bool? ?? false,
      volume:
          (json['volume'] as num?)?.toInt() ??
          (json['Volume'] as num?)?.toInt() ??
          0,
      muted: json['muted'] as bool? ?? json['Muted'] as bool? ?? false,
      takeover:
          json['takeover'] as String? ?? json['Takeover'] as String? ?? '',
      caps: DeviceCaps.fromJson(
        json['caps'] as Map<String, dynamic>? ??
            json['Caps'] as Map<String, dynamic>?,
      ),
      eq: EqProfile.fromJson(
        json['eq'] as Map<String, dynamic>? ??
            json['EQ'] as Map<String, dynamic>?,
      ),
    );
  }
}

/// 组成员（含延迟补偿与音量偏移）。
class OutputMember {
  const OutputMember({
    required this.playerId,
    this.delayMs = 0,
    this.volumeOffset = 0,
  });

  final String playerId;

  /// 该设备额外延迟多少毫秒（修恒定偏移：设备自身缓冲比别的设备大）。
  final int delayMs;
  final int volumeOffset;

  factory OutputMember.fromJson(Map<String, dynamic> json) => OutputMember(
    playerId: json['player_id'] as String? ?? '',
    delayMs: (json['delay_ms'] as num?)?.toInt() ?? 0,
    volumeOffset: (json['volume_offset'] as num?)?.toInt() ?? 0,
  );
}

/// 成员能力摘要（前端用来提示"包含 DLNA 设备，只能起播对齐"）。
class MemberCaps {
  const MemberCaps({
    required this.playerId,
    this.kind = OutputKind.local,
    this.online = false,
    this.syncTier = SyncTier.exact,
    this.syncing = false,
  });

  final String playerId;
  final OutputKind kind;
  final bool online;
  final SyncTier syncTier;

  /// 刚入组 / 刚唤醒，还没走完一个校正周期：显示"对齐中"。
  final bool syncing;

  factory MemberCaps.fromJson(Map<String, dynamic> json) => MemberCaps(
    playerId: json['player_id'] as String? ?? '',
    kind: OutputKind.parse(json['kind'] as String?),
    online: json['online'] as bool? ?? false,
    syncTier: SyncTier.parse(json['sync_tier'] as String?),
    syncing: json['syncing'] as bool? ?? false,
  );
}

/// 队列快照。
class QueueSnapshot {
  const QueueSnapshot({
    this.items = const <int>[],
    this.current = 0,
    this.repeat = 'off',
    this.shuffle = false,
  });

  final List<int> items;
  final int current;
  final String repeat;
  final bool shuffle;

  bool get isEmpty => items.isEmpty;

  factory QueueSnapshot.fromJson(Map<String, dynamic>? json) {
    if (json == null) return const QueueSnapshot();
    return QueueSnapshot(
      items:
          (json['items'] as List?)?.map((e) => (e as num).toInt()).toList() ??
          const <int>[],
      current: (json['current'] as num?)?.toInt() ?? 0,
      repeat: json['repeat'] as String? ?? 'off',
      shuffle: json['shuffle'] as bool? ?? false,
    );
  }
}

/// 引擎状态（一个组或一个派对一个）。
class OutputStatus {
  const OutputStatus({
    this.ownerKind = '',
    this.ownerId = '',
    this.state = PlayState.idle,
    this.songId = 0,
    this.position = 0,
    this.repeat = 'off',
    this.shuffle = false,
    this.underruns = 0,
    this.error = '',
    this.queue = const QueueSnapshot(),
  });

  final String ownerKind;
  final String ownerId;
  final String state;
  final int songId;
  final double position;
  final String repeat;
  final bool shuffle;
  final int underruns;
  final String error;
  final QueueSnapshot queue;

  bool get isPlaying => state == PlayState.playing;
  bool get isBuffering => state == PlayState.buffering;

  /// 正在出声或缓冲，UI 才显示进度与暂停键。
  bool get isActive =>
      state == PlayState.playing ||
      state == PlayState.buffering ||
      state == PlayState.paused;

  factory OutputStatus.fromJson(Map<String, dynamic>? json) {
    if (json == null) return const OutputStatus();
    return OutputStatus(
      ownerKind: json['owner_kind'] as String? ?? '',
      ownerId: json['owner_id'] as String? ?? '',
      state: json['state'] as String? ?? PlayState.idle,
      songId: (json['song_id'] as num?)?.toInt() ?? 0,
      position: (json['position'] as num?)?.toDouble() ?? 0,
      repeat: json['repeat'] as String? ?? 'off',
      shuffle: json['shuffle'] as bool? ?? false,
      underruns: (json['underruns'] as num?)?.toInt() ?? 0,
      error: json['error'] as String? ?? '',
      queue: QueueSnapshot.fromJson(json['queue'] as Map<String, dynamic>?),
    );
  }
}

/// 同步组（含只含自己的单机组）。
class OutputGroup {
  const OutputGroup({
    required this.id,
    required this.name,
    this.icon = '',
    this.masterId = '',
    this.partyId = '',
    this.members = const <OutputMember>[],
    this.syncTier = SyncTier.exact,
    this.memberCaps = const <MemberCaps>[],
    this.status = const OutputStatus(),
    this.signalPath,
  });

  final String id;
  final String name;

  /// 区域图标 key（白名单见后端 manager.go），空串表示客户端默认图标。
  final String icon;
  final String masterId;
  final String partyId;
  final List<OutputMember> members;

  /// 全组能力汇总：任一成员不是 exact，整组就是 aligned。
  final SyncTier syncTier;
  final List<MemberCaps> memberCaps;
  final OutputStatus status;

  /// 只读信号链路诊断；旧服务端没有 `signal_path` 时为 null。
  final SignalPath? signalPath;

  bool get isSolo => members.length <= 1;
  bool get isPlaying => status.isPlaying;

  List<String> get memberIds => members.map((m) => m.playerId).toList();

  /// 组里有设备离线：UI 要提示"包含离线设备"，否则用户以为声音丢了。
  bool get hasOfflineMember => memberCaps.any((c) => !c.online);

  factory OutputGroup.fromJson(Map<String, dynamic> json) => OutputGroup(
    id: json['id'] as String? ?? '',
    name: json['name'] as String? ?? '',
    icon: json['icon'] as String? ?? '',
    masterId: json['master_id'] as String? ?? '',
    partyId: json['party_id'] as String? ?? '',
    members:
        (json['members'] as List?)
            ?.map((e) => OutputMember.fromJson(e as Map<String, dynamic>))
            .toList() ??
        const <OutputMember>[],
    syncTier: SyncTier.parse(json['sync_tier'] as String?),
    memberCaps:
        (json['member_caps'] as List?)
            ?.map((e) => MemberCaps.fromJson(e as Map<String, dynamic>))
            .toList() ??
        const <MemberCaps>[],
    status: OutputStatus.fromJson(json['status'] as Map<String, dynamic>?),
    signalPath: SignalPath.fromJson(json['signal_path']),
  );
}

/// 组内单个成员的实际音量（基准 + 偏移，已 clamp 到 0-100）。
class GroupVolumeMember {
  const GroupVolumeMember({
    required this.playerId,
    this.volume = 0,
    this.volumeOffset = 0,
    this.ok = true,
    this.error = '',
  });

  final String playerId;
  final int volume;
  final int volumeOffset;
  final bool ok;

  /// 该设备下发失败的原因（其余设备不回滚）。
  final String error;

  factory GroupVolumeMember.fromJson(Map<String, dynamic> json) =>
      GroupVolumeMember(
        playerId: json['player_id'] as String? ?? '',
        volume: (json['volume'] as num?)?.toInt() ?? 0,
        volumeOffset: (json['volume_offset'] as num?)?.toInt() ?? 0,
        ok: json['ok'] as bool? ?? true,
        error: json['error'] as String? ?? '',
      );
}

/// 组音量（基准 + 每成员实际值）。
class GroupVolume {
  const GroupVolume({
    this.volume = 0,
    this.muted = false,
    this.members = const <GroupVolumeMember>[],
  });

  final int volume;
  final bool muted;
  final List<GroupVolumeMember> members;

  List<GroupVolumeMember> get failed =>
      members.where((m) => !m.ok).toList(growable: false);

  factory GroupVolume.fromJson(Map<String, dynamic> json) => GroupVolume(
    volume: (json['volume'] as num?)?.toInt() ?? 0,
    muted: json['muted'] as bool? ?? false,
    members:
        (json['members'] as List?)
            ?.map((e) => GroupVolumeMember.fromJson(e as Map<String, dynamic>))
            .toList() ??
        const <GroupVolumeMember>[],
  );
}

/// EQ 预设（服务端算好 preamp，前端直接 PUT 回去）。
class EqPreset {
  const EqPreset({
    required this.id,
    required this.name,
    this.bands = const <double>[],
    this.preamp = 0,
  });

  final String id;
  final String name;
  final List<double> bands;
  final double preamp;

  factory EqPreset.fromJson(Map<String, dynamic> json) => EqPreset(
    id: json['id'] as String? ?? '',
    name: json['name'] as String? ?? '',
    bands:
        (json['bands'] as List?)?.map((e) => (e as num).toDouble()).toList() ??
        const <double>[],
    preamp: (json['preamp'] as num?)?.toDouble() ?? 0,
  );
}

/// 派对内单个组的同步情况。
class PartyMember {
  const PartyMember({
    required this.groupId,
    this.offsetMs = 0,
    this.state = PlayState.idle,
    this.drifting = false,
    this.unaligned = false,
  });

  final String groupId;
  final int offsetMs;
  final String state;

  /// 偏差超过 party_drift_tolerance_ms：显示"未对齐"，不要反复弹提示。
  final bool drifting;

  /// 连续校正失败已放弃重试。
  final bool unaligned;

  factory PartyMember.fromJson(Map<String, dynamic> json) => PartyMember(
    groupId: json['group_id'] as String? ?? '',
    offsetMs: (json['offset_ms'] as num?)?.toInt() ?? 0,
    state: json['state'] as String? ?? PlayState.idle,
    drifting: json['drifting'] as bool? ?? false,
    unaligned: json['unaligned'] as bool? ?? false,
  );
}

/// 派对状态（含主控组状态与各组偏移）。
class PartyStatus {
  const PartyStatus({
    required this.id,
    required this.name,
    this.leaderGroupId = '',
    this.groups = const <String>[],
    this.leaderStatus = const OutputStatus(),
    this.members = const <PartyMember>[],
  });

  final String id;
  final String name;
  final String leaderGroupId;
  final List<String> groups;
  final OutputStatus leaderStatus;
  final List<PartyMember> members;

  bool get hasDrift => members.any((m) => m.drifting || m.unaligned);

  factory PartyStatus.fromJson(Map<String, dynamic> json) => PartyStatus(
    id: json['id'] as String? ?? '',
    name: json['name'] as String? ?? '',
    leaderGroupId: json['leader_group_id'] as String? ?? '',
    groups:
        (json['groups'] as List?)?.map((e) => e.toString()).toList() ??
        const <String>[],
    leaderStatus: OutputStatus.fromJson(
      json['leader_status'] as Map<String, dynamic>?,
    ),
    members:
        (json['members'] as List?)
            ?.map((e) => PartyMember.fromJson(e as Map<String, dynamic>))
            .toList() ??
        const <PartyMember>[],
  );
}

/// 单个在播 owner（组 / 派对）的指标明细。
class OwnerMetrics {
  const OwnerMetrics({
    required this.owner,
    this.groupId = '',
    this.partyId = '',
    this.state = PlayState.idle,
    this.songId = 0,
    this.position = 0,
    this.driftMs = 0,
    this.targets = 0,
    this.buffering = false,
  });

  final String owner;
  final String groupId;
  final String partyId;
  final String state;
  final int songId;
  final double position;
  final int driftMs;
  final int targets;

  /// 长时间停在缓冲说明下游写不进去，比 underruns 更早暴露问题。
  final bool buffering;

  factory OwnerMetrics.fromJson(Map<String, dynamic> json) => OwnerMetrics(
    owner: json['owner'] as String? ?? '',
    groupId: json['group_id'] as String? ?? '',
    partyId: json['party_id'] as String? ?? '',
    state: json['state'] as String? ?? PlayState.idle,
    songId: (json['song_id'] as num?)?.toInt() ?? 0,
    position: (json['position'] as num?)?.toDouble() ?? 0,
    driftMs: (json['drift_ms'] as num?)?.toInt() ?? 0,
    targets: (json['targets'] as num?)?.toInt() ?? 0,
    buffering: json['buffering'] as bool? ?? false,
  );
}

/// 运行指标快照（排查"声音卡"是解码跟不上还是网络慢）。
class PlaybackMetrics {
  const PlaybackMetrics({
    this.decodeSlotsUsed = 0,
    this.decodeSlotsMax = 0,
    this.underrunsTotal = 0,
    this.droppedFramesTotal = 0,
    this.resyncsTotal = 0,
    this.eventsDroppedTotal = 0,
    this.driftMs = 0,
    this.groups = 0,
    this.players = 0,
    this.owners = const <OwnerMetrics>[],
  });

  final int decodeSlotsUsed;
  final int decodeSlotsMax;

  /// 欠载补静音帧数：解码跟不上。
  final int underrunsTotal;

  /// 分发队列丢帧：下游写不进去。
  final int droppedFramesTotal;

  /// 偏差超限重挂次数。
  final int resyncsTotal;
  final int eventsDroppedTotal;

  /// 所有 owner 里最近一次校正偏差的最大值。
  final int driftMs;
  final int groups;
  final int players;
  final List<OwnerMetrics> owners;

  bool get decodeSaturated =>
      decodeSlotsMax > 0 && decodeSlotsUsed >= decodeSlotsMax;

  factory PlaybackMetrics.fromJson(Map<String, dynamic> json) =>
      PlaybackMetrics(
        decodeSlotsUsed: (json['decode_slots_used'] as num?)?.toInt() ?? 0,
        decodeSlotsMax: (json['decode_slots_max'] as num?)?.toInt() ?? 0,
        underrunsTotal: (json['player_underruns_total'] as num?)?.toInt() ?? 0,
        droppedFramesTotal:
            (json['player_sink_dropped_frames_total'] as num?)?.toInt() ?? 0,
        resyncsTotal: (json['player_resyncs_total'] as num?)?.toInt() ?? 0,
        eventsDroppedTotal:
            (json['player_events_dropped_total'] as num?)?.toInt() ?? 0,
        driftMs: (json['player_drift_ms'] as num?)?.toInt() ?? 0,
        groups: (json['groups'] as num?)?.toInt() ?? 0,
        players: (json['players'] as num?)?.toInt() ?? 0,
        owners:
            (json['owners'] as List?)
                ?.map((e) => OwnerMetrics.fromJson(e as Map<String, dynamic>))
                .toList() ??
            const <OwnerMetrics>[],
      );
}

/// 输出与派对配置（GET/PUT /settings/player-output）。
class PlayerOutputSetting {
  const PlayerOutputSetting({
    this.maxGroups = 4,
    this.defaultLatencyMs = 2000,
    this.dlnaRealignIntervalMinutes = 0,
    this.allowPrivateNetwork = true,
    this.networkSinksEnabled = true,
    this.partyEnabled = true,
    this.partyDriftToleranceMs = 1500,
  });

  final int maxGroups;
  final int defaultLatencyMs;

  /// 0 表示不周期性重对齐（只在检测到漂移时校正）。
  final int dlnaRealignIntervalMinutes;
  final bool allowPrivateNetwork;

  /// 是否允许网络音箱。iOS Bundle 恒为 false，桌面 Bundle 需显式开启。
  final bool networkSinksEnabled;
  final bool partyEnabled;
  final int partyDriftToleranceMs;

  factory PlayerOutputSetting.fromJson(Map<String, dynamic> json) =>
      PlayerOutputSetting(
        maxGroups: (json['max_groups'] as num?)?.toInt() ?? 4,
        defaultLatencyMs: (json['default_latency_ms'] as num?)?.toInt() ?? 2000,
        dlnaRealignIntervalMinutes:
            (json['dlna_realign_interval_minutes'] as num?)?.toInt() ?? 0,
        allowPrivateNetwork: json['allow_private_network'] as bool? ?? true,
        networkSinksEnabled: json['network_sinks_enabled'] as bool? ?? true,
        partyEnabled: json['party_enabled'] as bool? ?? true,
        partyDriftToleranceMs:
            (json['party_drift_tolerance_ms'] as num?)?.toInt() ?? 1500,
      );

  /// 全量 PUT：后端会先读旧值再覆盖，这里仍然带全字段，避免依赖该兜底。
  Map<String, dynamic> toJson() => {
    'max_groups': maxGroups,
    'default_latency_ms': defaultLatencyMs,
    'dlna_realign_interval_minutes': dlnaRealignIntervalMinutes,
    'allow_private_network': allowPrivateNetwork,
    'network_sinks_enabled': networkSinksEnabled,
    'party_enabled': partyEnabled,
    'party_drift_tolerance_ms': partyDriftToleranceMs,
  };

  PlayerOutputSetting copyWith({
    int? maxGroups,
    int? defaultLatencyMs,
    int? dlnaRealignIntervalMinutes,
    bool? allowPrivateNetwork,
    bool? networkSinksEnabled,
    bool? partyEnabled,
    int? partyDriftToleranceMs,
  }) => PlayerOutputSetting(
    maxGroups: maxGroups ?? this.maxGroups,
    defaultLatencyMs: defaultLatencyMs ?? this.defaultLatencyMs,
    dlnaRealignIntervalMinutes:
        dlnaRealignIntervalMinutes ?? this.dlnaRealignIntervalMinutes,
    allowPrivateNetwork: allowPrivateNetwork ?? this.allowPrivateNetwork,
    networkSinksEnabled: networkSinksEnabled ?? this.networkSinksEnabled,
    partyEnabled: partyEnabled ?? this.partyEnabled,
    partyDriftToleranceMs: partyDriftToleranceMs ?? this.partyDriftToleranceMs,
  );
}

/// 设备发现配置（GET/PUT /settings/player-discovery）。
class PlayerDiscoverySetting {
  const PlayerDiscoverySetting({
    this.enabled = true,
    this.protocols = const ['raop', 'dlna'],
    this.intervalSeconds = 30,
  });

  final bool enabled;
  final List<String> protocols;
  final int intervalSeconds;

  factory PlayerDiscoverySetting.fromJson(Map<String, dynamic> json) =>
      PlayerDiscoverySetting(
        enabled: json['enabled'] as bool? ?? true,
        protocols:
            (json['protocols'] as List?)?.map((e) => e.toString()).toList() ??
            const ['raop', 'dlna'],
        intervalSeconds: (json['interval_seconds'] as num?)?.toInt() ?? 30,
      );

  Map<String, dynamic> toJson() => {
    'enabled': enabled,
    'protocols': protocols,
    'interval_seconds': intervalSeconds,
  };

  PlayerDiscoverySetting copyWith({
    bool? enabled,
    List<String>? protocols,
    int? intervalSeconds,
  }) => PlayerDiscoverySetting(
    enabled: enabled ?? this.enabled,
    protocols: protocols ?? this.protocols,
    intervalSeconds: intervalSeconds ?? this.intervalSeconds,
  );
}

/// 播放器出口白名单（GET/PUT /settings/player-output-allowlist）。
///
/// 与代理白名单是两套配置：空数组表示私网不限制，非空则收敛到这些网段，
/// 公网恒拒绝。
class PlayerOutputAllowlist {
  const PlayerOutputAllowlist({this.entries = const <String>[]});

  final List<String> entries;

  factory PlayerOutputAllowlist.fromJson(Map<String, dynamic> json) =>
      PlayerOutputAllowlist(
        entries:
            (json['entries'] as List?)?.map((e) => e.toString()).toList() ??
            const <String>[],
      );

  Map<String, dynamic> toJson() => {'entries': entries};
}

/// 一次扫描发现的音箱（还没登记成设备）。
class DiscoveredSpeaker {
  const DiscoveredSpeaker({
    required this.id,
    required this.kind,
    this.name = '',
    this.model = '',
    this.address = '',
    this.caps = const DeviceCaps(),
  });

  final String id;
  final OutputKind kind;
  final String name;
  final String model;
  final String address;
  final DeviceCaps caps;

  factory DiscoveredSpeaker.fromJson(Map<String, dynamic> json) =>
      DiscoveredSpeaker(
        id: json['id'] as String? ?? '',
        kind: OutputKind.parse(json['kind'] as String?),
        name: json['name'] as String? ?? '',
        model: json['model'] as String? ?? '',
        address: json['address'] as String? ?? '',
        caps: DeviceCaps.fromJson(json['caps'] as Map<String, dynamic>?),
      );
}

/// 被跳过的音箱（目前只有"需要密码"）。
class SkippedSpeaker {
  const SkippedSpeaker({required this.id, this.name = '', this.reason = ''});

  final String id;
  final String name;
  final String reason;

  factory SkippedSpeaker.fromJson(Map<String, dynamic> json) => SkippedSpeaker(
    id: json['id'] as String? ?? '',
    name: json['name'] as String? ?? '',
    reason: json['reason'] as String? ?? '',
  );
}

/// 手动扫描的结果。
class DiscoveryResult {
  const DiscoveryResult({
    this.speakers = const <DiscoveredSpeaker>[],
    this.added = const <String>[],
    this.updated = const <String>[],
    this.skipped = const <SkippedSpeaker>[],
    this.errors = const <String>[],
  });

  final List<DiscoveredSpeaker> speakers;

  /// 本次新登记的设备 id。
  final List<String> added;

  /// 已在库、本次刷新了地址 / 能力的设备 id。
  final List<String> updated;
  final List<SkippedSpeaker> skipped;

  /// 单个协议的失败原因（一个协议挂了不影响另一个）。
  final List<String> errors;

  bool get isEmpty =>
      speakers.isEmpty && added.isEmpty && updated.isEmpty && skipped.isEmpty;

  factory DiscoveryResult.fromJson(Map<String, dynamic> json) =>
      DiscoveryResult(
        speakers:
            (json['speakers'] as List?)
                ?.map(
                  (e) => DiscoveredSpeaker.fromJson(e as Map<String, dynamic>),
                )
                .toList() ??
            const <DiscoveredSpeaker>[],
        added:
            (json['added'] as List?)?.map((e) => e.toString()).toList() ??
            const <String>[],
        updated:
            (json['updated'] as List?)?.map((e) => e.toString()).toList() ??
            const <String>[],
        skipped:
            (json['skipped'] as List?)
                ?.map((e) => SkippedSpeaker.fromJson(e as Map<String, dynamic>))
                .toList() ??
            const <SkippedSpeaker>[],
        errors:
            (json['errors'] as List?)?.map((e) => e.toString()).toList() ??
            const <String>[],
      );
}

/// 交叉淡化配置（GET/PUT /settings/crossfade）。
///
/// 开启后交界处用等功率混合，**放弃 gapless 接续**（服务端单解码源下只能
/// 二选一）；默认关闭，行为与没有这个功能时一致。
class CrossfadeSetting {
  const CrossfadeSetting({this.enabled = false, this.seconds = 3});

  final bool enabled;

  /// 淡化时长，0.5–12 秒。enabled=false 时后端忽略。
  final double seconds;

  factory CrossfadeSetting.fromJson(Map<String, dynamic> json) =>
      CrossfadeSetting(
        enabled: json['enabled'] as bool? ?? false,
        seconds: (json['seconds'] as num?)?.toDouble() ?? 3,
      );

  Map<String, dynamic> toJson() => {'enabled': enabled, 'seconds': seconds};

  CrossfadeSetting copyWith({bool? enabled, double? seconds}) =>
      CrossfadeSetting(
        enabled: enabled ?? this.enabled,
        seconds: seconds ?? this.seconds,
      );
}

/// ReplayGain 响度均衡配置（GET/PUT /settings/replaygain）。
class ReplayGainSetting {
  const ReplayGainSetting({this.mode = 'off', this.preventClipping = true});

  /// `off` / `track` / `album`。
  final String mode;

  /// 按 peak 标签限制正增益，避免削波。
  final bool preventClipping;

  factory ReplayGainSetting.fromJson(Map<String, dynamic> json) =>
      ReplayGainSetting(
        mode: json['mode'] as String? ?? 'off',
        preventClipping: json['prevent_clipping'] as bool? ?? true,
      );

  Map<String, dynamic> toJson() => {
    'mode': mode,
    'prevent_clipping': preventClipping,
  };

  ReplayGainSetting copyWith({String? mode, bool? preventClipping}) =>
      ReplayGainSetting(
        mode: mode ?? this.mode,
        preventClipping: preventClipping ?? this.preventClipping,
      );
}
