import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:homeocr26/features/views/amount_book_page.dart';
import 'package:homeocr26/features/views/cheque_clearance_page.dart';
import 'package:homeocr26/features/views/customer_invoice_list_page.dart';
import 'package:homeocr26/features/views/customer_web_view_page.dart';
import 'package:homeocr26/features/views/employee_performance_page.dart';
import 'package:homeocr26/features/views/login_page.dart';
import 'package:homeocr26/features/views/net_amount_page.dart';
import 'package:homeocr26/features/views/payment_book_page.dart';
import 'package:homeocr26/features/views/payment_history_page.dart';
import 'package:homeocr26/features/views/stock_list_page.dart';
import 'package:provider/provider.dart';

import '../../models/payment_book_model.dart';
import '../../viewModels/cheque_clearance_viewmodel.dart';
import '../../viewModels/login_viewmodel.dart';
import '../../viewModels/net_amount_viewmodel.dart';
import '../../viewModels/payment_book_viewmodel.dart';
import '../services/cheque_clearance_service.dart';
import '../services/cheque_notification_service.dart';
import '../services/home_prefetch_service.dart';
import '../services/live_data_sync.dart';
import '../widgets/app_responsive.dart';

class SelectionScreen extends StatefulWidget {
  const SelectionScreen({super.key});

  @override
  State<SelectionScreen> createState() => _SelectionScreenState();
}

class _SelectionScreenState extends State<SelectionScreen> {
  late final NetAmountViewModel _netAmountViewModel;
  late final PaymentBookViewModel _paymentBookViewModel;

  static const Color _primaryOrange = Color(0xFFF57C00);

  static const Color _pageBackground = Color(0xFFFFFBF7);

  static const Color _textPrimary = Color(0xFF29231F);

  static const Color _textSecondary = Color(0xFF746A63);

  @override
  void initState() {
    super.initState();

    _netAmountViewModel = NetAmountViewModel();
    _paymentBookViewModel = PaymentBookViewModel();

    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_notifyChequeClearance());

