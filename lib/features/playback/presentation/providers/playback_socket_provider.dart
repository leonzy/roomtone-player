import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/network/api_client.dart';
import '../../data/playback_socket.dart';
import '../../domain/playback_event.dart';

/// 后台播放服务开关。
///
/// 生产环境恒为 true；widget 测试里关掉，避免真实 WS 连接与心跳定时器
/// 在测试结束后仍处于 pending 状态。
final playbackBackgroundEnabledProvider = Provider<bool>((ref) => true);

/// 全局唯一的播放事件 WebSocket。
///
/// 复用 [apiClientProvider] 的 Dio：ticket 请求自动带当前登录 token；
/// WS 地址由 [DioPlaybackConnector] 从 `AppConfig.resolvedBaseUrl` 推导。
/// 一个连接接收全部区域的事件，消费方按 `group_id` 分发。
final playbackSocketProvider = Provider<PlaybackSocket>((ref) {
  final apiClient = ref.watch(apiClientProvider);
  final socket = PlaybackSocket(
    connector: DioPlaybackConnector(dio: apiClient.dio),
  );
  ref.onDispose(() => unawaited(socket.dispose()));
  // Provider build 内不直接发起网络请求，放到微任务里；若 provider 在
  // 微任务执行前被销毁，connect() 会因 _disposed 直接返回。
  if (ref.watch(playbackBackgroundEnabledProvider)) {
    Future.microtask(socket.connect);
  }
  return socket;
});

/// 已按 seq 去重的增量事件流。
final playbackEventsProvider = StreamProvider<PlaybackEvent>((ref) {
  return ref.watch(playbackSocketProvider).events;
});

/// 降级态：实时事件不可用、退回 3 秒轮询时为 true。
final playbackDegradedProvider = Provider<ValueNotifier<bool>>((ref) {
  return ref.watch(playbackSocketProvider).degraded;
});

/// 最近一次 `GET /playback` 快照（降级轮询 / 重连全量对齐）。
final playbackSnapshotProvider = Provider<ValueNotifier<Map<String, dynamic>?>>(
  (ref) {
    return ref.watch(playbackSocketProvider).snapshot;
  },
);
