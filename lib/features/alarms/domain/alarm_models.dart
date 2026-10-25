/// 服务端闹钟（`/api/v1/alarms`）。
///
/// 时间是本地 `HH:MM`，不存绝对时刻——闹钟的语义是"每天 07:30"，
/// 存时间戳会跟着夏令时错位。`daysMask` 按 bit0=周一 … bit6=周日，
/// 127=每天，0=只在今天触发一次（靠 last_fired_at 保证只响一次）。
class Alarm {
  const Alarm({
    required this.id,
    this.name = '',
    required this.targetId,
    required this.timeOfDay,
    this.daysMask = 127,
    this.playlistId = 0,
    this.volume = 50,
    this.fadeSeconds = 0,
    this.enabled = true,
    this.lastFiredAt = '',
  });

  final String id;
  final String name;

  /// 组 id 或设备 id（后端会把设备解析成它所在的组）。
  final String targetId;
  final String timeOfDay;
  final int daysMask;

  /// 0 表示只调整音量、不起播。
  final int playlistId;
  final int volume;
  final int fadeSeconds;
  final bool enabled;

  /// 最近触发到的分钟（`YYYY-MM-DDTHH:MM`），空表示从未触发。
  final String lastFiredAt;

  factory Alarm.fromJson(Map<String, dynamic> json) => Alarm(
    id: json['id'] as String? ?? '',
    name: json['name'] as String? ?? '',
    targetId: json['target_id'] as String? ?? '',
    timeOfDay: json['time_of_day'] as String? ?? '07:30',
    daysMask: (json['days_mask'] as num?)?.toInt() ?? 127,
    playlistId: (json['playlist_id'] as num?)?.toInt() ?? 0,
    volume: (json['volume'] as num?)?.toInt() ?? 50,
    fadeSeconds: (json['fade_seconds'] as num?)?.toInt() ?? 0,
    enabled: json['enabled'] as bool? ?? true,
    lastFiredAt: json['last_fired_at'] as String? ?? '',
  );

  AlarmDraft toDraft() => AlarmDraft(
    name: name,
    targetId: targetId,
    timeOfDay: timeOfDay,
    daysMask: daysMask,
    playlistId: playlistId,
    volume: volume,
    fadeSeconds: fadeSeconds,
    enabled: enabled,
  );

  Alarm copyWith({bool? enabled}) => Alarm(
    id: id,
    name: name,
    targetId: targetId,
    timeOfDay: timeOfDay,
    daysMask: daysMask,
    playlistId: playlistId,
    volume: volume,
    fadeSeconds: fadeSeconds,
    enabled: enabled ?? this.enabled,
    lastFiredAt: lastFiredAt,
  );
}

/// 新建 / 更新请求体（与 `AlarmRequest` 一一对应）。
class AlarmDraft {
  const AlarmDraft({
    this.name = '',
    this.targetId = '',
    this.timeOfDay = '07:30',
    this.daysMask = 127,
    this.playlistId = 0,
    this.volume = 50,
    this.fadeSeconds = 0,
    this.enabled = true,
  });

  final String name;
  final String targetId;
  final String timeOfDay;
  final int daysMask;
  final int playlistId;
  final int volume;
  final int fadeSeconds;
  final bool enabled;

  Map<String, dynamic> toJson() => {
    'name': name,
    'target_id': targetId,
    'time_of_day': timeOfDay,
    'days_mask': daysMask,
    'playlist_id': playlistId,
    'volume': volume,
    'fade_seconds': fadeSeconds,
    'enabled': enabled,
  };

  AlarmDraft copyWith({
    String? name,
    String? targetId,
    String? timeOfDay,
    int? daysMask,
    int? playlistId,
    int? volume,
    int? fadeSeconds,
    bool? enabled,
  }) => AlarmDraft(
    name: name ?? this.name,
    targetId: targetId ?? this.targetId,
    timeOfDay: timeOfDay ?? this.timeOfDay,
    daysMask: daysMask ?? this.daysMask,
    playlistId: playlistId ?? this.playlistId,
    volume: volume ?? this.volume,
    fadeSeconds: fadeSeconds ?? this.fadeSeconds,
    enabled: enabled ?? this.enabled,
  );
}

/// 星期掩码的工具：bit0=周一。
class AlarmDays {
  static const labels = ['一', '二', '三', '四', '五', '六', '日'];

  static bool has(int mask, int index) => mask & (1 << index) != 0;

  static int toggle(int mask, int index) => mask ^ (1 << index);

  /// 127 → "每天"，0 → "仅一次"，其它 → "周一、周三"。
  static String describe(int mask) {
    if (mask == 127) return '每天';
    if (mask == 0) return '仅一次';
    final names = <String>[];
    for (var i = 0; i < 7; i++) {
      if (has(mask, i)) names.add('周${labels[i]}');
    }
    return names.isEmpty ? '未选择' : names.join('、');
  }
}
