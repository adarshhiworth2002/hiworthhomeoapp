import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app_responsive.dart';

/// System inset helpers so content stays clear of status bar, notch, and
/// navigation/gesture bars on all devices.
class SystemSafe {
  SystemSafe._();

  static const _overlayStyle = SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    statusBarIconBrightness: Brightness.dark,
    statusBarBrightness: Brightness.light,
    systemNavigationBarColor: Colors.transparent,
    systemNavigationBarIconBrightness: Brightness.dark,
    systemNavigationBarContrastEnforced: false,
  );

  static Future<void> configure() async {
    WidgetsFlutterBinding.ensureInitialized();
    await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    SystemChrome.setSystemUIOverlayStyle(_overlayStyle);
  }

  /// Wraps every route so system bars never overlap app content.
  static Widget wrapApp(BuildContext context, Widget? child) {
    if (child == null) return const SizedBox.shrink();
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: _overlayStyle,
      child: SafeArea(
        top: false,
        child: child,
      ),
    );
  }

  /// Bottom inset still needed inside scroll views (nav bar + optional FAB).
  static double bottomInset(
    BuildContext context, {
    double extra = 16,
    double fabClearance = 0,
  }) {
    return MediaQuery.paddingOf(context).bottom + extra + fabClearance;
  }

  /// Standard list / scroll padding for full-width pages.
  static EdgeInsets listPadding(
    BuildContext context, {
    double? horizontal,
    double top = 8,
    double extraBottom = 16,
    double fabClearance = 0,
  }) {
    final h = horizontal ?? AppResponsive.of(context).pagePadding;
    return EdgeInsets.fromLTRB(
      h,
      top,
      h,
      bottomInset(
        context,
        extra: extraBottom,
        fabClearance: fabClearance,
      ),
    );
  }

  /// Horizontal-only padding for column layouts (search + list).
  static EdgeInsets horizontalPadding(BuildContext context,
      {double? horizontal, double top = 8, double bottom = 4}) {
    final h = horizontal ?? AppResponsive.of(context).pagePadding;
    return EdgeInsets.fromLTRB(h, top, h, bottom);
  }

  /// Android 3-button nav bar is taller than gesture bar — add a little room.
  static double actionBarBottomPadding(BuildContext context) {
    final base = MediaQuery.paddingOf(context).bottom;
    if (!Platform.isAndroid) return base + 12;
    return base + 16;
  }
}
