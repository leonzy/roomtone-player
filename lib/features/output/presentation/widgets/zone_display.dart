import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../config/app_config.dart';
import '../../../library/presentation/providers/songs_provider.dart';
import '../../domain/output_models.dart';
import '../providers/output_provider.dart';
import '../providers/zone_focus_provider.dart';

/// 区域图标白名单（与后端 `internal/player/manager.go` 的 groupIcons 一致）。
const Map<String, IconData> zoneIconKeys = <String, IconData>{
  'speaker': Icons.speaker_rounded,
  'bookshelf': Icons.shelves,
  'soundbar': Icons.speaker,
  'headphone': Icons.headphones_rounded,
  'tv': Icons.tv_rounded,
  'phone': Icons.phone_iphone_rounded,
  'laptop': Icons.laptop_mac_rounded,
  'multiroom': Icons.speaker_group_rounded,
};

/// 区域在 UI 上的投影：一个真实 group，或“本机”哨兵。
///
/// 只做展示层聚合，不复制服务端状态：所有字段都从 [OutputState] 派生。
class ZoneEntry {
  const ZoneEntry({
    required this.id,
    required this.name,
    required this.icon,
    required this.isLocal,
    required this.online,
    required this.sameNetwork,
    required this.status,
    required this.partyId,
    required this.members,
    required this.volume,
    this.group,
  });

  /// 真实 group id；本机哨兵为 [kLocalZoneId]。
  final String id;
  final String name;

  /// 图标 key（空串 = 默认图标）。
  final String icon;
  final bool isLocal;
  final bool online;

  /// 是否与服务端同网段（用于“在线→同网→名称”排序）。
  final bool sameNetwork;
  final OutputStatus status;
  final String partyId;
  final List<OutputMember> members;

  /// 区域基准音量（取主控设备，回退第一个成员）。
  final int volume;

  /// null 表示本机哨兵：服务端还没有本机区域，不能发组命令。
  final OutputGroup? group;

  bool get isReal => group != null;
  bool get isSynthetic => group == null;

  /// 服务端下发的只读信号链路；旧服务端没有该字段时为 null。
  SignalPath? get signalPath => group?.signalPath;

  bool get isPlaying => status.isPlaying;
  bool get isPaused => status.state == PlayState.paused;
  bool get isActive => status.isActive;
  bool get canControl => isReal && online;
}

/// 从输出状态派生区域列表：真实组 + 必要时补一个“本机”哨兵。
///
/// 本机永远在列表里（P9）：即使没有任何音箱、甚至本机还没注册成功，
/// 也要给用户一个可聚焦的“本机”，而不是空白列表。
List<ZoneEntry> buildZoneEntries(OutputState state, {String? localDeviceId}) {
  // 「本机区域」= 成员里有**本机设备**，不是「成员里有 kind=local 的设备」：
  // 别的客户端（手机 / 另一个浏览器）注册的也是 local，按 kind 判断会把
  // 别人的区域当成自己的，在本机播别人的歌并污染本机所在区域的状态。
  final localPlayerIds = <String>{};
  for (final p in state.players) {
    if (p.kind == OutputKind.local) localPlayerIds.add(p.id);
  }

  final entries = <ZoneEntry>[];
  var hasLocalGroup = false;
  for (final group in state.groups) {
    final isLocal =
        localDeviceId != null && localDeviceId.isNotEmpty
            ? group.memberIds.contains(localDeviceId)
            // 设备 id 还没读出来（启动瞬间）：退回旧判定，避免列表闪一下。
            : group.memberIds.any(localPlayerIds.contains);
    if (isLocal) hasLocalGroup = true;
    entries.add(_entryFromGroup(group, state, isLocal: isLocal));
  }

  if (!hasLocalGroup) {
    final local = _firstLocalDevice(state);
    entries.add(
      ZoneEntry(
        id: kLocalZoneId,
        name: _localZoneName(local),
        icon: 'phone',
        isLocal: true,
        online: true,
        sameNetwork: true,
        status: const OutputStatus(),
        partyId: '',
        members: const <OutputMember>[],
        volume: local?.volume ?? 0,
      ),
    );
  }

  entries.sort(compareZoneEntries);
  return entries;
}

