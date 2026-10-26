import 'package:flutter_riverpod/flutter_riverpod.dart';

/// 焦点区域不含本机时的区域 id。
///
/// 这种区域的声音由服务端推给它的设备，本机只是遥控器：播放命令要发给
/// 服务端，而不是在本机起播。由 `ZoneQueueSync` 维护——它本来就要解析
/// 焦点区域，播放器只读结果，避免为了拿一个 id 去实例化整个输出控制器
/// （那会顺带发起网络请求）。
final remoteZoneIdProvider = NotifierProvider<RemoteZoneIdNotifier, String?>(
  RemoteZoneIdNotifier.new,
);

class RemoteZoneIdNotifier extends Notifier<String?> {
  @override
  String? build() {
    // 播放器每个动作都要读它；被回收重建会短暂变 null，
    // 让「远端区域」的播放命令误落到本机音频引擎。
    ref.keepAlive();
    return null;
  }

  void set(String? zoneId) {
    if (state == zoneId) return;
    state = zoneId;
  }
}
