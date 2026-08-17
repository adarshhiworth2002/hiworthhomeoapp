import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Layout breakpoints (Material 3 window sizes).
///
/// - compact: phones
/// - medium: large phones / small tablets
/// - expanded: tablets
class AppBreakpoints {
  static const compact = 600.0;
  static const medium = 840.0;
  static const expanded = 1200.0;
}

/// Screen-size helpers used by every page.
class AppResponsive {
  const AppResponsive._(this.size);

  factory AppResponsive.of(BuildContext context) {
    return AppResponsive._(MediaQuery.sizeOf(context));
  }

  final Size size;

  double get width => size.width;
  double get height => size.height;
  double get shortestSide => size.shortestSide;

  bool get isCompact => width < AppBreakpoints.compact;
  bool get isMedium =>
      width >= AppBreakpoints.compact && width < AppBreakpoints.medium;
  bool get isExpanded => width >= AppBreakpoints.medium;
  bool get isTablet => shortestSide >= AppBreakpoints.compact;
  bool get isNarrowPhone => width < 360;

  /// Centered content width so lists/forms don't stretch on tablets.
  double get contentMaxWidth {
    if (width >= AppBreakpoints.expanded) return 960;
    if (width >= AppBreakpoints.medium) return 840;
    if (width >= AppBreakpoints.compact) return 720;
    return width;
  }

  /// Home grid can use more of a tablet's width.
  double get homeMaxWidth {
    if (width >= 1100) return 1100;
    return width;
  }

  /// Login / compact forms.
  double get formMaxWidth => isTablet ? 480.0 : width;

  double get dialogMaxWidth {
    if (isExpanded) return 560;
    if (isTablet) return 480;
    return width;
  }

  EdgeInsets get dialogInsets {
    if (isTablet) {
      return const EdgeInsets.symmetric(horizontal: 40, vertical: 32);
    }
    return const EdgeInsets.symmetric(horizontal: 16, vertical: 24);
  }

  double get pagePadding {
    if (isNarrowPhone) return 12;
    if (isTablet) return 24;
    return 16;
  }

  int get homeCrossAxisCount {
    if (width >= 1000) return 4;
    if (width >= AppBreakpoints.compact) return 3;
    return 2;
  }

  double get homeTileAspect {
    if (width >= AppBreakpoints.medium) return 1.35;
    if (width >= AppBreakpoints.compact) return 1.2;
    return 1.05;
  }

  int get kpiCrossAxisCount {
    if (width >= AppBreakpoints.medium) return 4;
    if (width >= AppBreakpoints.compact) return 3;
    return 2;
  }

  /// Extra table columns (company, subtotal, …) on wider screens.
  bool get showListSecondary => width >= 400;
  bool get showListTertiary => width >= AppBreakpoints.compact;

  Size scannerFrame({double widthFactor = 0.8, double heightFactor = 0.28}) {
    return Size(
      math.min(width * widthFactor, isTablet ? 420.0 : width * widthFactor),
      math.min(height * heightFactor, isTablet ? 260.0 : 220.0),
    );
  }

  double sheetHeight({double fraction = 0.85}) {
    final raw = height * fraction;
    if (isTablet) return math.min(raw, 720);
    return raw;
  }

  static double scaleClamp(double shortestSide) {
    return (shortestSide / 390).clamp(0.85, 1.25);
  }
}

/// Centers [child] and caps width on tablets. Fills height so
/// [Column] + [Expanded] still work.
class ResponsiveBody extends StatelessWidget {
  const ResponsiveBody({
    super.key,
    required this.child,
    this.maxWidth,
  });

  final Widget child;
  final double? maxWidth;

  @override
  Widget build(BuildContext context) {
    final cap = maxWidth ?? AppResponsive.of(context).contentMaxWidth;
    return LayoutBuilder(
      builder: (context, constraints) {
        final bounded = constraints.hasBoundedHeight;
        return Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: cap,
              minHeight: bounded ? constraints.maxHeight : 0,
              maxHeight: bounded ? constraints.maxHeight : double.infinity,
            ),
            child: SizedBox(width: double.infinity, child: child),
          ),
        );
      },
    );
  }
}

/// Two fields side-by-side on wider screens, stacked on narrow phones.
class AdaptiveSplit extends StatelessWidget {
  const AdaptiveSplit({
    super.key,
    required this.start,
    required this.end,
    this.spacing = 8,
    this.breakpoint = 400,
  });

  final Widget start;
  final Widget end;
  final double spacing;
  final double breakpoint;

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width >= breakpoint;
    if (wide) {
      return Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(child: start),
          SizedBox(width: spacing),
          Expanded(child: end),
        ],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        start,
        SizedBox(height: spacing),
        end,
      ],
    );
  }
}
