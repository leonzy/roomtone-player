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

  // 上报必须用音频引擎的真实状态，不能用 UI 投影的区域状态：
  // 切到远端区域后 `currentState.currentSong` 已经是那个区域的歌，
  // 拿它上报会把远端区域的曲目写进本机所在区域。
  @override
  Duration get position => _player.loadedPosition;

  @override
  double get volume => _player.currentState.volume.toDouble();

  @override
  bool get isPlaying => _player.loadedIsPlaying;

  @override
  bool get isBuffering => _player.currentState.isBuffering;

  @override
  bool get hasSong => _player.loadedHasSong;

  @override
  int? get songId => _player.loadedSongId;
}