/// 解析当前焦点区域；焦点失效时回退到含本机的区域，再回退到第一个区域。
ZoneEntry? resolveFocusedZone(
  OutputState state,
  String? focusId, {
  String? localDeviceId,
}) {
  final entries = buildZoneEntries(state, localDeviceId: localDeviceId);
  if (entries.isEmpty) return null;

  if (focusId != null && focusId.isNotEmpty) {
    for (final entry in entries) {
      if (entry.id == focusId) return entry;
    }
    // 本机哨兵在真实本机组出现后会被替换：按“本机”语义继续匹配。
    if (focusId == kLocalZoneId) {
      for (final entry in entries) {
        if (entry.isLocal) return entry;
      }
    }
  }

  for (final entry in entries) {
    if (entry.isLocal) return entry;
  }
  return entries.first;
}

/// 焦点点是否为实心：显式 id 命中，或“本机”语义命中。
bool isZoneFocused(ZoneEntry entry, String? focusId) {
  if (focusId == entry.id) return true;
  if (entry.isLocal &&
      (focusId == null || focusId.isEmpty || focusId == kLocalZoneId)) {
    return true;
  }
  return false;
}

/// 排序：在线 → 同网 → 名称（不区分大小写）。
int compareZoneEntries(ZoneEntry a, ZoneEntry b) {
  if (a.online != b.online) return a.online ? -1 : 1;
  if (a.sameNetwork != b.sameNetwork) return a.sameNetwork ? -1 : 1;
  return a.name.toLowerCase().compareTo(b.name.toLowerCase());
}

/// 区域图标：优先服务端白名单 key，其次按本机/单机/多成员给默认图标。
IconData zoneIconFor(ZoneEntry zone) {
  final mapped = zoneIconKeys[zone.icon];
  if (mapped != null) return mapped;
  if (zone.isLocal) {
    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
      case TargetPlatform.iOS:
        return Icons.phone_iphone_rounded;
      default:
        return Icons.laptop_mac_rounded;
    }
  }
  return zone.members.length > 1
      ? Icons.speaker_group_rounded
      : Icons.speaker_rounded;
}

/// 状态文案：离线优先，其次播放状态机。
String zoneStatusLabel(ZoneEntry zone) {
  if (!zone.online) return '离线';
  switch (zone.status.state) {
    case PlayState.playing:
      return '正在播放';
    case PlayState.paused:
      return '已暂停';
    case PlayState.buffering:
      return '缓冲中';
    case PlayState.error:
      return '播放错误';
    default:
      return '空闲';
  }
}

/// 状态点颜色：绿=播放，琥珀=暂停，蓝=缓冲，红=错误，灰=空闲/离线。
Color zoneStatusColor(ThemeData theme, ZoneEntry zone) {
  if (!zone.online) return theme.colorScheme.outline;
  switch (zone.status.state) {
    case PlayState.playing:
      return const Color(0xFF2E7D32);
    case PlayState.paused:
      return const Color(0xFFF9A825);
    case PlayState.buffering:
      return theme.colorScheme.primary;
    case PlayState.error:
      return theme.colorScheme.error;
    default:
      return theme.colorScheme.outline;
  }
}

/// 状态行：`正在播放 · 晴天 — 周杰伦` / `空闲`。
///
/// 曲名通过 `songDetailProvider` 按 song_id 懒加载；没有 song_id 时不发请求。
class ZoneStatusLine extends ConsumerWidget {
  const ZoneStatusLine({super.key, required this.zone});

  final ZoneEntry zone;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final label = zoneStatusLabel(zone);
    final songId = zone.status.songId;
    if (songId <= 0) {
      return Text(
        label,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      );
    }

    final song = ref.watch(songDetailProvider(songId)).value;
    final title = song?.title;
    final artist = song?.artist;
    final suffix =
        title == null
            ? '歌曲 #$songId'
            : (artist == null || artist.isEmpty ? title : '$title — $artist');
    return Text(
      '$label · $suffix',
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: theme.textTheme.bodySmall?.copyWith(
        color: theme.colorScheme.onSurfaceVariant,
      ),
    );
  }
}

