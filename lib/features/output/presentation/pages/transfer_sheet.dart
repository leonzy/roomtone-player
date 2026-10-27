import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../shared/utils/responsive_snackbar.dart';
import '../../../library/presentation/providers/songs_provider.dart';
import '../../../playback/presentation/providers/local_output_provider.dart';
import '../../domain/output_models.dart';
import '../providers/output_provider.dart';
import '../providers/zone_focus_provider.dart';
import '../widgets/zone_display.dart';

Future<void> showTransferSheet(
  BuildContext context,
  WidgetRef ref,
  OutputGroup group,
) async {
  await showDialog<void>(
    context: context,
    builder: (_) => TransferZoneDialog(groupId: group.id),
  );
}

/// Current zone and track above, actual receiving speakers/zones below.
class TransferZoneDialog extends ConsumerStatefulWidget {
  const TransferZoneDialog({super.key, required this.groupId});
  final String groupId;
  @override
  ConsumerState<TransferZoneDialog> createState() => _TransferZoneDialogState();
}

class _TransferZoneDialogState extends ConsumerState<TransferZoneDialog> {
  bool _busy = false;
  String _error = '';
  @override
  void initState() {
    super.initState();
    Future.microtask(
      () => ref.read(outputControllerProvider.notifier).refresh(silent: true),
    );
  }

  Future<void> _transfer(ZoneEntry target) async {
    setState(() {
      _busy = true;
      _error = '';
    });
    final ok = await ref
        .read(outputControllerProvider.notifier)
        .transfer(fromGroupId: widget.groupId, toGroupId: target.id);
    if (!mounted) return;
    if (!ok) {
      setState(() {
        _busy = false;
        _error = ref.read(outputControllerProvider).error;
      });
      return;
    }
    await ref.read(zoneFocusProvider.notifier).focus(target.id);
    if (!mounted) return;
    ResponsiveSnackBar.showSuccess(
      context,
      message: '已转移至${target.compactName}',
    );
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(outputControllerProvider);
    final zones = buildZoneEntries(
      state,
      localDeviceId: ref.watch(localDeviceIdProvider),
    );
    final current = zones.where((z) => z.id == widget.groupId).firstOrNull;
    final targets =
        zones.where((z) => z.isReal && z.id != widget.groupId).toList();
    final theme = Theme.of(context);
    final songId = current?.status.songId ?? 0;
    final song =
        songId > 0 ? ref.watch(songDetailProvider(songId)).value : null;
    return Dialog(
      insetPadding: const EdgeInsets.all(16),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
      clipBehavior: Clip.antiAlias,
      child: SizedBox(
        width: 400,
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(context).height * .8,
          ),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 16, 8, 12),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          '转换区域',
                          style: theme.textTheme.titleLarge?.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      IconButton(
                        tooltip: '关闭',
                        onPressed: _busy ? null : () => Navigator.pop(context),
                        icon: const Icon(Icons.close, size: 20),
                      ),
                    ],
                  ),
                ),
                if (current != null)
                  ColoredBox(
                    color: theme.colorScheme.primaryContainer.withValues(
                      alpha: .6,
                    ),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      child: Column(
                        children: [
                          ListTile(
                            leading: Icon(zoneIconFor(current), size: 36),
                            title: ZoneMemberNames(
                              zone: current,
                              style: theme.textTheme.titleMedium?.copyWith(
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                          ListTile(
                            leading: Icon(
                              current.isPlaying
                                  ? Icons.pause_circle_filled
                                  : Icons.play_circle_filled,
                              size: 28,
                            ),
                            title: Text(
                              song?.title ??
                                  (songId > 0 ? '歌曲 #$songId' : '尚未播放'),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.bodySmall,
                            ),
                            subtitle:
                                song?.artist?.isNotEmpty == true
                                    ? Text(
                                      song!.artist!,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: theme.textTheme.bodySmall,
                                    )
                                    : null,
                            dense: true,
                          ),
                        ],
                      ),
                    ),
                  ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 18, 20, 10),
                  child: Text(
                    '转至',
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                if (targets.isEmpty)
                  const Padding(
                    padding: EdgeInsets.all(20),
                    child: Text('没有其他音箱或区域可接收播放'),
                  ),
                for (final target in targets)
                  ListTile(
                    key: ValueKey('transfer-target-${target.id}'),
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 28,
                      vertical: 8,
                    ),
                    leading: Icon(zoneIconFor(target), size: 36),
                    title: ZoneMemberNames(
                      zone: target,
                      style: theme.textTheme.titleMedium,
                    ),
                    subtitle:
                        !target.online
                            ? const Text('离线')
                            : target.isPlaying
                            ? const Text('正在播放 · 转移将替换该区域的队列')
                            : null,
                    enabled: !_busy && target.online && songId > 0,
                    onTap: () => _transfer(target),
                  ),
                if (_busy) const LinearProgressIndicator(),
                if (_error.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.all(20),
                    child: Text(
                      _error,
                      style: TextStyle(color: theme.colorScheme.error),
                    ),
                  ),
                const SizedBox(height: 12),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
