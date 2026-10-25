import 'package:flutter/material.dart';

import '../../domain/output_models.dart';

/// 待机 / 唤醒开关。
///
/// 语义容易误解，所以文案里把边界写清楚：`standby=true` 只表示
/// **服务端不再向它推流**（DLNA 发 Stop 并清 URI，RAOP 停发 RTP），
/// 不代表设备真的断电待机 —— RTSP 与 DLNA 都没有通用的硬件上电指令。
///
/// [exactDisabled] 用于"加入精确同步组"的选择列表：待机设备收不到帧，
/// 也不在同步环里，必须置灰而不是让它进组后悄悄不出声。
class PowerToggle extends StatelessWidget {
  const PowerToggle({
    super.key,
    required this.device,
    required this.onChanged,
    this.busy = false,
    this.exactDisabled = false,
  });

  final OutputDevice device;
  final ValueChanged<bool> onChanged;
  final bool busy;

  /// 置灰（待机设备不可加入精确同步组）。
  final bool exactDisabled;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final on = !device.standby;
    final disabled = busy || !device.online;

    return Tooltip(
      message: device.standby ? '已待机：服务端不向它推流，不代表设备断电' : '待机后从组内分发与同步校正中摘除',
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (device.standby)
            Padding(
              padding: const EdgeInsets.only(right: 6),
              child: Text(
                '待机',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.outline,
                ),
              ),
            ),
          Switch.adaptive(value: on, onChanged: disabled ? null : onChanged),
        ],
      ),
    );
  }
}