ZoneEntry _entryFromGroup(
  OutputGroup group,
  OutputState state, {
  required bool isLocal,
}) {
  return ZoneEntry(
    id: group.id,
    name: _groupZoneName(group, state, isLocal: isLocal),
    icon: group.icon,
    isLocal: isLocal,
    online: _groupOnline(group, state),
    sameNetwork: _groupSameNetwork(group, state, isLocal: isLocal),
    status: group.status,
    partyId: group.partyId,
    members: group.members,
    volume: _groupVolume(group, state),
    group: group,
  );
}

String _groupZoneName(
  OutputGroup group,
  OutputState state, {
  required bool isLocal,
}) {
  final name = group.name.trim();
  if (name.isNotEmpty) return name;
  if (isLocal) return _localZoneName(_firstLocalDevice(state));
  if (group.isSolo && group.members.isNotEmpty) {
    final player = state.playerOf(group.members.first.playerId);
    final playerName = player?.displayName.trim() ?? '';
    if (playerName.isNotEmpty) return playerName;
  }
  return '区域';
}

String _localZoneName(OutputDevice? local) {
  final name = local?.displayName.trim() ?? '';
  if (name.isEmpty || name == '本机') return '本机';
  return '本机（$name）';
}

OutputDevice? _firstLocalDevice(OutputState state) {
  for (final player in state.players) {
    if (player.kind == OutputKind.local) return player;
  }
  return null;
}

bool _groupOnline(OutputGroup group, OutputState state) {
  if (group.memberCaps.isNotEmpty) {
    return group.memberCaps.any((caps) => caps.online);
  }
  if (group.members.isEmpty) return false;
  for (final member in group.members) {
    final player = state.playerOf(member.playerId);
    if (player != null && player.online) return true;
  }
  return false;
}

int _groupVolume(OutputGroup group, OutputState state) {
  final master = state.playerOf(group.masterId);
  if (master != null) return master.volume;
  for (final member in group.members) {
    final player = state.playerOf(member.playerId);
    if (player != null) return player.volume;
  }
  return 0;
}

/// “同网”判定：本机恒为同网；网络设备与服务端地址在同一 /24 网段。
///
/// 服务端地址是 localhost / 域名时无法判断，按“不同网”处理，排序退化为
/// 在线→名称，不会把设备排到离线项后面。
bool _groupSameNetwork(
  OutputGroup group,
  OutputState state, {
  required bool isLocal,
}) {
  if (isLocal) return true;
  final serverHost = _hostOf(AppConfig.resolvedBaseUrl);
  if (serverHost == null || !_isPrivateIpv4(serverHost)) return false;
  for (final member in group.members) {
    final player = state.playerOf(member.playerId);
    final host = _hostOf(player?.address ?? '');
    if (host != null && _sameSubnet24(serverHost, host)) return true;
  }
  return false;
}

String? _hostOf(String raw) {
  final value = raw.trim();
  if (value.isEmpty) return null;
  final withScheme = value.contains('://') ? value : 'http://$value';
  final uri = Uri.tryParse(withScheme);
  final host = uri?.host;
  if (host == null || host.isEmpty) return null;
  return host;
}

bool _isPrivateIpv4(String host) {
  final parts = host.split('.');
  if (parts.length != 4) return false;
  final octets = <int>[];
  for (final part in parts) {
    final value = int.tryParse(part);
    if (value == null || value < 0 || value > 255) return false;
    octets.add(value);
  }
  if (octets[0] == 10) return true;
  if (octets[0] == 172 && octets[1] >= 16 && octets[1] <= 31) return true;
  if (octets[0] == 192 && octets[1] == 168) return true;
  if (octets[0] == 169 && octets[1] == 254) return true;
  return false;
}

bool _sameSubnet24(String a, String b) {
  final pa = a.split('.');
  final pb = b.split('.');
  if (pa.length != 4 || pb.length != 4) return false;
  return pa[0] == pb[0] && pa[1] == pb[1] && pa[2] == pb[2];
}
