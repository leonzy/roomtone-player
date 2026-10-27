import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../providers/output_provider.dart';
import '../pages/eq_sheet.dart';
import '../pages/playback_tuning_sheet.dart';
import 'zone_display.dart';

Future<void> showZoneSleep(
  BuildContext context,
  WidgetRef ref,
  ZoneEntry zone,
) async {
  final api = ref.read(outputApiProvider);
  var minutes = 30.0;
  var busy = false;
  var error = '';
  final current = await api.sleepTimer(zone.id);
  if (!context.mounted) return;
  await showDialog<void>(
    context: context,
    builder:
        (ctx) => StatefulBuilder(
          builder:
              (ctx, setLocal) => AlertDialog(
                title: const Text('休眠定时器'),
                content: SizedBox(
                  width: 300,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      ListTile(
                        leading: const Icon(Icons.speaker_outlined),
                        title: Text(zone.name),
                      ),
                      if (current['active'] == true)
                        const Text('此区域已有定时器，保存将替换它。'),
                      Slider(
                        value: minutes,
                        min: 15,
                        max: 120,
                        divisions: 7,
                        label: '${minutes.round()} 分钟',
                        onChanged:
                            busy ? null : (v) => setLocal(() => minutes = v),
                      ),
                      Text('${minutes.round()} 分钟后暂停此区域'),
                      if (error.isNotEmpty)
                        Text(error, style: const TextStyle(color: Colors.red)),
                    ],
                  ),
                ),
                actions: [
                  TextButton(
                    onPressed:
                        busy
                            ? null
                            : () async {
                              await api.sleepTimer(zone.id, minutes: 0);
                              if (ctx.mounted) Navigator.pop(ctx);
                            },
                    child: const Text('取消定时'),
                  ),
                  FilledButton(
                    onPressed:
                        busy
                            ? null
                            : () async {
                              setLocal(() => busy = true);
                              try {
                                await api.sleepTimer(
                                  zone.id,
                                  minutes: minutes.round(),
                                );
                                if (ctx.mounted) Navigator.pop(ctx);
                              } catch (e) {
                                if (ctx.mounted) {
                                  setLocal(() {
                                    busy = false;
                                    error = '$e';
                                  });
                                }
                              }
                            },
                    child: const Text('设置定时休眠'),
                  ),
                ],
              ),
        ),
  );
}

Future<void> showZoneSettings(
  BuildContext context,
  WidgetRef ref,
  ZoneEntry zone,
) async {
  final name = TextEditingController(text: zone.name);
  var icon = zone.icon.isEmpty ? 'speaker' : zone.icon;
  var error = '';
  var busy = false;
  final state = ref.read(outputControllerProvider);
  await showDialog<void>(
    context: context,
    builder:
        (ctx) => StatefulBuilder(
          builder:
              (ctx, setLocal) => AlertDialog(
                title: const Text('区域设置'),
                content: SizedBox(
                  width: 480,
                  child: SingleChildScrollView(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (!zone.isGrouped)
                          TextField(
                            controller: name,
                            decoration: const InputDecoration(
                              labelText: '音箱／区域名称',
                            ),
                          )
                        else
                          const Text('编组内的音箱可在下方分别修改名称。'),
                        const SizedBox(height: 16),
                        DropdownButtonFormField<String>(
                          initialValue: icon,
                          decoration: const InputDecoration(labelText: '区域图标'),
                          items: [
                            for (final entry in zoneIconKeys.entries)
                              DropdownMenuItem(
                                value: entry.key,
                                child: Row(
                                  children: [
                                    Icon(entry.value),
                                    const SizedBox(width: 12),
                                    Text(entry.key),
                                  ],
                                ),
                              ),
                          ],
                          onChanged:
                              busy ? null : (v) => setLocal(() => icon = v!),
                        ),
                        const SizedBox(height: 24),
                        const Text('音频设备'),
                        for (final p in state.players.where(
                          (p) => zone.members.any((m) => m.playerId == p.id),
                        ))
                          SpeakerSettingsRow(playerId: p.id),
                        TextButton.icon(
                          icon: const Icon(Icons.tune),
                          label: const Text('渐变与音量均衡设置'),
                          onPressed: () => showPlaybackTuningSheet(ctx),
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
                    onPressed: busy ? null : () => Navigator.pop(ctx),
                    child: const Text('取消'),
                  ),
                  FilledButton(
                    onPressed:
                        busy
                            ? null
                            : () async {
                              setLocal(() => busy = true);
                              final ok = await ref
                                  .read(outputControllerProvider.notifier)
                                  .renameGroup(
                                    zone.id,
                                    name: name.text.trim(),
                                    icon: icon,
                                  );
                              if (!ctx.mounted) return;
                              if (ok) {
                                Navigator.pop(ctx);
                              } else {
                                setLocal(() {
                                  busy = false;
                                  error =
                                      ref.read(outputControllerProvider).error;
                                });
                              }
                            },
                    child: const Text('保存'),
                  ),
                ],
              ),
        ),
  );
  name.dispose();
}

class SpeakerSettingsRow extends ConsumerWidget {
  const SpeakerSettingsRow({super.key, required this.playerId});
  final String playerId;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final player = ref.watch(outputControllerProvider).playerOf(playerId);
    if (player == null) return const SizedBox.shrink();
    return ListTile(
      leading: const Icon(Icons.speaker_outlined),
      title: Text(player.displayName),
      subtitle: Text('${player.kind.label} · ${player.address}'),
      trailing: IconButton(
        key: ValueKey('rename-speaker-$playerId'),
        tooltip: '修改音箱名称',
        icon: const Icon(Icons.edit_outlined),
        onPressed: () => showSpeakerRename(context, ref, playerId),
      ),
    );
  }
}

