import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/output_provider.dart';
import '../providers/zone_focus_provider.dart';
import 'zone_display.dart';
import 'zone_picker.dart';

/// 播放条常驻的区域入口：区域名 + 图标 + 状态点。
///
/// 点击只打开区域选择器，不改变任何区域的播放状态。选择器里的行主体
/// 才负责切焦点（docs/architecture_playback_ui.md §4.2）。
class ZoneButton extends ConsumerWidget {
  const ZoneButton({super.key, this.compact = false});

  /// 窄播放条（迷你播放器 / 手机全屏顶栏）只显示图标与状态点，
  /// 区域名放进 tooltip 与语义标签，避免挤压标题与传输按钮。
  final bool compact;

  static const Key buttonKey = Key('zone-button');

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(outputControllerProvider);
    final focusId = ref.watch(zoneFocusProvider);
    final zone = resolveFocusedZone(state, focusId);
    final theme = Theme.of(context);

    final name = zone?.name ?? '本机';
    final icon = zone == null ? Icons.speaker_rounded : zoneIconFor(zone);
    final dotColor =
        zone == null ? theme.colorScheme.outline : zoneStatusColor(theme, zone);

    final content = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          icon,
          size: 18,
          color:
              zone?.online == false
                  ? theme.colorScheme.outline
                  : theme.colorScheme.onSurface,
        ),
        if (!compact) ...[
          const SizedBox(width: 6),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 96),
            child: Text(
              name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.labelMedium?.copyWith(
                fontWeight: FontWeight.w600,
                color:
                    zone?.online == false
                        ? theme.colorScheme.outline
                        : theme.colorScheme.onSurface,
              ),
            ),
          ),
        ],
        const SizedBox(width: 6),
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(color: dotColor, shape: BoxShape.circle),
        ),
      ],
    );

    return Tooltip(
      message: name,
      child: Semantics(
        button: true,
        label: '区域：$name',
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            key: buttonKey,
            borderRadius: BorderRadius.circular(18),
            onTap: () => showZonePicker(context),
            child: Padding(
              padding: EdgeInsets.symmetric(
                horizontal: compact ? 8 : 10,
                vertical: 6,
              ),
              child: content,
            ),
          ),
        ),
      ),
    );
  }
}
