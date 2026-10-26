import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../output/data/output_api.dart';
import '../../../output/presentation/providers/output_provider.dart';
import '../../../player/presentation/providers/player_provider.dart';
import '../../data/local_output.dart';
import '../../data/local_output_audio.dart';
import 'playback_socket_provider.dart';
import '../../../output/presentation/providers/zone_focus_provider.dart';

/// 本机 local 播放器：注册、心跳、服务端指令执行。
///
/// 全局单例。WS 未连上时 start() 只订阅连接状态，连上后自动注册；
/// 断线后停止心跳，服务端 30s 超时标离线。
final localOutputProvider = Provider<LocalOutput>((ref) {
  // 常驻：被回收会注销设备、停心跳，服务端 30s 后把本机标离线。
  ref.keepAlive();
  final output = LocalOutput(
    transport: PlaybackSocketTransport(ref.watch(playbackSocketProvider)),
    audio: PlayerNotifierLocalAudio(ref.read(playerStateProvider.notifier)),
    membership: OutputApiZoneMembership(ref.watch(outputApiProvider)),
    deviceIdSource: LocalDeviceIdStore(),
  );

  // 焦点变化只影响“是否执行服务端指令”，不发任何网络请求。
  ref.listen<String?>(zoneFocusProvider, (_, next) {
    unawaited(output.setFocusedGroup(next));
  }, fireImmediately: true);

  if (ref.watch(playbackBackgroundEnabledProvider)) {
    Future.microtask(output.start);
  }
  ref.onDispose(() => unawaited(output.dispose()));
  return output;
});

/// 本机设备 id（与 [LocalOutput] 共用同一个 prefs key）。
///
/// 区域「是否含本机」按它判断，不能按 `kind=local` 判断——别的客户端
/// 注册的也是 local，按 kind 判断会把别人的区域当成自己的。
///
/// 单独读 prefs 而不是从 [localOutputProvider] 取：后者会建立 WS 连接，
/// 纯展示组件（区域按钮）不该为了拿一个 id 去启动后台服务。
final localDeviceIdProvider = NotifierProvider<LocalDeviceIdNotifier, String?>(
  LocalDeviceIdNotifier.new,
);

class LocalDeviceIdNotifier extends Notifier<String?> {
  @override
  String? build() {
    ref.keepAlive();
    Future.microtask(_load);
    return null;
  }

  Future<void> _load() async {
    try {
      final id = await LocalDeviceIdStore().loadOrCreate();
      if (id.isNotEmpty) state = id;
    } catch (_) {
      // 读不到就保持 null，区域列表退回旧判定。
    }
  }
}

/// 服务端接管态：EQ 面板据此置灰。
final serverControlledProvider = Provider<ValueListenable<bool>>((ref) {
  return ref.watch(localOutputProvider).serverControlled;
});

/// 通过 `GET /groups` 判断本机在哪些区域里。
class OutputApiZoneMembership implements LocalZoneMembership {
  OutputApiZoneMembership(this._api);

  final OutputApi _api;

  @override
  Future<Set<String>> groupsContaining(String playerId) async {
    final groups = await _api.listGroups();
    return groups
        .where((group) => group.memberIds.contains(playerId))
        .map((group) => group.id)
        .toSet();
  }
}
