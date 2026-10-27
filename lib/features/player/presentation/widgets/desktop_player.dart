import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/theme/app_theme.dart';
import '../../../../core/utils/formatters.dart';
import '../../../../core/utils/url_helper.dart';
import '../../../../l10n/app_localizations.dart';
import '../../../../shared/widgets/favorite_button.dart';
import '../../domain/player_state.dart';
import '../providers/player_provider.dart';
import '../utils/full_player_route.dart';
import 'progress_bar.dart';
import 'capsule_mini_player.dart';
import '../../../output/presentation/widgets/zone_button.dart';
import '../../../output/presentation/widgets/roon_controls.dart';

/// 桌面端底部播放器栏
class DesktopPlayer extends ConsumerWidget {
  const DesktopPlayer({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(activePlaybackStateProvider);
    final notifier = ref.read(playerStateProvider.notifier);
    final theme = Theme.of(context);

    final ext = theme.extension<SongloftThemeExtension>();
    final useCapsule = ext?.navigationStyle == 'capsule';

    // 胶囊模式：浮起玻璃胶囊条，由 CapsuleMiniPlayer 统一渲染。
    // 提前返回，省掉下面整棵 104px 底栏的构建（含三个 Expanded 与封面解码）。
    if (useCapsule) return const CapsuleMiniPlayer();

    if (MediaQuery.sizeOf(context).width < 700) {
      return Material(
        color: theme.colorScheme.surface,
        child: SizedBox(
          height: 156,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Column(
              children: [
                SizedBox(
                  height: 72,
                  child: Row(
                    children: [
                      Expanded(child: _buildSongInfo(context, state)),
                      const ZoneButton(compact: true),
                      const RoonVolumeButton(),
                    ],
                  ),
                ),
                Expanded(child: _buildPlayControls(context, state, notifier)),
              ],
            ),
          ),
        ),
      );
    }

    final bar = Container(
      height: 104,
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        border: Border(
          top: BorderSide(color: theme.colorScheme.outlineVariant, width: 1),
        ),
      ),
      child: Column(
        children: [
          // 顶部进度条（可点击）
          ClickableProgressBar(
            position: state.currentTime,
            duration: state.duration,
            onSeek: notifier.seek,
            height: 4,
          ),
          // 主内容
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(
                children: [
                  // 最左：区域入口（宽屏显示区域名，窄屏只留图标 + 状态点）
                  // 左侧：歌曲信息
                  Expanded(flex: 3, child: _buildSongInfo(context, state)),
                  // 中间：播放控制
                  Expanded(
                    flex: 4,
                    child: _buildPlayControls(context, state, notifier),
                  ),
                  // 右侧：工具栏
                  const SizedBox(width: 24),
                  const ZoneButton(),
                  const SizedBox(width: 12),
                  const RoonVolumeButton(),
                ],
              ),
            ),
          ),
        ],
      ),
    );

    // 标准模式：104px 底栏（含 border-top）
    return bar;
  }

  Widget _buildSongInfo(BuildContext context, PlayerState state) {
    final theme = Theme.of(context);

    if (!state.hasSong) {
      return Row(
        children: [
          // 空封面
          Container(
            width: 56,
            height: 56,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(8),
              color: theme.colorScheme.surfaceContainerHighest,
            ),
            child: Icon(
              Icons.music_note_rounded,
              color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.5),
            ),
          ),
          const SizedBox(width: 12),
          Text(
            AppLocalizations.of(context).playerNoContent,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.5),
            ),
          ),
        ],
      );
    }

    final song = state.currentSong!;
    final coverUrl = song.coverUrl;

    return Row(
      children: [
        // 可点击区域（封面+标题）
        Expanded(
          child: Semantics(
            button: true,
            label: AppLocalizations.of(context).playerOpenFullPlayer,
            child: GestureDetector(
              onTap: () => openFullPlayer(context),
              behavior: HitTestBehavior.opaque,
              child: Row(
                children: [
                  // 封面
                  Container(
                    width: 56,
                    height: 56,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(8),
                      color: theme.colorScheme.surfaceContainerHighest,
                    ),
                    clipBehavior: Clip.antiAlias,
                    child:
                        coverUrl != null
                            ? ExcludeSemantics(
                              child: Image.network(
                                UrlHelper.buildCoverUrl(coverUrl, width: 300),
                                fit: BoxFit.cover,
                                errorBuilder:
                                    (_, _, _) => Icon(
                                      Icons.music_note_rounded,
                                      color: theme.colorScheme.onSurfaceVariant,
                                    ),
                              ),
                            )
                            : Icon(
                              Icons.music_note_rounded,
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                  ),
                  const SizedBox(width: 12),
                  // 标题和艺术家
                  Expanded(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          song.title,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            fontWeight: FontWeight.w500,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: 4),
                        Text(
                          song.artist ??
                              AppLocalizations.of(context).playerUnknownArtist,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        const SizedBox(width: 8),
        // 收藏按钮
        FavoriteButton(songId: song.id, songType: song.type, size: 20),
      ],
    );
  }

  Widget _buildPlayControls(
    BuildContext context,
    PlayerState state,
    PlayerNotifier notifier,
  ) {
    final theme = Theme.of(context);

    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        // 控制按钮
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const RoonSignalButton(),
            IconButton(
              tooltip: '上一首',
              onPressed: state.hasPrev ? notifier.playPrev : null,
              icon: const Icon(Icons.skip_previous, size: 26),
            ),
            IconButton(
              tooltip: state.isPlaying ? '暂停' : '播放',
              onPressed: notifier.togglePlay,
              icon:
                  state.showBufferingIndicator
                      ? const SizedBox(
                        width: 24,
                        height: 24,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                      : Icon(
                        state.isPlaying ? Icons.pause : Icons.play_arrow,
                        size: 38,
                      ),
            ),
            IconButton(
              tooltip: '下一首',
              onPressed: state.hasNext ? notifier.playNext : null,
              icon: const Icon(Icons.skip_next, size: 26),
            ),
            IconButton(
              tooltip: '播放队列',
              onPressed: notifier.togglePlaylistDrawer,
              icon: const Icon(Icons.queue_music, size: 22),
            ),
          ],
        ),
        const SizedBox(height: 4),
        // 时间显示
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              Formatters.formatDuration(state.currentTime.inSeconds.toDouble()),
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: ClickableProgressBar(
                position: state.currentTime,
                duration: state.duration,
                onSeek: notifier.seek,
                height: 3,
              ),
            ),
            const SizedBox(width: 12),
            Text(
              Formatters.formatDuration(state.duration.inSeconds.toDouble()),
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ],
    );
  }
}
