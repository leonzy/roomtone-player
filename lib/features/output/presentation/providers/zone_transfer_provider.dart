import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../playback/domain/playback_event.dart';
import '../../../playback/presentation/providers/playback_socket_provider.dart';

/// 区域转移的进行态（docs/architecture_playback.md §11.2 S6）。
///
/// RAOP 握手 + 缓冲决定了转移必然有 0.5~3s 无声期，协议层消不掉；
/// 这里只负责把这段时间讲清楚：目标行「正在切换…」、源行「正在移交」，
/// 收到目标区域 state 事件即结束，5s 未收到则标记超时。
class ZoneTransferState {
  const ZoneTransferState({this.from, this.to, this.timedOut = false});

  final String? from;
  final String? to;
  final bool timedOut;

  bool get active => to != null;
}

/// 转移超时上限：超过这个时间还没收到目标区域的 state 事件就提示用户。
const Duration zoneTransferTimeout = Duration(seconds: 5);

final zoneTransferProvider =
    NotifierProvider<ZoneTransferNotifier, ZoneTransferState>(
      ZoneTransferNotifier.new,
    );

class ZoneTransferNotifier extends Notifier<ZoneTransferState> {
  Timer? _timer;

  @override
  ZoneTransferState build() {
    ref.keepAlive();
    ref.listen<AsyncValue<PlaybackEvent>>(playbackEventsProvider, (_, next) {
      final event = next.value;
      if (event == null || event.type != 'state') return;
      if (event.groupId.isNotEmpty) complete(event.groupId);
    });
    ref.onDispose(() => _timer?.cancel());
    return const ZoneTransferState();
  }

  void begin({required String from, required String to}) {
    _timer?.cancel();
    state = ZoneTransferState(from: from, to: to);
    _timer = Timer(zoneTransferTimeout, () {
      if (state.to != to) return;
      state = const ZoneTransferState(timedOut: true);
    });
  }

  /// 目标区域开始播放（或转移失败）时结束进行态。
  void complete(String groupId) {
    if (state.to != groupId) return;
    _timer?.cancel();
    _timer = null;
    state = const ZoneTransferState();
  }

  /// 超时提示已展示，清掉标记避免重复弹。
  void clearTimedOut() {
    if (!state.timedOut) return;
    state = const ZoneTransferState();
  }
}