      unawaited(
            () async {
          await HomePrefetchService.warmAll(
            context,
            netAmountViewModel: _netAmountViewModel,
          );

          if (!mounted) return;

          await _paymentBookViewModel.fetch(
            context,
            silent: true,
            applyFilter: PaymentBookFilter.today(),
          );

          if (!mounted) return;

          LiveDataSync.start(
            onSync: _liveSync,
          );
        }(),
      );
    });
  }

  // ==========================================================
  // CHEQUE NOTIFICATION
  // ==========================================================

  Future<void> _notifyChequeClearance() async {
    if (!mounted) return;

    var count =
        ChequeClearanceService.cachedItems?.length ?? 0;

    if (count <= 0) {
      final items =
      await ChequeClearanceViewModel.prefetch(context);

      count = items.length;
    }

    if (!mounted || count <= 0) return;

    await ChequeNotificationService.notifyIfNeeded(
      context: context,
      count: count,
      onOpen: () {
        Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) =>
            const ChequeClearancePage(),
          ),
        );
      },
    );
  }

  // ==========================================================
  // OPEN CHEQUE CLEARANCE
  // ==========================================================

  void _openChequeClearance() {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => const ChequeClearancePage(),
      ),
    );
  }

  // ==========================================================
  // LIVE SYNC
  // ==========================================================

  Future<void> _liveSync() async {
    if (!mounted) return;

    // Soft warm other sections; always force payment book so it tracks the
    // website within a few seconds (cache TTL is short).
    await HomePrefetchService.warmAll(
      context,
      netAmountViewModel: _netAmountViewModel,
      forceRefresh: false,
    );

    if (!mounted) return;

    await _paymentBookViewModel.fetch(
      context,
      silent: true,
      forceRefresh: true,
      applyFilter: PaymentBookFilter.today(),
    );
  }

  // ==========================================================
  // DISPOSE
  // ==========================================================

  @override
  void dispose() {
    LiveDataSync.stop();

    _netAmountViewModel.dispose();
    _paymentBookViewModel.dispose();

    super.dispose();
  }

  // ==========================================================
  // OPEN NET AMOUNT
  // ==========================================================

  Future<void> _openNetAmount() async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) {
          return NetAmountPage(
            viewModel: _netAmountViewModel,
          );
        },
      ),
    );

    if (!mounted) return;

    await _netAmountViewModel.fetchBoth(
      context,
      silent: true,
      forceRefresh: true,
    );
  }

  // ==========================================================
  // LOGOUT
  // ==========================================================

  Future<void> _showLogoutDialog() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          backgroundColor: Colors.white,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(22),
          ),
          title: const Row(
            children: [
              Icon(
                Icons.logout_rounded,
                color: _primaryOrange,
              ),
              SizedBox(width: 10),
              Text(
                'Logout',
                style: TextStyle(
                  color: _textPrimary,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
          content: const Text(
            'Are you sure you want to log out?',
            style: TextStyle(
              color: _textSecondary,
            ),
          ),
          actionsPadding: const EdgeInsets.fromLTRB(
            20,
            0,
            20,
            18,
          ),
          actions: [
            TextButton(
              onPressed: () {
                Navigator.pop(dialogContext, false);
              },
              child: const Text(
                'Cancel',
                style: TextStyle(
                  color: _textSecondary,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: _primaryOrange,
                foregroundColor: Colors.white,
                elevation: 0,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(11),
                ),
              ),
              onPressed: () {
                Navigator.pop(dialogContext, true);
              },
              child: const Text(
                'Logout',
              ),
            ),
          ],
        );
      },
    );

    if (confirmed != true || !mounted) return;

    await context.read<LoginViewmodel>().logout();

    if (!mounted) return;

    Navigator.of(context).pushReplacement(
      PageRouteBuilder(
        pageBuilder: (
            context,
            animation,
            secondaryAnimation,
            ) {
          return const LoginPage();
        },
        transitionDuration:
        const Duration(milliseconds: 400),
        transitionsBuilder: (
            context,
            animation,
            secondaryAnimation,
            child,
            ) {
          return FadeTransition(
            opacity: animation,
            child: child,
          );
        },
      ),
    );
  }

  // ==========================================================
  // MOVE APP TO BACKGROUND
  // ==========================================================

  Future<void> _moveToBackground() async {
    if (Platform.isAndroid) {
      try {
        await const MethodChannel(
          'com.example.homeocr26/lifecycle',
        ).invokeMethod('moveToBackground');

        return;
      } catch (_) {}
    }

    await SystemNavigator.pop();
  }

  // ==========================================================
  // BUILD
  // ==========================================================

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final tablet = AppResponsive.of(context).isTablet;
    final page = PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;

        unawaited(_moveToBackground());
      },
      child: MultiProvider(
        providers: [
          ChangeNotifierProvider.value(
            value: _netAmountViewModel,
          ),
          ChangeNotifierProvider.value(
            value: _paymentBookViewModel,
          ),
        ],
        child: Scaffold(
          backgroundColor: _pageBackground,
          body: DecoratedBox(
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Color(0xFFFFE4CC),
                  Color(0xFFFFF6EC),
                  Color(0xFFFFFBF7),
                ],
                stops: [0.0, 0.22, 0.55],
              ),
            ),
            child: SafeArea(
              child: ResponsiveBody(
              maxWidth:
              AppResponsive.of(context).homeMaxWidth,
              child: Column(
                children: [
                  _buildTopBar(context),

                  // ==================================================
                  // DASHBOARD
                  // ==================================================

                  Expanded(
                    child: Consumer2<
                        NetAmountViewModel,
                        PaymentBookViewModel>(
                      builder: (
                          context,
                          netModel,
                          paymentModel,
                          _,
                          ) {
                        return RefreshIndicator(
                          color: _primaryOrange,
                          backgroundColor: Colors.white,
                          onRefresh: () async {
                            await HomePrefetchService
                                .refreshHome(
                              context,
                              netAmountViewModel:
                              _netAmountViewModel,
                            );

                            if (!context.mounted) return;

                            await _paymentBookViewModel.fetch(
                              context,
                              forceRefresh: true,
                              silent: true,
                              applyFilter:
                              PaymentBookFilter.today(),
                            );
                          },
                          child: CustomScrollView(
                            physics:
                            const AlwaysScrollableScrollPhysics(),
                            slivers: [
                              SliverPadding(
                                padding: EdgeInsets.fromLTRB(
                                  AppResponsive.of(context)
                                      .pagePadding,
                                  12,
                                  AppResponsive.of(context)
                                      .pagePadding,
                                  20,
                                ),
                                sliver: SliverGrid(
                                  delegate:
                                  SliverChildListDelegate(
                                    [
                                      // ==================================================
                                      // 1. NET AMOUNT
                                      // ==================================================

                                      _DashboardCard(
                                        title: 'Net Amount',
                                        subtitle: '(Yesterday)',
                                        value: netModel.homeLoading
                                            ? '...'
                                            : NetAmountViewModel
                                            .formatAmount(
                                          netModel
                                              .displayYouGotPaid,
                                        ),
                                        icon: Icons
                                            .currency_rupee_rounded,
                                        imageAsset:
                                        'assets/images/net_amount.png',
                                        accent:
                                        const Color(
                                          0xFFF57C00,
                                        ),
                                        background:
                                        const Color(
                                          0xFFFFF3E8,
                                        ),
                                        onTap:
                                        _openNetAmount,
                                      ),

                                      // ==================================================
                                      // 2. CASH BOOK
                                      // ==================================================

                                      _DashboardCard(
                                        title: 'Cash Book',
                                        icon: Icons
                                            .menu_book_rounded,
                                        imageAsset:
                                        'assets/images/cashbook.png',
                                        accent:
                                        const Color(
                                          0xFFFF9800,
                                        ),
                                        background:
                                        const Color(
                                          0xFFFFF8E8,
                                        ),
                                        onTap: () {
                                          Navigator.of(
                                            context,
                                          ).push(
                                            MaterialPageRoute(
                                              builder: (_) =>
                                              const AmountBookPage(),
                                            ),
                                          );
                                        },
                                      ),

                                      // ==================================================
                                      // 3. TODAY CHEQUE CLEARANCE
                                      // ==================================================

                                      _DashboardCard(
                                        title:
                                        'Today Cheque\nClearance',

                                        icon: Icons
                                            .price_check_rounded,
                                        imageAsset:
                                        'assets/images/cheque.png',
                                        accent:
                                        const Color(
                                          0xFF20A63A,
                                        ),
                                        background:
                                        const Color(
                                          0xFFF0FAF0,
                                        ),
                                        onTap:
                                        _openChequeClearance,
                                      ),

                                      // ==================================================
                                      // 4. PAYMENT HISTORY
                                      // ==================================================

                                      _DashboardCard(
                                        title:
                                        'Payment\nHistory',
                                        icon:
                                        Icons.history_rounded,
                                        imageAsset:
                                        'assets/images/payment_history.png',
                                        accent:
                                        const Color(
                                          0xFF7C3AED,
                                        ),
                                        background:
                                        const Color(
                                          0xFFF4EFFF,
                                        ),
                                        onTap: () {
                                          Navigator.of(
                                            context,
                                          ).push(
                                            MaterialPageRoute(
                                              builder: (_) =>
                                              const PaymentHistoryPage(),
                                            ),
                                          );
                                        },
                                      ),

                                      // ==================================================
                                      // 5. CUSTOMER INVOICE
                                      // ==================================================

                                      _DashboardCard(
                                        title:
                                        'Customer\nInvoice',
                                        icon: Icons
                                            .receipt_long_rounded,
                                        imageAsset:
                                        'assets/images/customer_invoice.png',
                                        accent:
                                        const Color(
                                          0xFF2563EB,
                                        ),
                                        background:
                                        const Color(
                                          0xFFF0F5FF,
                                        ),
                                        onTap: () {
                                          Navigator.of(
                                            context,
                                          ).push(
                                            MaterialPageRoute(
                                              builder: (_) =>
                                              const CustomerInvoiceListPage(),
                                            ),
                                          );
                                        },
                                      ),

                                      // ==================================================
                                      // 6. PAYMENT BOOK
                                      // ==================================================

                                      _DashboardCard(
                                        title: 'Payment\nBook',
                                        icon: Icons
                                            .account_balance_wallet_rounded,
                                        imageAsset:
                                        'assets/images/payment_book.png',
                                        accent:
                                        const Color(
                                          0xFFF43F5E,
                                        ),
                                        background:
                                        const Color(
                                          0xFFFFF0F3,
                                        ),
                                        onTap: () {
                                          Navigator.of(
                                            context,
                                          ).push(
                                            MaterialPageRoute(
                                              builder: (_) =>
                                              const PaymentBookPage(),
                                            ),
                                          );
                                        },
                                      ),

                                      // ==================================================
                                      // 7. CUSTOMER WEB VIEW
                                      // ==================================================

                                      _DashboardCard(
                                        title:
                                        'Customer \nWeb View',
                                        icon:
                                        Icons.language_rounded,
                                        imageAsset:
                                        'assets/images/customer_webview.png',
                                        accent:
                                        const Color(
                                          0xFF0891B2,
                                        ),
                                        background:
                                        const Color(
                                          0xFFECFAFC,
                                        ),
                                        onTap: () {
                                          Navigator.of(
                                            context,
                                          ).push(
                                            MaterialPageRoute(
                                              builder: (_) =>
                                              const CustomerWebViewPage(),
                                            ),
                                          );
                                        },
                                      ),

                                      // ==================================================
                                      // 8. STOCK
                                      // ==================================================

                                      _DashboardCard(
                                        title: 'Stock',
                                        icon: Icons
                                            .inventory_2_rounded,
                                        imageAsset:
                                        'assets/images/stock.png',
                                        accent:
                                        const Color(
                                          0xFFEA580C,
                                        ),
                                        background:
                                        const Color(
                                          0xFFFFF3EC,
                                        ),
                                        onTap: () {
                                          Navigator.of(
                                            context,
                                          ).push(
                                            MaterialPageRoute(
                                              builder: (_) =>
                                              const StockListPage(),
                                            ),
                                          );
                                        },
                                      ),

                                      // ==================================================
                                      // 9. EMPLOYEE PERFORMANCE
                                      // ==================================================

                                      _DashboardCard(
                                        title:
                                        'Employee \nPerformance',
                                        icon:
                                        Icons.insights_rounded,
                                        imageAsset:
                                        'assets/images/employee_performance.png',
                                        accent:
                                        const Color(
                                          0xFF9333EA,
                                        ),
                                        background:
                                        const Color(
                                          0xFFF7F0FF,
                                        ),
                                        onTap: () {
                                          Navigator.of(
                                            context,
                                          ).push(
                                            MaterialPageRoute(
                                              builder: (_) =>
                                              const EmployeePerformancePage(),
                                            ),
                                          );
                                        },
                                      ),
                                    ],
                                  ),
                                  gridDelegate:
                                  _buildGridDelegate(
                                    context,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        );
                      },
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
      ),
    );

    if (!tablet) return page;
    return MediaQuery(
      data: media.copyWith(
        textScaler: TextScaler.linear(
          media.textScaler.scale(1) / AppResponsive.tabletTextScale,
        ),
      ),
      child: page,
    );
  }

  SliverGridDelegate _buildGridDelegate(
      BuildContext context,
      ) {
    final r = AppResponsive.of(context);
    final width = MediaQuery.of(context).size.width;

    double aspectRatio;
    if (width < 360) {
      aspectRatio = 1.10;
    } else if (width < 600) {
      aspectRatio = 1.18;
    } else if (width < 900) {
      aspectRatio = 1.28;
    } else {
      aspectRatio = 1.40;
    }

    return SliverGridDelegateWithFixedCrossAxisCount(
      crossAxisCount: r.homeCrossAxisCount,
      crossAxisSpacing: 12,
      mainAxisSpacing: 12,
      childAspectRatio: aspectRatio,
    );
  }

  _DayGreeting _greetingForNow(String? userName) {
    final hour = DateTime.now().hour;
    final first = (userName ?? '').trim().split(RegExp(r'\s+')).first;
    final name = first;

    if (hour >= 5 && hour < 12) {
      return _DayGreeting(
        title: name.isEmpty ? 'Good Morning' : 'Good Morning',
        emoji: '☀️',
        subtitle: 'Have a productive day',
      );
    }
    if (hour >= 12 && hour < 17) {
      return _DayGreeting(
        title: name.isEmpty ? 'Good Afternoon' : 'Good Afternoon',
        emoji: '🌤️',
        subtitle: "Here's what's happening today",
      );
    }
    return _DayGreeting(
      title: name.isEmpty ? 'Good Evening' : 'Good Evening',
      emoji: '🌙',
      subtitle: 'Hope your day went well',
    );
  }

  Widget _buildTopBar(BuildContext context) {
    final userName = context.watch<LoginViewmodel>().userName;
    final greeting = _greetingForNow(userName);
    final tablet = AppResponsive.of(context).isTablet;
    final emojiBox = tablet ? 58.0 : 44.0;
    final logoutBox = tablet ? 62.0 : 48.0;

    return Padding(
      padding: tablet
          ? const EdgeInsets.fromLTRB(20, 14, 20, 12)
          : const EdgeInsets.fromLTRB(16, 10, 16, 8),
      child: Row(
        children: [
          Expanded(
            child: Container(
              padding: tablet
                  ? const EdgeInsets.fromLTRB(16, 16, 18, 16)
                  : const EdgeInsets.fromLTRB(12, 12, 14, 12),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.94),
                borderRadius: BorderRadius.circular(tablet ? 22 : 18),
                border: Border.all(color: const Color(0xFFFFDFC6)),
                boxShadow: [
                  BoxShadow(
                    color: _primaryOrange.withValues(alpha: 0.10),
                    blurRadius: 16,
                    offset: const Offset(0, 6),
                  ),
                ],
              ),
              child: Row(
                children: [
                  Container(
                    width: emojiBox,
                    height: emojiBox,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      gradient: const LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        colors: [
                          Color(0xFFFFF3E0),
                          Color(0xFFFFE0B2),
                        ],
                      ),
                      borderRadius: BorderRadius.circular(tablet ? 18 : 14),
                    ),
                    child: Text(
                      greeting.emoji,
                      style: TextStyle(
                        fontSize: tablet ? 32 : 24,
                        height: 1,
                      ),
                    ),
                  ),
                  SizedBox(width: tablet ? 16 : 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          greeting.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: _textPrimary,
                            fontSize: tablet ? 22 : 16,
                            fontWeight: FontWeight.w800,
                            height: 1.15,
                          ),
                        ),
                        SizedBox(height: tablet ? 4 : 2),
                        Text(
                          greeting.subtitle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: _textSecondary,
                            fontSize: tablet ? 16 : 12,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
          SizedBox(width: tablet ? 14 : 10),
          Material(
            color: Colors.transparent,
            child: InkWell(
              onTap: _showLogoutDialog,
              borderRadius: BorderRadius.circular(tablet ? 18 : 15),
              child: Ink(
                width: logoutBox,
                height: logoutBox,
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(tablet ? 18 : 15),
                  border: Border.all(color: const Color(0xFFFFDFC6)),
                  boxShadow: [
                    BoxShadow(
                      color: _primaryOrange.withValues(alpha: 0.08),
                      blurRadius: 14,
                      offset: const Offset(0, 5),
                    ),
                  ],
                ),
                child: Icon(
                  Icons.logout_rounded,
                  color: _primaryOrange,
                  size: tablet ? 28 : 22,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}


class _DayGreeting {
  const _DayGreeting({
    required this.title,
    required this.emoji,
    required this.subtitle,
  });

  final String title;
  final String emoji;
  final String subtitle;
}

class _DashboardCard extends StatelessWidget {
  const _DashboardCard({
    required this.title,
    required this.icon,
    required this.imageAsset,
    required this.accent,
    required this.background,
    required this.onTap,
    this.subtitle,
    this.value,
  });

  final String title;
  final String? subtitle;
  final IconData icon;
  final String imageAsset;
  final Color accent;
  final Color background;
  final VoidCallback onTap;
  final String? value;

  static const Color _textPrimary = Color(0xFF29231F);

  @override
  Widget build(BuildContext context) {
    final tablet = AppResponsive.of(context).isTablet;
    final iconBox = tablet ? 56.0 : 38.0;
    final iconSize = tablet ? 30.0 : 20.0;
    final imageSize = tablet ? 168.0 : 102.0;
    final titleSize = tablet ? 22.0 : 16.0;
    final subtitleSize = tablet ? 14.0 : 11.0;
    final valueSize = tablet ? 26.0 : 18.0;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(22),
        splashColor: accent.withValues(alpha: 0.08),
        highlightColor: accent.withValues(alpha: 0.04),
        child: Ink(
          decoration: BoxDecoration(
            color: background,
            borderRadius: BorderRadius.circular(22),
            border: Border.all(color: accent.withValues(alpha: 0.16)),
            boxShadow: [
              BoxShadow(
                color: accent.withValues(alpha: 0.10),
                blurRadius: 14,
                offset: const Offset(0, 6),
              ),
            ],
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(22),
            child: Stack(
              children: [
                _buildDecorations(),
                Positioned(
                  right: tablet ? -4 : -6,
                  bottom: tablet ? -8 : -10,
                  child: IgnorePointer(
                    child: Opacity(
                      opacity: 0.42,
                      child: Image.asset(
                        imageAsset,
                        width: imageSize,
                        height: imageSize,
                        fit: BoxFit.contain,
                        filterQuality: FilterQuality.high,
                      ),
                    ),
                  ),
                ),
                Padding(
                  padding: tablet
                      ? const EdgeInsets.fromLTRB(20, 20, 24, 18)
                      : const EdgeInsets.fromLTRB(14, 14, 40, 12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Container(
                        width: iconBox,
                        height: iconBox,
                        decoration: BoxDecoration(
                          color: accent,
                          borderRadius: BorderRadius.circular(tablet ? 16 : 12),
                          boxShadow: [
                            BoxShadow(
                              color: accent.withValues(alpha: 0.28),
                              blurRadius: 8,
                              offset: const Offset(0, 3),
                            ),
                          ],
                        ),
                        child: Icon(icon, color: Colors.white, size: iconSize),
                      ),
                      const Spacer(),
                      Text(
                        title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: _textPrimary,
                          fontSize: titleSize,
                          height: 1.25,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                      if (subtitle != null) ...[
                        const SizedBox(height: 2),
                        Text(
                          subtitle!,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: _textPrimary.withValues(alpha: 0.45),
                            fontSize: subtitleSize,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                      if (value != null) ...[
                        const SizedBox(height: 4),
                        Text(
                          value!,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: accent,
                            fontSize: valueSize,
                            fontWeight: FontWeight.w800,
                            height: 1.1,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }


  Widget _buildDecorations() {
    return IgnorePointer(
      child: Stack(
        children: [
          Positioned(
            right: -24,
            top: -18,
            child: Container(
              width: 86,
              height: 86,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: accent.withValues(alpha: 0.06),
              ),
            ),
          ),
          Positioned(
            left: -20,
            bottom: -28,
            child: Container(
              width: 70,
              height: 70,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: accent.withValues(alpha: 0.05),
              ),
            ),
          ),
          Positioned(
            right: -10,
            bottom: -18,
            child: Transform.rotate(
              angle: -0.18,
              child: Container(
                width: 110,
                height: 48,
                decoration: BoxDecoration(
                  color: accent.withValues(alpha: 0.06),
                  borderRadius: BorderRadius.circular(24),
                ),
              ),
            ),
          ),
          Positioned(
            right: 38,
            top: 12,
            child: SizedBox(
              width: 28,
              height: 28,
              child: Wrap(
                spacing: 4,
                runSpacing: 4,
                children: List.generate(9, (index) {
                  return Container(
                    width: 3,
                    height: 3,
                    decoration: BoxDecoration(
                      color: accent.withValues(
                        alpha: index % 2 == 0 ? 0.22 : 0.10,
                      ),
                      shape: BoxShape.circle,
                    ),
                  );
                }),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
