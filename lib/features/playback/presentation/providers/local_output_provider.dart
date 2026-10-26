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

  Future.microtask(output.start);
  ref.onDispose(() => unawaited(output.dispose()));
  return output;
});

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
