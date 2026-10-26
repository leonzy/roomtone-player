import 'dart:io';

import 'package:flutter/foundation.dart';

/// 平台检测工具类
class PlatformUtils {
  PlatformUtils._();

  /// 是否是 Android 平台
  static bool get isAndroid {
    if (kIsWeb) return false;
    return Platform.isAndroid;
  }

  /// 是否是 iOS 平台
  static bool get isIOS {
    if (kIsWeb) return false;
    return Platform.isIOS;
  }

  /// 是否是移动平台（Android 或 iOS）
  static bool get isMobile {
    if (kIsWeb) return false;
    return Platform.isAndroid || Platform.isIOS;
  }

  /// 是否是桌面平台
  static bool get isDesktop {
    if (kIsWeb) return false;
    return Platform.isWindows || Platform.isMacOS || Platform.isLinux;
  }

  /// 是否是 Web 平台
  static bool get isWeb => kIsWeb;

  /// 是否是 Windows 平台
  static bool get isWindows {
    if (kIsWeb) return false;
    return Platform.isWindows;
  }

  /// 是否支持触摸操作
  static bool get supportsTouchInput {
    if (kIsWeb) return true;
    // 移动设备支持触摸
    if (Platform.isAndroid || Platform.isIOS) return true;
    // 桌面设备假设支持鼠标/触摸
    return true;
  }

  /// 获取当前设备名（用于注册为 local 播放器时的显示名）。
  ///
  /// 优先用主机名；Web / 取不到主机名时退回平台名。不要用 IP 或型号：
  /// 换网后 IP 会变，型号在多台同款设备上会重名。
  static String get deviceName {
    if (kIsWeb) return platformName;
    try {
      final host = Platform.localHostname.trim();
      if (host.isNotEmpty) return host;
    } catch (_) {
      // 某些受限平台不允许读主机名，退回平台名。
    }
    return platformName;
  }

  /// 获取当前平台名称
  static String get platformName {
    if (kIsWeb) return 'Web';
    if (Platform.isAndroid) return 'Android';
    if (Platform.isIOS) return 'iOS';
    if (Platform.isWindows) return 'Windows';
    if (Platform.isMacOS) return 'macOS';
    if (Platform.isLinux) return 'Linux';
    return 'Unknown';
  }
}
