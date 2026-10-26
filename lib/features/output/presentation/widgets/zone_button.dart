import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../playback/presentation/providers/local_output_provider.dart';
import '../providers/output_provider.dart';
import '../providers/zone_focus_provider.dart';
import 'zone_display.dart';
import 'zone_picker.dart';

/// 播放条常驻的区域入口：图标在上、区域名在下（Roon 底栏样式）。
///
/// 点击只打开区域选择器，不改变任何区域的播放状态。选择器里的行主体
/// 才负责切焦点（docs/architecture_playback_ui.md §4.2）。
class ZoneButton extends ConsumerWidget {
  const ZoneButton({super.key, this.compact = false});

  /// 窄播放条（迷你播放器 / 手机全屏顶栏 / 胶囊）用更小的图标与字号，
  /// 但区域名始终显示在图标下方，不再只藏在 tooltip 里。
  final bool compact;

  static const Key buttonKey = Key('zone-button');

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(outputControllerProvider);
    final focusId = ref.watch(zoneFocusProvider);
    final zone = resolveFocusedZone(
      state,
      focusId,
      localDeviceId: ref.watch(localDeviceIdProvider),
    );
    final theme = Theme.of(context);

    final name = zone?.name ?? '本机';
    final icon = zone == null ? Icons.speaker_rounded : zoneIconFor(zone);
    final offline = zone?.online == false;
    final dotColor =
        zone == null ? theme.colorScheme.outline : zoneStatusColor(theme, zone);
    final foreground =
        offline ? theme.colorScheme.outline : theme.colorScheme.onSurface;

    final content = Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Stack(
          clipBehavior: Clip.none,
          children: [
            Icon(icon, size: compact ? 18 : 20, color: foreground),
            Positioned(
              right: -3,
              bottom: -2,
              child: Container(
                width: 7,
                height: 7,
                decoration: BoxDecoration(
                  color: dotColor,
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: theme.colorScheme.surface,
                    width: 1,
                  ),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 2),
        ConstrainedBox(
          constraints: BoxConstraints(maxWidth: compact ? 64 : 96),
          child: Text(
            name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: theme.textTheme.labelSmall?.copyWith(
              fontSize: compact ? 9 : 10,
              height: 1.1,
              fontWeight: FontWeight.w600,
              color: foreground,
            ),
          ),
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
            borderRadius: BorderRadius.circular(12),
            onTap: () => showZonePicker(context),
            child: Padding(
              padding: EdgeInsets.symmetric(
                horizontal: compact ? 6 : 8,
                vertical: 4,
              ),
              child: content,
            ),
          ),
        ),
      ),
    );
  }
}
