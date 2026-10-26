import 'dart:convert';

/// 服务端播放事件（`/api/v1/playback/events`）。
///
/// 统一信封：`{seq, type, time_ms, ...}`。`seq` 由服务端全局单调递增，
/// 所有事件类型共用；客户端只需比较 `seq` 丢弃旧消息，不必按类型各维护一份。
/// 其余字段按事件类型出现（Go 侧 `omitempty`），完整契约见
/// `docs/architecture_playback.md` §7.4。
///
/// 刻意保留 [raw]：事件类型会随服务端演进增加字段，消费方（区域状态、
/// 设备列表、派对面板）可以在不升级客户端的情况下读取新字段。
class PlaybackEvent {
  const PlaybackEvent({
    required this.seq,
    required this.type,
    required this.timeMs,
    required this.raw,
  });

  /// 全局单调递增序号，用于去重 / 丢弃乱序消息。
  final int seq;

  /// 事件类型：`state` / `target_changed` / `member_changed` /
  /// `group_changed` / `speaker_seen` / `party_changed` / `group_drift` /
  /// `eq_changed` / `error`。
  final String type;

  /// 服务端产生事件的时间（Unix 毫秒）。
  final int timeMs;

  /// 原始 JSON 对象，保留服务端新增字段。
  final Map<String, dynamic> raw;

  /// 解析一条 WS 文本帧；格式不合法时返回 null（调用方直接丢弃）。
  static PlaybackEvent? tryParse(String payload) {
    try {
      final decoded = jsonDecode(payload);
      if (decoded is! Map<String, dynamic>) return null;
      return tryParseMap(decoded);
    } on FormatException {
      return null;
    } catch (_) {
      // jsonDecode 对非字符串输入、深层嵌套等也可能抛其它异常；
      // 单条坏消息不应打断整条事件流。
      return null;
    }
  }

  /// 从已解码的 JSON 对象解析；不是事件信封（例如服务端下发的
  /// `{cmd: "load"}` 指令）时返回 null。
  static PlaybackEvent? tryParseMap(Map<String, dynamic> json) {
    try {
      return PlaybackEvent.fromJson(json);
    } on FormatException {
      return null;
    } catch (_) {
      return null;
    }
  }

  /// 从 JSON 对象解析。缺少 `seq` / `type` 时抛 [FormatException]。
  factory PlaybackEvent.fromJson(Map<String, dynamic> json) {
    final seq = _asInt(json['seq']);
    final type = json['type'];
    if (seq == null || type is! String || type.isEmpty) {
      throw const FormatException('invalid playback event envelope');
    }
    return PlaybackEvent(
      seq: seq,
      type: type,
      timeMs: _asInt(json['time_ms']) ?? 0,
      raw: Map<String, dynamic>.unmodifiable(json),
    );
  }

  String get groupId => _asString(raw['group_id']) ?? '';
  String get fromGroupId => _asString(raw['from_group_id']) ?? '';
  String get partyId => _asString(raw['party_id']) ?? '';
  String get playerId => _asString(raw['player_id']) ?? '';
  int get songId => _asInt(raw['song_id']) ?? 0;
  int get positionMs => _asInt(raw['position_ms']) ?? 0;
  String get status => _asString(raw['status']) ?? '';
  String get action => _asString(raw['action']) ?? '';
  String get reason => _asString(raw['reason']) ?? '';
  String get name => _asString(raw['name']) ?? '';
  String get kind => _asString(raw['kind']) ?? '';
  String get code => _asString(raw['code']) ?? '';
  String get message => _asString(raw['message']) ?? '';
  String get preset => _asString(raw['preset']) ?? '';
  int get offsetMs => _asInt(raw['offset_ms']) ?? 0;
  bool? get enabled => _asBool(raw['enabled']);
  bool? get corrected => _asBool(raw['corrected']);
  bool? get unaligned => _asBool(raw['unaligned']);

  @override
  String toString() => 'PlaybackEvent(seq: $seq, type: $type)';

  static int? _asInt(Object? value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    if (value is String) return int.tryParse(value);
    return null;
  }

  static String? _asString(Object? value) => value is String ? value : null;

  static bool? _asBool(Object? value) {
    if (value is bool) return value;
    if (value is num) return value != 0;
    if (value is String) {
      if (value == 'true') return true;
      if (value == 'false') return false;
    }
    return null;
  }
}
