import '../../player/presentation/providers/player_provider.dart';
import 'local_output.dart';

/// 把 [PlayerNotifier] 适配成 local sink 的音频执行接口。
///
/// 只做转发，不在这里判断焦点：是否执行由 [LocalOutput] 的
/// `serverControlled` / 焦点区域决定，避免两处状态机。
class PlayerNotifierLocalAudio implements LocalAudio {
  PlayerNotifierLocalAudio(this._player);

  final PlayerNotifier _player;

  @override
  Future<void> load(int songId, {required Duration position}) =>
      _player.loadForServer(songId, position: position);

  @override
  Future<void> play() => _player.resumeForServer();

  @override
  Future<void> pause() => _player.pauseForServer();

  @override
  Future<void> seek(Duration position) => _player.seek(position);

  @override
  Future<void> setVolume(double volume) =>
      _player.setVolume(volume.round().clamp(0, 100).toDouble());

  @override
  Future<void> skipNext() => _player.playNext();

  @override
  Future<void> skipPrevious() => _player.playPrev();

  @override
  Future<void> stop() => _player.stopForServer();

  @override
  Duration get position => _player.currentState.currentTime;

  @override
  double get volume => _player.currentState.volume.toDouble();

  @override
  bool get isPlaying => _player.currentState.isPlaying;

  @override
  bool get isBuffering => _player.currentState.isBuffering;

  @override
  bool get hasSong => _player.currentState.hasSong;
}
