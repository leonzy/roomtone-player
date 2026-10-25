import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../shared/utils/responsive_snackbar.dart';
import '../../domain/output_models.dart';
import '../providers/output_provider.dart';

/// 播放转移（F2）。
///
/// 后端 `POST /groups/{to}/transfer`：把源组的队列与位置转到目标组。
/// `only_player_id` 非空时后端会先把该设备从源组摘出来单独成组，
/// 再把播放转过去 —— 此时路径里的目标组会被忽略（服务端用新组的 id），
/// 所以这里传什么都不会影响结果，但为了可读性仍传目标 id。
Future<void> showTransferSheet(
  BuildContext context,
  WidgetRef ref,
  OutputGroup group,
) async {
  final state = ref.read(outputControllerProvider);
  final controller = ref.read(outputControllerProvider.notifier);
  final targets = state.groups.where((g) => g.id != group.id).toList();

  final choice = await showModalBottomSheet<Object>(
    context: context,
    showDragHandle: true,
    builder: (ctx) {
      final theme = Theme.of(ctx);
      return SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Text('转移播放', style: theme.textTheme.titleLarge),
            ),
            if (!group.isSolo) ...[
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Text(
                  '只在一台设备上继续',
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: theme.colorScheme.outline,
                  ),
                ),
              ),
              for (final m in group.members)
                ListTile(
                  leading: const Icon(Icons.person_outline),
                  title: Text(
                    state.playerOf(m.playerId)?.displayName ?? m.playerId,
                  ),
                  subtitle: const Text('拆出来单独成组'),
                  onTap: () => Navigator.of(ctx).pop(m.playerId),
                ),
              const Divider(height: 1),
            ],
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: Text(
                '转到另一个组',
                style: theme.textTheme.labelMedium?.copyWith(
                  color: theme.colorScheme.outline,
                ),
              ),
            ),
            if (targets.isEmpty)
              const Padding(
                padding: EdgeInsets.all(16),
                child: Text('没有其他组可接收。'),
              )
            else
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    for (final t in targets)
                      ListTile(
                        leading: Icon(
                          t.isSolo ? Icons.speaker : Icons.speaker_group,
                        ),
                        title: Text(t.isSolo ? '单机播放' : t.name),
                        subtitle: Text(
                          [
                            '${t.members.length} 台',
                            if (t.isPlaying) '播放中',
                            if (t.hasOfflineMember) '含离线设备',
                            if (t.partyId.isNotEmpty) '派对中',
                          ].join(' · '),
                        ),
                        onTap: () => Navigator.of(ctx).pop(t),
                      ),
                  ],
                ),
              ),
          ],
        ),
      );
    },
  );

  if (choice == null) return;
  final ok =
      choice is OutputGroup
          ? await controller.transfer(
            fromGroupId: group.id,
            toGroupId: choice.id,
          )
          : await controller.transfer(
            fromGroupId: group.id,
            toGroupId: group.id,
            onlyPlayerId: choice as String,
          );

  if (!context.mounted) return;
  final s = ref.read(outputControllerProvider);
  if (ok) {
    ResponsiveSnackBar.showSuccess(context, message: '已转移播放');
  } else if (s.error.isNotEmpty) {
    ResponsiveSnackBar.showError(context, message: s.error);
  }
}
