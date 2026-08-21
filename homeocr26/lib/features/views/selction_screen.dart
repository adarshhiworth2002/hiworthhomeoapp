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
import 'package:homeocr26/features/widgets/app_backdrop.dart';
import 'package:provider/provider.dart';

import '../../viewModels/cheque_clearance_viewmodel.dart';
import '../../viewModels/login_viewmodel.dart';
import '../../viewModels/net_amount_viewmodel.dart';
import '../../viewModels/payment_book_viewmodel.dart';
import '../../models/payment_book_model.dart';
import '../services/cheque_clearance_service.dart';
import '../services/cheque_notification_service.dart';
import '../services/home_prefetch_service.dart';
import '../services/live_data_sync.dart';
import '../theme.dart';
import '../widgets/app_responsive.dart';
import '../widgets/system_safe.dart';

class SelectionScreen extends StatefulWidget {
  const SelectionScreen({super.key});

  @override
  State<SelectionScreen> createState() => _SelectionScreenState();
}

class _SelectionScreenState extends State<SelectionScreen> {
  late final NetAmountViewModel _netAmountViewModel;
  late final PaymentBookViewModel _paymentBookViewModel;

  @override
  void initState() {
    super.initState();
    _netAmountViewModel = NetAmountViewModel();
    _paymentBookViewModel = PaymentBookViewModel();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      // Cheque alert as soon as home is visible — do not wait for warmAll.
      unawaited(_notifyChequeClearance());
      unawaited(() async {
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
        LiveDataSync.start(onSync: _liveSync);
      }());
    });
  }

  Future<void> _notifyChequeClearance() async {
    if (!mounted) return;
    // Prefer any already-cached cheque list so the banner is instant.
    var count = ChequeClearanceService.cachedItems?.length ?? 0;
    if (count <= 0) {
      final items = await ChequeClearanceViewModel.prefetch(context);
      count = items.length;
    }
    if (!mounted || count <= 0) return;
    await ChequeNotificationService.notifyIfNeeded(
      context: context,
      count: count,
      onOpen: () {
        Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => const ChequeClearancePage(),
          ),
        );
      },
    );
  }

  void _openChequeClearance() {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => const ChequeClearancePage(),
      ),
    );
  }

  Future<void> _liveSync() async {
    if (!mounted) return;
    await HomePrefetchService.warmAll(
      context,
      netAmountViewModel: _netAmountViewModel,
      forceRefresh: true,
    );
    if (!mounted) return;
    await _paymentBookViewModel.fetch(
      context,
      silent: true,
      forceRefresh: true,
      applyFilter: PaymentBookFilter.today(),
    );
  }

  @override
  void dispose() {
    LiveDataSync.stop();
    _netAmountViewModel.dispose();
    _paymentBookViewModel.dispose();
    super.dispose();
  }

  Future<void> _openNetAmount() async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => NetAmountPage(viewModel: _netAmountViewModel),
      ),
    );
    if (!mounted) return;
    await _netAmountViewModel.fetchBoth(
      context,
      silent: true,
      forceRefresh: true,
    );
  }

  Future<void> _showLogoutDialog() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: const Text('Logout'),
          content: const Text('Are you sure you want to log out ?'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('Cancel', style: TextStyle(color: appMuted)),
            ),
            FilledButton(
              style: const ButtonStyle(
                backgroundColor: WidgetStatePropertyAll(appOrange),
                foregroundColor: WidgetStatePropertyAll(Colors.white),
              ),
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('Logout'),
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
        pageBuilder: (context, animation, secondaryAnimation) =>
            const LoginPage(),
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

  Future<void> _moveToBackground() async {
    if (Platform.isAndroid) {
      try {
        await const MethodChannel('com.example.homeocr26/lifecycle')
            .invokeMethod('moveToBackground');
        return;
      } catch (_) {}
    }
    await SystemNavigator.pop();
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        unawaited(_moveToBackground());
      },
      child: MultiProvider(
        providers: [
          ChangeNotifierProvider.value(value: _netAmountViewModel),
          ChangeNotifierProvider.value(value: _paymentBookViewModel),
        ],
        child: Scaffold(
        backgroundColor: Colors.transparent,
        extendBodyBehindAppBar: true,
        appBar: AppBar(
          title: const Text(
            'HOMEO ATHURASRAMAM',
            style: TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.w700,
              fontSize: 17,
              letterSpacing: 0.4,
            ),
          ),
          backgroundColor: appOrange.withValues(alpha: 0.92),
          elevation: 0,
          actions: [
            IconButton(
              onPressed: _showLogoutDialog,
              icon: const Icon(Icons.logout),
              color: Colors.white,
            ),
          ],
        ),
        body: AppBackdrop(
          alignment: const Alignment(0, -0.05),
          scrim: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              Colors.black.withValues(alpha: 0.38),
              Colors.black.withValues(alpha: 0.18),
              Colors.black.withValues(alpha: 0.28),
              Colors.black.withValues(alpha: 0.55),
            ],
            stops: const [0.0, 0.28, 0.65, 1.0],
          ),
          child: SafeArea(
            top: false,
            child: ResponsiveBody(
              maxWidth: AppResponsive.of(context).homeMaxWidth,
              child: Padding(
              padding: EdgeInsets.fromLTRB(
                AppResponsive.of(context).pagePadding,
                12,
                AppResponsive.of(context).pagePadding,
                SystemSafe.actionBarBottomPadding(context),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const SizedBox(height: 8),
                  // const Text(
                  //   'Home',
                  //   style: TextStyle(
                  //     color: Colors.white,
                  //     fontSize: 30,
                  //     fontWeight: FontWeight.w800,
                  //     letterSpacing: 0.2,
                  //   ),
                  // ),
                  // const SizedBox(height: 4),
                  // Text(
                  //   'Choose a section to continue',
                  //   style: TextStyle(
                  //     color: Colors.white.withValues(alpha: 0.82),
                  //     fontSize: 15,
                  //     fontWeight: FontWeight.w500,
                  //   ),
                  // ),
                  // const SizedBox(height: 18),
                  Expanded(
                    child: Consumer2<NetAmountViewModel, PaymentBookViewModel>(
                      builder: (context, netModel, _, _) {
                        return RefreshIndicator(
                          color: const Color(0xFFE07A2F),
                          onRefresh: () async {
                            await HomePrefetchService.refreshHome(
                              context,
                              netAmountViewModel: _netAmountViewModel,
                            );
                            if (!context.mounted) return;
                            await _paymentBookViewModel.fetch(
                              context,
                              forceRefresh: true,
                              silent: true,
                              applyFilter: PaymentBookFilter.today(),
                            );
                          },
                          child: LayoutBuilder(
                            builder: (context, constraints) {
                              final r = AppResponsive.of(context);
                              return GridView.count(
                          physics: const AlwaysScrollableScrollPhysics(),
                          crossAxisCount: r.homeCrossAxisCount,
                          mainAxisSpacing: 14,
                          crossAxisSpacing: 14,
                          childAspectRatio: r.homeTileAspect,
                          children: [
                            
                            _HomeTile(
                              title: 'Net Amount\n(Yesterday)',
                              icon: Icons.currency_rupee_outlined,
                              subtitle: netModel.homeLoading
                                  ? '...'
                                  : NetAmountViewModel.formatAmount(
                                      netModel.displayYouGotPaid,
                                    ),
                              accentSubtitle: true,
                              onTap: _openNetAmount,
                            ),
                            _HomeTile(
                              title: 'Cash\nBook',
                              icon: Icons.menu_book_outlined,
                              onTap: () {
                                Navigator.of(context).push(
                                  MaterialPageRoute(
                                    builder: (_) => const AmountBookPage(),
                                  ),
                                );
                              },
                            ),
                            _HomeTile(
                              title: 'Today Cheque\nClearance',
                              icon: Icons.price_check_outlined,
                              onTap: _openChequeClearance,
                            ),
                            _HomeTile(
                              title: 'Payment\nHistory',
                              icon: Icons.history_outlined,
                              onTap: () {
                                Navigator.of(context).push(
                                  MaterialPageRoute(
                                    builder: (_) => const PaymentHistoryPage(),
                                  ),
                                );
                              },
                            ),
                            _HomeTile(
                              title: 'Customer\nInvoice',
                              icon: Icons.receipt_long_outlined,
                              onTap: () {
                                Navigator.of(context).push(
                                  MaterialPageRoute(
                                    builder: (_) =>
                                        const CustomerInvoiceListPage(),
                                  ),
                                );
                              },
                            ),
                            _HomeTile(
                              title: 'Payment\nBook',
                              icon: Icons.payments_outlined,
                              onTap: () {
                                Navigator.of(context).push(
                                  MaterialPageRoute(
                                    builder: (_) => const PaymentBookPage(),
                                  ),
                                );
                              },
                            ),

                            _HomeTile(
                              title: 'Customer\nWeb View',
                              icon: Icons.language_outlined,
                              onTap: () {
                                Navigator.of(context).push(
                                  MaterialPageRoute(
                                    builder: (_) => const CustomerWebViewPage(),
                                  ),
                                );
                              },
                            ),
                            _HomeTile(
                              title: 'Stock',
                              icon: Icons.inventory_2_outlined,
                              onTap: () {
                                Navigator.of(context).push(
                                  MaterialPageRoute(
                                    builder: (_) => const StockListPage(),
                                  ),
                                );
                              },
                            ),
                            _HomeTile(
                              title: 'Employee\nPerformance',
                              icon: Icons.insights_outlined,
                              onTap: () {
                                Navigator.of(context).push(
                                  MaterialPageRoute(
                                    builder: (_) =>
                                        const EmployeePerformancePage(),
                                  ),
                                );
                              },
                            ),
                          ],
                              );
                            },
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
      ),
    );
  }
}

class _HomeTile extends StatelessWidget {
  const _HomeTile({
    required this.title,
    required this.icon,
    required this.onTap,
    this.subtitle,
    this.accentSubtitle = false,
  });

  final String title;
  final IconData icon;
  final VoidCallback onTap;
  final String? subtitle;
  final bool accentSubtitle;

  static const _ink = Color(0xFF1C1A17);
  static const _accent = Color(0xFFE07A2F);

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: onTap,
        child: Ink(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.88),
            borderRadius: BorderRadius.circular(18),
            border: Border.all(
              color: Colors.white.withValues(alpha: 0.65),
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.16),
                blurRadius: 14,
                offset: const Offset(0, 6),
              ),
            ],
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: _accent.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(icon, color: _accent, size: 22),
              ),
              const Spacer(),
              Text(
                title,
                style: const TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.w700,
                  height: 1.2,
                  color: _ink,
                ),
              ),
              if (subtitle != null) ...[
                const SizedBox(height: 6),
                Text(
                  subtitle!,
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w800,
                    color: accentSubtitle
                        ? const Color(0xFFE07A2F)
                        : _ink,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