Future<void> showSpeakerRename(
  BuildContext context,
  WidgetRef ref,
  String playerId,
) async {
  final name = TextEditingController(
    text:
        ref.read(outputControllerProvider).playerOf(playerId)?.displayName ??
        '',
  );
  var busy = false;
  String? error;
  final route = DialogRoute<void>(
    context: context,
    builder:
        (ctx) => StatefulBuilder(
          builder:
              (ctx, setLocal) => AlertDialog(
                title: const Text('修改音箱名称'),
                content: SizedBox(
                  width: 360,
                  child: TextField(
                    key: const Key('speaker-name-field'),
                    controller: name,
                    autofocus: true,
                    maxLength: 40,
                    decoration: InputDecoration(
                      labelText: '音箱名称',
                      errorText: error,
                    ),
                    enabled: !busy,
                  ),
                ),
                actions: [
                  TextButton(
                    onPressed: busy ? null : () => Navigator.pop(ctx),
                    child: const Text('取消'),
                  ),
                  FilledButton(
                    onPressed:
                        busy
                            ? null
                            : () async {
                              final value = name.text.trim();
                              if (value.isEmpty || value.runes.length > 40) {
                                setLocal(() => error = '请输入 1～40 个字符的名称');
                                return;
                              }
                              setLocal(() {
                                busy = true;
                                error = null;
                              });
                              final ok = await ref
                                  .read(outputControllerProvider.notifier)
                                  .renamePlayer(playerId, value);
                              if (!ctx.mounted) return;
                              if (ok) {
                                Navigator.pop(ctx);
                              } else {
                                setLocal(() {
                                  busy = false;
                                  error =
                                      ref.read(outputControllerProvider).error;
                                });
                              }
                            },
                    child: Text(busy ? '保存中…' : '保存'),
                  ),
                ],
              ),
        ),
  );
  await Navigator.of(context).push(route);
  await route.completed;
  name.dispose();
}

Future<void> showZoneDSP(
  BuildContext context,
  ZoneEntry zone,
) => showDialog<void>(
  context: context,
  builder:
      (ctx) => Dialog(
        child: SizedBox(
          width: 880,
          height: 560,
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.all(20),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        '精准音频控制 · ${zone.name}',
                        style: Theme.of(ctx).textTheme.headlineSmall,
                      ),
                    ),
                    IconButton(
                      tooltip: '关闭',
                      onPressed: () => Navigator.pop(ctx),
                      icon: const Icon(Icons.close),
                    ),
                  ],
                ),
              ),
              const Divider(height: 1),
              Expanded(
                child: Row(
                  children: [
                    SizedBox(
                      width: 210,
                      child: ListView(
                        children: [
                          const ListTile(
                            title: Text('滤波器'),
                            subtitle: Text('服务端 PCM 音频处理'),
                          ),
                          for (final member in zone.members)
                            ListTile(
                              leading: const Icon(Icons.graphic_eq),
                              title: const Text('10 段均衡器'),
                              subtitle: Consumer(
                                builder:
                                    (context, ref, _) => Text(
                                      ref
                                              .watch(outputControllerProvider)
                                              .playerOf(member.playerId)
                                              ?.displayName ??
                                          member.playerId,
                                    ),
                              ),
                              onTap:
                                  () => showDialog<void>(
                                    context: ctx,
                                    builder:
                                        (_) => Dialog(
                                          child: SizedBox(
                                            width: 640,
                                            height: 520,
                                            child: EqSheet(
                                              playerId: member.playerId,
                                            ),
                                          ),
                                        ),
                                  ),
                            ),
                          ListTile(
                            leading: const Icon(Icons.tune),
                            title: const Text('响度与交叉淡化'),
                            onTap: () => showPlaybackTuningSheet(ctx),
                          ),
                        ],
                      ),
                    ),
                    const VerticalDivider(width: 1),
                    const Expanded(
                      child: Padding(
                        padding: EdgeInsets.all(28),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '音频处理',
                              style: TextStyle(
                                fontSize: 28,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            SizedBox(height: 24),
                            Icon(
                              Icons.multiline_chart,
                              size: 100,
                              color: Color(0xFF796CFF),
                            ),
                            SizedBox(height: 24),
                            Text('为每个输出设备设置均衡器，并管理响度和交叉淡化。处理结果以信号路径与实际输出为准。'),
                            SizedBox(height: 16),
                            Text(
                              '当前版本尚未实现参数化 EQ、耳机校正、交叉反馈或自定义升频。DLNA 直拉模式不经过 PCM 均衡器。',
                              style: TextStyle(color: Colors.grey),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
);
