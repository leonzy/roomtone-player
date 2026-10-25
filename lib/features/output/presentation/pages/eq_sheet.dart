import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../shared/utils/responsive_snackbar.dart';
import '../../domain/output_models.dart';
import '../providers/output_provider.dart';

/// EQ 面板（F3）。
///
/// 10 段增益顺序固定 31/62/125/250/500/1k/2k/4k/8k/16k Hz，与后端
/// `dsp.CenterFreqs` 和客户端 /settings/equalizer 一致。两件事必须记住：
///
/// 1. 增益由服务端钳到 ±12dB 并**重算 preamp** 后回填，所以保存后要用
///    返回值刷新界面，不能拿本地值当真。
/// 2. 任一频段非 0 时该组强制走服务端解码管线，占一个解码槽位；槽位耗尽
///    会返回 503，错误原因直接展示给用户。
class EqSheet extends ConsumerStatefulWidget {
  const EqSheet({super.key, required this.playerId});

  final String playerId;

  @override
  ConsumerState<EqSheet> createState() => _EqSheetState();
}

class _EqSheetState extends ConsumerState<EqSheet> {
  static const _freqLabels = [
    '31',
    '62',
    '125',
    '250',
    '500',
    '1k',
    '2k',
    '4k',
    '8k',
    '16k',
  ];

  EqProfile? _eq;
  List<EqPreset> _presets = const [];
  bool _loading = true;
  bool _saving = false;
  String _error = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final controller = ref.read(outputControllerProvider.notifier);
    final eq = await controller.eq(widget.playerId);
    final presets = await controller.eqPresets(widget.playerId);
    if (!mounted) return;
    setState(() {
      _eq = eq ?? EqProfile(enabled: false, bands: List<double>.filled(10, 0));
      _presets = presets ?? const [];
      _loading = false;
      _error = eq == null ? '读取 EQ 失败' : '';
    });
  }

  Future<void> _save() async {
    final eq = _eq;
    if (eq == null) return;
    setState(() => _saving = true);
    final ok = await ref
        .read(outputControllerProvider.notifier)
        .setEq(widget.playerId, eq);
    if (!mounted) return;
    setState(() => _saving = false);
    final s = ref.read(outputControllerProvider);
    if (ok) {
      // 服务端会钳增益、重算 preamp，重新拉一次以显示真实生效值。
      await _load();
      if (!mounted) return;
      ResponsiveSnackBar.showSuccess(context, message: '已保存 EQ');
    } else if (s.error.isNotEmpty) {
      setState(() => _error = s.error);
      ResponsiveSnackBar.showError(context, message: s.error);
    }
  }

  void _applyPreset(EqPreset preset) {
    final eq = _eq;
    if (eq == null) return;
    setState(() {
      _eq = eq.copyWith(
        enabled: true,
        preset: preset.id,
        bands: preset.bands,
        preamp: preset.preamp,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final eq = _eq;

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child:
            _loading
                ? const SizedBox(
                  height: 200,
                  child: Center(child: CircularProgressIndicator()),
                )
                : Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text('均衡器', style: theme.textTheme.titleLarge),
                        ),
                        if (eq != null)
                          Switch.adaptive(
                            value: eq.enabled,
                            onChanged:
                                (v) => setState(() {
                                  _eq = eq.copyWith(enabled: v);
                                }),
                          ),
                      ],
                    ),
                    if (eq != null)
                      Text(
                        eq.enabled
                            ? '前级衰减 ${eq.preamp.toStringAsFixed(1)} dB（服务端算，防削波）'
                            : '已关闭：不占解码槽位',
                        style: theme.textTheme.bodySmall,
                      ),
                    if (_error.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: Text(
                          _error,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.error,
                          ),
                        ),
                      ),
                    if (eq != null) ...[
                      const SizedBox(height: 8),
                      SizedBox(
                        height: 36,
                        child: ListView.separated(
                          scrollDirection: Axis.horizontal,
                          itemCount: _presets.length,
                          separatorBuilder: (_, _) => const SizedBox(width: 8),
                          itemBuilder: (ctx, i) {
                            final p = _presets[i];
                            final selected = eq.preset == p.id;
                            return ChoiceChip(
                              label: Text(p.name),
                              selected: selected,
                              onSelected: (_) => _applyPreset(p),
                            );
                          },
                        ),
                      ),
                      const SizedBox(height: 8),
                      Flexible(
                        child: ListView.builder(
                          shrinkWrap: true,
                          itemCount: 10,
                          itemBuilder: (ctx, i) {
                            final bands =
                                eq.bands.length == 10
                                    ? eq.bands
                                    : List<double>.filled(10, 0);
                            final value = bands[i].clamp(-12.0, 12.0);
                            return Row(
                              children: [
                                SizedBox(
                                  width: 44,
                                  child: Text(
                                    '${_freqLabels[i]}Hz',
                                    style: theme.textTheme.bodySmall,
                                  ),
                                ),
                                Expanded(
                                  child: Slider(
                                    value: value.toDouble(),
                                    min: -12,
                                    max: 12,
                                    divisions: 24,
                                    label:
                                        '${value > 0 ? '+' : ''}${value.toStringAsFixed(1)} dB',
                                    onChanged:
                                        eq.enabled
                                            ? (v) {
                                              final next = List<double>.from(
                                                bands,
                                              );
                                              next[i] = v;
                                              setState(() {
                                                _eq = eq.copyWith(
                                                  bands: next,
                                                  preset: '',
                                                );
                                              });
                                            }
                                            : null,
                                  ),
                                ),
                                SizedBox(
                                  width: 56,
                                  child: Text(
                                    '${value > 0 ? '+' : ''}${value.toStringAsFixed(1)}',
                                    textAlign: TextAlign.right,
                                    style: theme.textTheme.bodySmall,
                                  ),
                                ),
                              ],
                            );
                          },
                        ),
                      ),
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          Expanded(
                            child: OutlinedButton(
                              onPressed:
                                  eq.enabled
                                      ? () => setState(() {
                                        _eq = eq.copyWith(
                                          bands: List<double>.filled(10, 0),
                                          preset: '',
                                        );
                                      })
                                      : null,
                              child: const Text('全部归零'),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: FilledButton(
                              onPressed: _saving ? null : _save,
                              child: Text(_saving ? '保存中…' : '保存'),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ],
                ),
      ),
    );
  }
}

/// 从设备行弹出 EQ 面板。设备列表在下层保持 4s 轮询，这里只读一次快照。
Future<void> showEqSheet(
  BuildContext context,
  WidgetRef ref,
  String playerId,
) async {
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder:
        (ctx) => DraggableScrollableSheet(
          expand: false,
          initialChildSize: 0.85,
          maxChildSize: 0.95,
          builder: (_, _) => EqSheet(playerId: playerId),
        ),
  );
}
