import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../playback/presentation/providers/local_output_provider.dart';
import '../../../player/presentation/providers/player_provider.dart';
import '../providers/output_provider.dart';
import '../../domain/output_models.dart';
import '../providers/zone_focus_provider.dart';
import '../pages/transfer_sheet.dart';
import 'roon_volume.dart';
import 'signal_path.dart';
import 'zone_display.dart';
import 'roon_zone_settings.dart';

Future<void> showPlayerPopover(
  BuildContext context,
  Widget child, {
  double width = 380,
}) {
  final box = context.findRenderObject() as RenderBox;
  final anchor = box.localToGlobal(Offset.zero);
  final size = MediaQuery.sizeOf(context);
  final actualWidth = width.clamp(0.0, size.width - 24);
  return showDialog<void>(
    context: context,
    barrierColor: Colors.transparent,
    builder:
        (_) => Stack(
          children: [
            Positioned(
              left: (anchor.dx - actualWidth / 2).clamp(
                12.0,
                size.width - actualWidth - 12,
              ),
              bottom: (size.height - anchor.dy + 12).clamp(
                100.0,
                size.height - 180,
              ),
              width: actualWidth,
              child: Material(
                elevation: 12,
                borderRadius: BorderRadius.circular(6),
                clipBehavior: Clip.antiAlias,
                child: ConstrainedBox(
                  constraints: BoxConstraints(maxHeight: size.height * .72),
                  child: SingleChildScrollView(child: child),
                ),
              ),
            ),
          ],
        ),
  );
}

ZoneEntry? focusedOutput(WidgetRef ref) => resolveFocusedZone(
  ref.watch(outputControllerProvider),
  ref.watch(zoneFocusProvider),
  localDeviceId: ref.watch(localDeviceIdProvider),
);

class RoonSignalButton extends ConsumerWidget {
  const RoonSignalButton({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final zone = focusedOutput(ref);
    final path = zone?.signalPath;
    final error = zone?.status.error ?? '';
    return IconButton(
      tooltip: error.isEmpty ? '信号路径' : '播放失败：$error',
      icon: Container(
        width: 7,
        height: 7,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color:
              error.isNotEmpty
                  ? Colors.red
                  : path == null
                  ? Colors.grey
                  : signalPathColor(path.kind),
          boxShadow: const [BoxShadow(color: Color(0x334CC5B4), blurRadius: 5)],
        ),
      ),
      onPressed:
          () => showPlayerPopover(
            context,
            Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    error.isNotEmpty
                        ? '信号路径：连接失败'
                        : '信号路径：${path?.kind.label ?? '尚未播放'}',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  const SizedBox(height: 8),
                  Text(zone?.name ?? '本机'),
                  if (error.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 12),
                      child: Text(
                        error,
                        style: const TextStyle(color: Colors.red),
                      ),
                    ),
                  if (path != null && error.isEmpty)
                    SignalPathPanel(path: path),
                  if (path == null && error.isEmpty)
                    const Padding(
                      padding: EdgeInsets.only(top: 16),
                      child: Text('开始播放后显示实际音频链路。'),
                    ),
                ],
              ),
            ),
          ),
    );
  }
}

class RoonZoneList extends ConsumerWidget {
  const RoonZoneList({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(outputControllerProvider);
    final zones = buildZoneEntries(
      state,
      localDeviceId: ref.watch(localDeviceIdProvider),
    );
    final focused = focusedOutput(ref);
    final controller = ref.read(outputControllerProvider.notifier);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final zone in zones)
          ListTile(
            selected: zone.id == focused?.id,
            selectedTileColor: Theme.of(
              context,
            ).colorScheme.primaryContainer.withValues(alpha: .6),
            leading: Icon(zoneIconFor(zone), size: 32),
            title: ZoneMemberNames(zone: zone),
            subtitle:
                !zone.online
                    ? const Text('离线')
                    : zone.status.error.isNotEmpty
                    ? Text(
                      zone.status.error,
                      maxLines: 2,
                      style: const TextStyle(color: Colors.red),
                    )
                    : null,
            trailing:
                zone.canControl
                    ? IconButton(
                      tooltip: zone.isPlaying ? '暂停此区域' : '播放此区域',
                      icon: Icon(
                        zone.isPlaying
                            ? Icons.pause_circle_outline
                            : Icons.play_circle_outline,
                      ),
                      onPressed:
                          () => controller.transport(
                            zone.id,
                            zone.isPlaying ? 'pause' : 'play',
                          ),
                    )
                    : null,
            onTap: () {
              ref.read(zoneFocusProvider.notifier).focus(zone.id);
              Navigator.pop(context);
            },
          ),
        const Divider(height: 1),
        Padding(
          padding: const EdgeInsets.all(8),
          child: Row(
            children: [
              TextButton.icon(
                icon: const Icon(Icons.pause_circle_outline),
                label: const Text('暂停所有播放'),
                onPressed:
                    zones.any((z) => z.canControl && z.isPlaying)
                        ? () async {
                          for (final z in zones.where(
                            (z) => z.canControl && z.isPlaying,
                          )) {
                            await controller.transport(z.id, 'pause');
                          }
                        }
                        : null,
              ),
              const Spacer(),
              TextButton.icon(
                icon: const Icon(Icons.link),
                label: const Text('组'),
                onPressed:
                    focused?.isReal == true
                        ? () {
                          final parent = Navigator.of(context).context;
                          Navigator.pop(context);
                          showRoonGroupEditor(parent, ref, focused!);
                        }
                        : null,
              ),
            ],
          ),
        ),
      ],
    );
  }
}

