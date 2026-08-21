import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'package:provider/provider.dart';

import '../../viewModels/login_viewmodel.dart';
import '../theme.dart';
import '../widgets/app_responsive.dart';
import 'login_page.dart';
import 'selction_screen.dart';

class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _scaleAnimation;
  late Animation<double> _fadeAnimation;

  @override
  void initState() {
    super.initState();

    _controller = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    );

    _scaleAnimation = Tween<double>(
      begin: 0.5,
      end: 1.0,
    ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeOutBack));

    _fadeAnimation = Tween<double>(
      begin: 0,
      end: 1,
    ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeIn));

    _controller.forward();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_goNext());
    });
  }

  Future<void> _goNext() async {
    final login = context.read<LoginViewmodel>();
    final minSplash = Future<void>.delayed(const Duration(seconds: 3));
    if (!login.isLoggedIn) {
      await login.restoreSession();
    }
    final stayLoggedIn = login.isLoggedIn;
    if (stayLoggedIn) {
      unawaited(login.tryAutoLogin());
    }
    await minSplash;
    if (!mounted) return;

    Navigator.of(context).pushReplacement(
      PageRouteBuilder(
        pageBuilder: (context, animation, secondaryAnimation) =>
            stayLoggedIn ? const SelectionScreen() : const LoginPage(),
        transitionDuration: const Duration(milliseconds: 500),
        transitionsBuilder: (context, animation, secondaryAnimation, child) {
          return FadeTransition(
            opacity: animation,
            child: child,
          );
        },
      ),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final r = AppResponsive.of(context);
    final short = size.height < 560;
    final scale = AppResponsive.scaleClamp(size.shortestSide);
    final iconSize = (short ? 64.0 : 90.0) * scale;
    final titleSize = (short ? 20.0 : 24.0) * scale;
    final subtitleSize = (short ? 14.0 : 16.0) * scale;
    final iconPad = (short ? 16.0 : 25.0) * scale;
    final bottomGap = math.min(40.0, size.height * 0.06);

    return Scaffold(
      body: Container(
        width: double.infinity,
        height: double.infinity,
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            colors: [appBlack, appBlackSoft, appOrangeDeep],
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
          ),
        ),
        child: SafeArea(
          bottom: false,
          child: FadeTransition(
            opacity: _fadeAnimation,
            child: Align(
              alignment: Alignment.center,
              child: ConstrainedBox(
                constraints: BoxConstraints(maxWidth: r.formMaxWidth),
                child: Padding(
                  padding: EdgeInsets.symmetric(horizontal: r.pagePadding),
                  child: Column(
                    children: [
                      const Spacer(flex: 3),
                      ScaleTransition(
                        scale: _scaleAnimation,
                        child: Container(
                          padding: EdgeInsets.all(iconPad),
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: Colors.white.withValues(alpha: 0.08),
                          ),
                          child: Icon(
                            Icons.medical_services_rounded,
                            size: iconSize,
                            color: Colors.white,
                          ),
                        ),
                      ),
                      SizedBox(height: short ? 16 : 28),
                      FittedBox(
                        fit: BoxFit.scaleDown,
                        child: Text(
                          'HOMEO ATHURASRAMAM',
                          maxLines: 1,
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontSize: titleSize,
                            fontWeight: FontWeight.bold,
                            letterSpacing: short? 3.2 : 4,
                            color: Colors.white,
                          ),
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'Natural Healing • Trusted Care',
                        textAlign: TextAlign.center,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: subtitleSize,
                          color: Colors.white.withValues(alpha: 0.7),
                        ),
                      ),
                      const Spacer(flex: 2),
                      const SizedBox(
                        width: 28,
                        height: 28,
                        child: CircularProgressIndicator(
                          strokeWidth: 1.5,
                          color: appOrange,
                        ),
                      ),
                      SizedBox(height: bottomGap),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
