import 'dart:ui';

import 'package:flutter/material.dart';

/// Shared pharmacy collage backdrop for login + home.
class AppBackdrop extends StatelessWidget {
  const AppBackdrop({
    super.key,
    required this.child,
    this.alignment = Alignment.center,
    this.scrim,
    this.showBottomAccent = true,
  });

  static const assetPath = 'assets/images/homeo_bg.png';

  final Widget child;
  final Alignment alignment;
  final Gradient? scrim;
  final bool showBottomAccent;

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        const DecoratedBox(
          decoration: BoxDecoration(color: Color(0xFFF7F4EF)),
        ),
        Image.asset(
          assetPath,
          fit: BoxFit.cover,
          alignment: alignment,
          filterQuality: FilterQuality.high,
        ),
        DecoratedBox(
          decoration: BoxDecoration(
            gradient: scrim ??
                LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Colors.white.withValues(alpha: 0.55),
                    Colors.white.withValues(alpha: 0.28),
                    Colors.black.withValues(alpha: 0.18),
                    Colors.black.withValues(alpha: 0.52),
                  ],
                  stops: const [0.0, 0.32, 0.68, 1.0],
                ),
          ),
        ),
        if (showBottomAccent)
          const Align(
            alignment: Alignment.bottomCenter,
            child: IgnorePointer(
              child: SizedBox(
                height: 6,
                width: double.infinity,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      colors: [
                        Color(0xFF1B1B1B),
                        Color(0xFFE07A2F),
                        Color(0xFFC43B2E),
                        Color(0xFFE8A04A),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        child,
      ],
    );
  }
}

/// Frosted panel used on top of [AppBackdrop] for forms / content.
class FrostedPanel extends StatelessWidget {
  const FrostedPanel({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(24),
    this.borderRadius = 22,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final double borderRadius;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(borderRadius),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
        child: Container(
          padding: padding,
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.72),
            borderRadius: BorderRadius.circular(borderRadius),
            border: Border.all(
              color: Colors.white.withValues(alpha: 0.55),
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.12),
                blurRadius: 24,
                offset: const Offset(0, 10),
              ),
            ],
          ),
          child: child,
        ),
      ),
    );
  }
}
