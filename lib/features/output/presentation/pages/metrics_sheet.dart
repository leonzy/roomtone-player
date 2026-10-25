import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/output_models.dart';
import '../providers/output_provider.dart';

/// 运行指标面板（F5）。
///
/// 排查"声音卡"是解码跟不上还是下游写不进去：
/// - `underruns` 涨 = 解码跟不上（CPU / 网络），会补静音帧。
/// - `dropped_frames` 涨 = 分发队列丢帧，下游（音箱 / 网络）写不进去。
/// - `resyncs` 涨 = 偏差超限重挂，通常是时钟或设备抖动。
/// - `buffering` 长时间为真比 underruns 更早暴露问题。
///
/// 面板打开时按 2s 刷新一次，关闭即停（由调用方负责）。
class MetricsSheet extends ConsumerStatefulWidget {
  const MetricsSheet({super.key});

  @override
  ConsumerState<MetricsSheet> createState() => _MetricsSheetState();
}

class _MetricsSheetState extends ConsumerState<MetricsSheet> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ref.read(outputControllerProvider.notifier).loadMetrics();
    });
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(outputControllerProvider);
    final theme = Theme.of(context);
    final m = state.metrics;

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child:
            m == null
                ? const SizedBox(
                  height: 160,
                  child: Center(child: CircularProgressIndicator()),
                )
                : Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            '运行指标',
                            style: theme.textTheme.titleLarge,
                          ),
                        ),
                        IconButton(
                          tooltip: '刷新',
                          onPressed:
                              () =>
                                  ref
                                      .read(outputControllerProvider.notifier)
                                      .loadMetrics(),
                          icon: const Icon(Icons.refresh),
                        ),
                      ],
                    ),
                    if (m.decodeSaturated)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: Text(
                          '解码槽位已满：新增组或开启派对会返回 503',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.error,
                          ),
                        ),
                      ),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        _Metric(
                          label: '解码槽位',
                          value: '${m.decodeSlotsUsed}/${m.decodeSlotsMax}',
                        ),
                        _Metric(
                          label: '组 / 设备',
                          value: '${m.groups} / ${m.players}',
                        ),
                        _Metric(label: '欠载补静音', value: '${m.underrunsTotal}'),
                        _Metric(label: '丢帧', value: '${m.droppedFramesTotal}'),
                        _Metric(label: '重挂', value: '${m.resyncsTotal}'),
                        _Metric(
                          label: '事件丢弃',
                          value: '${m.eventsDroppedTotal}',
                        ),
                        _Metric(label: '最大偏差', value: '${m.driftMs} ms'),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Text('各 owner 明细', style: theme.textTheme.labelLarge),
                    const SizedBox(height: 4),
                    Flexible(
                      child:
                          m.owners.isEmpty
                              ? Padding(
                                padding: const EdgeInsets.symmetric(
                                  vertical: 16,
                                ),
                                child: Text(
                                  '当前没有在播的组或派对',
                                  style: theme.textTheme.bodySmall,
                                ),
                              )
                              : ListView.separated(
                                shrinkWrap: true,
                                itemCount: m.owners.length,
                                separatorBuilder:
                                    (_, _) => const Divider(height: 1),
                                itemBuilder: (ctx, i) {
                                  final o = m.owners[i];
                                  return ListTile(
                                    dense: true,
                                    contentPadding: EdgeInsets.zero,
                                    title: Text(
                                      '${o.owner}${o.buffering ? ' · 缓冲中' : ''}',
                                      style: TextStyle(
                                        color:
                                            o.buffering
                                                ? theme.colorScheme.error
                                                : null,
                                      ),
                                    ),
                                    subtitle: Text(
                                      '${_stateLabel(o.state)} · 偏差 ${o.driftMs} ms'
                                      ' · ${o.targets} 个输出',
                                    ),
                                  );
                                },
                              ),
                    ),
                  ],
                ),
      ),
    );
  }

  String _stateLabel(String state) => switch (state) {
    PlayState.playing => '播放中',
    PlayState.paused => '已暂停',
    PlayState.buffering => '缓冲中',
    PlayState.error => '出错',
    _ => '空闲',
  };
}

class _Metric extends StatelessWidget {
  const _Metric({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      width: 108,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: theme.textTheme.labelSmall),
          const SizedBox(height: 2),
          Text(
            value,
            style: theme.textTheme.titleSmall,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }
}

/// 打开指标面板。
Future<void> showMetricsSheet(BuildContext context) async {
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder:
        (_) => DraggableScrollableSheet(
          expand: false,
          initialChildSize: 0.7,
          maxChildSize: 0.92,
          builder: (_, _) => const MetricsSheet(),
        ),
  );
}
