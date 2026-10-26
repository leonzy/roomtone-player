import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../playback/domain/playback_event.dart';
import '../../../playback/presentation/providers/playback_socket_provider.dart';

/// 控制焦点（当前正在看的区域）的持久化 key。
const String zoneFocusKey = 'roomtone_zone_focus';

/// 自动跟随开关的持久化 key。
const String zoneAutoFollowKey = 'roomtone_zone_auto_follow';

/// 自动跟随去重窗口：同一区域 300ms 内的重复 state 事件只处理一次。
const Duration zoneAutoFollowDedupeWindow = Duration(milliseconds: 300);

/// 本机尚未注册成服务端区域时使用的本地哨兵 id。
///
/// 它只存在于客户端：用于让“本机”在没有音箱、甚至本机还没注册成功时
/// 仍然出现在区域列表里（docs/architecture_playback_ui.md §4.3）。
const String kLocalZoneId = '__local__';

/// 控制焦点：本地 UI 状态，不进服务端，也不触发任何播放命令。
///
/// 与播放状态分开是刻意的：焦点只决定“本机是否执行服务端指令”，
/// 点击区域不等于转移播放（docs/architecture_playback_ui.md §7.2）。
final zoneFocusProvider = NotifierProvider<ZoneFocusNotifier, String?>(
  ZoneFocusNotifier.new,
);

class ZoneFocusNotifier extends Notifier<String?> {
  bool _touched = false;

  @override
  String? build() {
    Future.microtask(_restore);
    return null;
  }

  Future<void> _restore() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final saved = prefs.getString(zoneFocusKey);
      // 用户在恢复完成前已经点过区域：以本次选择为准，避免旧值覆盖新值。
      if (!_touched && saved != null && saved.isNotEmpty && state == null) {
        state = saved;
      }
    } catch (_) {
      // 读不到焦点就保持 null，由 ZoneButton 自动回退到含本机的区域。
    }
  }

  /// 切换焦点；null / 空串表示清除（回退到本机区域）。
  Future<void> focus(String? zoneId) async {
    _touched = true;
    final next = (zoneId == null || zoneId.isEmpty) ? null : zoneId;
    state = next;
    try {
      final prefs = await SharedPreferences.getInstance();
      if (next == null) {
        await prefs.remove(zoneFocusKey);
      } else {
        await prefs.setString(zoneFocusKey, next);
      }
    } catch (_) {
      // 持久化失败不影响本次会话的焦点。
    }
  }

  /// 聚焦本机（含本机的真实区域，或本地哨兵）。
  Future<void> focusLocal() => focus(kLocalZoneId);
}

/// 自动跟随开关：在其他区域开始播放时，把控制焦点切到该区域。
///
/// 默认关闭。开关是本地 UI 偏好，不进服务端；监听播放事件是为了在任意
/// 页面都能生效，因此 [SongloftApp] 会常驻 watch 这个 provider。
final zoneAutoFollowProvider = NotifierProvider<ZoneAutoFollowNotifier, bool>(
  ZoneAutoFollowNotifier.new,
);

/// 自动跟随去重用的时钟；测试覆盖它即可精确控制 300ms 窗口。
final zoneAutoFollowClockProvider = Provider<DateTime Function()>(
  (ref) => DateTime.now,
);

class ZoneAutoFollowNotifier extends Notifier<bool> {
  bool _touched = false;
  final Map<String, DateTime> _lastFollowAt = <String, DateTime>{};

  @override
  bool build() {
    ref.listen<AsyncValue<PlaybackEvent>>(playbackEventsProvider, (_, next) {
      final event = next.value;
      if (event != null) _onPlaybackEvent(event);
    });
    Future.microtask(_restore);
    return false;
  }

  Future<void> _restore() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      // 用户在恢复完成前已经拨过开关：以本次操作为准。
      if (_touched) return;
      state = prefs.getBool(zoneAutoFollowKey) ?? false;
    } catch (_) {
      // 读不到就保持默认关闭。
    }
  }

  /// 更新开关并持久化；持久化失败不影响本次会话。
  Future<void> setAutoFollow(bool value) async {
    _touched = true;
    state = value;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(zoneAutoFollowKey, value);
    } catch (_) {
      // 持久化失败不影响本次会话。
    }
  }

  void _onPlaybackEvent(PlaybackEvent event) {
    if (!state) return;
    if (event.type != 'state' || event.status != 'playing') return;
    final groupId = event.groupId;
    if (groupId.isEmpty) return;
    if (groupId == ref.read(zoneFocusProvider)) return;

    final now = ref.read(zoneAutoFollowClockProvider)();
    // 只保留窗口内的记录，避免区域数量增长后 map 无限膨胀。
    _lastFollowAt.removeWhere(
      (_, at) => now.difference(at) >= zoneAutoFollowDedupeWindow,
    );
    if (_lastFollowAt.containsKey(groupId)) return;
    _lastFollowAt[groupId] = now;

    unawaited(ref.read(zoneFocusProvider.notifier).focus(groupId));
  }
}