Future<void> showRoonGroupEditor(
  BuildContext context,
  WidgetRef ref,
  ZoneEntry zone,
) async {
  final state = ref.read(outputControllerProvider);
  final controller = ref.read(outputControllerProvider.notifier);
  final original = zone.members.map((m) => m.playerId).toSet();
  final selected = {...original};
  var saving = false;
  var error = '';
  await showDialog<void>(
    context: context,
    builder:
        (ctx) => StatefulBuilder(
          builder:
              (ctx, setLocal) => AlertDialog(
                title: const Text('区域编组'),
                content: SizedBox(
                  width: 400,
                  child: SingleChildScrollView(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        ListTile(
                          tileColor: const Color(0x22796CFF),
                          leading: const Icon(Icons.speaker_outlined, size: 36),
                          title: Text(zone.name),
                          subtitle: const Text('当前区域'),
                        ),
                        const Padding(
                          padding: EdgeInsets.symmetric(vertical: 16),
                          child: Text('添加至区域'),
                        ),
                        for (final p in state.players)
                          CheckboxListTile(
                            contentPadding: EdgeInsets.zero,
                            secondary: const Icon(Icons.speaker_outlined),
                            title: Text(p.displayName),
                            subtitle: Text(p.kind.label),
                            value: selected.contains(p.id),
                            onChanged:
                                saving || !p.usable || p.id == original.first
                                    ? null
                                    : (v) => setLocal(() {
                                      if (v == true) {
                                        selected.add(p.id);
                                      } else {
                                        selected.remove(p.id);
                                      }
                                    }),
                          ),
                        const Text(
                          '不同协议的设备可能只对齐起播，不能保证精确同步。',
                          style: TextStyle(fontSize: 12),
                        ),
                        if (error.isNotEmpty)
                          Text(
                            error,
                            style: const TextStyle(color: Colors.red),
                          ),
                      ],
                    ),
                  ),
                ),
                actions: [
                  TextButton(
                    onPressed: saving ? null : () => Navigator.pop(ctx),
                    child: const Text('取消'),
                  ),
                  FilledButton(
                    onPressed:
                        saving
                            ? null
                            : () async {
                              setLocal(() => saving = true);
                              var ok = true;
                              for (final id in original.difference(selected)) {
                                if (!await controller.removeMember(
                                  zone.id,
                                  id,
                                )) {
                                  ok = false;
                                  break;
                                }
                              }
                              if (ok) {
                                for (final id in selected.difference(
                                  original,
                                )) {
                                  if (!await controller.addMember(
                                    zone.id,
                                    id,
                                  )) {
                                    ok = false;
                                    break;
                                  }
                                }
                              }
                              if (!ctx.mounted) return;
                              if (ok) {
                                Navigator.pop(ctx);
                              } else {
                                setLocal(() {
                                  saving = false;
                                  error =
                                      ref.read(outputControllerProvider).error;
                                });
                              }
                            },
                    child: Text(saving ? '保存中…' : '保存'),
                  ),
                ],
              ),
        ),
  );
}

class RoonVolumeButton extends ConsumerWidget {
  const RoonVolumeButton({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final zone = focusedOutput(ref);
    final player = ref.watch(activePlaybackStateProvider);
    return InkWell(
      onTap: () async {
        OutputGroup? transferGroup;
        await showPlayerPopover(
          context,
          _VolumePanel(
            onTransfer: (group) {
              transferGroup = group;
            },
          ),
          width: 440,
        );
        if (transferGroup != null && context.mounted) {
          await showTransferSheet(context, ref, transferGroup!);
        }
      },
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.volume_up_outlined, size: 28),
            const SizedBox(height: 4),
            Text(
              zone?.isGrouped == true
                  ? ''
                  : '${(zone?.isLocal == false ? zone!.volume : player.volume).round()}',
              style: const TextStyle(fontSize: 11),
            ),
          ],
        ),
      ),
    );
  }
}

class _VolumePanel extends ConsumerWidget {
  const _VolumePanel({required this.onTransfer});
  final ValueChanged<OutputGroup> onTransfer;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final zone = focusedOutput(ref);
    final player = ref.watch(activePlaybackStateProvider);
    return Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              IconButton(
                tooltip: '休眠定时器',
                icon: const Icon(Icons.bedtime_outlined),
                onPressed:
                    zone?.isReal == true
                        ? () => showZoneSleep(context, ref, zone!)
                        : null,
              ),
              IconButton(
                tooltip: 'DSP 音频控制',
                icon: const Icon(Icons.graphic_eq),
                onPressed:
                    zone == null ? null : () => showZoneDSP(context, zone),
              ),
              IconButton(
                tooltip: '转移当前区域的播放',
                icon: const Icon(Icons.swap_horiz),
                onPressed:
                    zone?.group == null
                        ? null
                        : () {
                          onTransfer(zone!.group!);
                          Navigator.of(context).pop();
                        },
              ),
              IconButton(
                tooltip: '区域设置',
                icon: const Icon(Icons.settings_outlined),
                onPressed:
                    zone?.isReal == true
                        ? () => showZoneSettings(context, ref, zone!)
                        : null,
              ),
            ],
          ),
          const Divider(),
          if (zone?.isReal == true)
            RoonGroupVolumeControl(
              key: ValueKey('volume-zone-${zone!.id}'),
              groupId: zone.id,
            )
          else
            Row(
              children: [
                const Icon(Icons.volume_up_outlined),
                Expanded(
                  child: Slider(
                    value: player.volume.toDouble().clamp(0, 100),
                    divisions: 100,
                    min: 0,
                    max: 100,
                    onChanged:
                        (v) => ref
                            .read(playerStateProvider.notifier)
                            .setVolume(v.roundToDouble()),
                  ),
                ),
              ],
            ),
        ],
      ),
    );
  }
}
