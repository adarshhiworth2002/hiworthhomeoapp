import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/prefix_search.dart';
import '../../models/invoice_summary_model.dart';
import '../../models/payment_book_model.dart';
import '../../viewModels/customer_invoice_viewmodel.dart';
import '../widgets/app_responsive.dart';
import '../widgets/system_safe.dart';
import 'customer_new_invoice_page.dart';
import 'invoice_list_widgets.dart';
import 'invoice_search_filter_sheet.dart';
import 'list_search_field.dart';
import 'live_refresh_mixin.dart';
import '../theme.dart';
import '../widgets/payment_book_style.dart';

class CustomerInvoiceListPage extends StatefulWidget {
  const CustomerInvoiceListPage({super.key});

  @override
  State<CustomerInvoiceListPage> createState() =>
      _CustomerInvoiceListPageState();
}

class _CustomerInvoiceListPageState extends State<CustomerInvoiceListPage>
    with LiveRefreshMixin {
  late final CustomerInvoiceViewModel _viewModel;
  late final TextEditingController _searchController;
  String _searchQuery = '';

  @override
  void initState() {
    super.initState();
    _viewModel = CustomerInvoiceViewModel();
    _searchController = TextEditingController();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(_viewModel.fetch(context, state: 'all'));
    });
    startLiveRefresh(
      () => _viewModel.fetch(context, forceRefresh: true, silent: true),
      interval: const Duration(seconds: 30),
      immediate: false,
    );
  }

  @override
  void dispose() {
    stopLiveRefresh();
    _searchController.dispose();
    _viewModel.dispose();
    super.dispose();
  }

  Future<void> _openFilter() async {
    final result = await showModalBottomSheet<InvoiceSearchFilterResult>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: sectionBg,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (sheetContext) => InvoiceSearchFilterSheet(
        initialFilter: _viewModel.listFilter,
        parentContext: context,
      ),
    );
    if (!mounted || result == null) return;
    if (result.clear) {
      _viewModel.clearListFilter();
      return;
    }
    _viewModel.applyListFilter(result.filter);
  }

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider.value(
      value: _viewModel,
      child: Scaffold(
        backgroundColor: sectionBg,
        appBar: AppBar(
          iconTheme: const IconThemeData(color: sectionText),
          title: const Text(
            'Customer Invoice',
            style: TextStyle(
              color: sectionText,
              fontWeight: FontWeight.w500,
              fontSize: 17,
            ),
          ),
          backgroundColor: sectionBg,
          elevation: 0,
          actions: [
            IconButton(
              tooltip: 'Filter',
              onPressed: _openFilter,
              icon: const Icon(Icons.filter_list, color: sectionText),
            ),
          ],
        ),
        body: ResponsiveBody(
          child: Consumer<CustomerInvoiceViewModel>(
          builder: (context, model, _) {
            final loadingCatalog = model.loading && model.items.isEmpty;
            final visible = _filterInvoices(model.visibleItems);
            final includeCancelInFooter = model.selectedState == 'cancel';
            final visibleTotal = model.selectedState == 'all'
                ? InvoiceSummaryModel.sumTotals(visible, includeCancel: false)
                : InvoiceSummaryModel.sumTotals(
                    visible,
                    includeCancel: includeCancelInFooter ||
                        model.selectedState != 'all',
                  );
            final visibleBalance = model.selectedState == 'all'
                ? InvoiceSummaryModel.sumBalances(visible, includeCancel: false)
                : InvoiceSummaryModel.sumBalances(visible, includeCancel: true);
            final visibleCount = model.selectedState == 'all'
                ? InvoiceSummaryModel.countBills(visible, includeCancel: false)
                : visible.length;
            return Column(
              children: [
                Padding(
                  padding: SystemSafe.horizontalPadding(context, top: 10, bottom: 8),
                  child: _NewBillGradientButton(
                    loading: loadingCatalog,
                    onPressed:
                        loadingCatalog ? null : () => _openNewBill(context),
                  ),
                ),
                Padding(
                  padding: SystemSafe.horizontalPadding(context, top: 0),
                  child: ListSearchField(
                    controller: _searchController,
                    hintText: 'Search customer or invoice no…',
                    onChanged: (value) => setState(() => _searchQuery = value),
                  ),
                ),
                if (model.listFilter.isActive)
                  Padding(
                    padding: SystemSafe.horizontalPadding(context, bottom: 8),
                    child: _InvoiceFilterChips(
                      filter: model.listFilter,
                      onClear: model.clearListFilter,
                    ),
                  ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                  child: InvoiceStatusFilterChips(
                    selected: model.selectedState,
                    onSelected: (state) =>
                        model.fetch(context, state: state),
                  ),
                ),
                const Padding(
                  padding: EdgeInsets.fromLTRB(16, 0, 16, 8),
                  child: PaymentBookColorLegend(),
                ),
                Expanded(child: _buildBody(model, visible)),
                _InvoiceListTotals(
                  count: visibleCount,
                  total: visibleTotal,
                  balance: visibleBalance,
                ),
              ],
            );
          },
        ),
        ),
      ),
    );
  }

  Future<void> _openNewBill(BuildContext context) async {
    if (_viewModel.loading && _viewModel.items.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Please wait for invoices to finish loading'),
        ),
      );
      return;
    }
    final invoices = List.of(_viewModel.items);
    final saved = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => CustomerNewInvoicePage(existingInvoices: invoices),
      ),
    );
    if (!mounted) return;
    // New bills are drafts — switch to Draft so the user can see them.
    if (saved == true) {
      _searchController.clear();
      setState(() => _searchQuery = '');
      await _viewModel.fetch(
        this.context,
        state: 'draft',
        forceRefresh: true,
      );
      return;
    }
    // Discard / back: force a fresh catalog so deleted drafts disappear.
    await _viewModel.fetch(this.context, forceRefresh: true);
  }

  Widget _buildBody(
    CustomerInvoiceViewModel model,
    List<InvoiceSummaryModel> filtered,
  ) {
    if (model.loading && model.items.isEmpty) {
      return const Center(
        child: CircularProgressIndicator(color: Color(0xFFE07A2F)),
      );
    }
    if (model.error.isNotEmpty && model.items.isEmpty) {
      return InvoiceListError(
        message: model.error,
        onRetry: () => model.fetch(context, forceRefresh: true),
      );
    }

    if (model.items.isEmpty) {
      return RefreshIndicator(
        color: const Color(0xFFE07A2F),
        displacement: 28,
        onRefresh: () => model.fetch(context, forceRefresh: true, silent: true),
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          children: [
            SizedBox(
              height: MediaQuery.sizeOf(context).height * 0.4,
              child: const Center(
                child: Text(
                  'No customer invoices found',
                  style: TextStyle(color: sectionTextMuted),
                ),
              ),
            ),
          ],
        ),
      );
    }
    if (filtered.isEmpty) {
      return RefreshIndicator(
        color: const Color(0xFFE07A2F),
        displacement: 28,
        onRefresh: () => model.fetch(context, forceRefresh: true, silent: true),
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          children: [
            SizedBox(
              height: MediaQuery.sizeOf(context).height * 0.35,
              child: Center(
                child: Text(
                  'No matches for "$_searchQuery"',
                  style: const TextStyle(color: sectionTextMuted),
                ),
              ),
            ),
          ],
        ),
      );
    }
    return RefreshIndicator(
      color: const Color(0xFFE07A2F),
      displacement: 28,
      onRefresh: () => model.fetch(context, forceRefresh: true, silent: true),
      child: ListView.separated(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: SystemSafe.listPadding(context, extraBottom: 8),
        itemCount: filtered.length,
        separatorBuilder: (_, _) => const SizedBox(height: 8),
        itemBuilder: (context, index) {
          final item = filtered[index];
          return InvoiceListCard(
            invoice: item,
            onTap: () => openInvoiceDetail(context, item),
          );
        },
      ),
    );
  }

  List<InvoiceSummaryModel> _filterInvoices(List<InvoiceSummaryModel> items) {
    return items
        .where(
          (item) => PrefixSearch.matchesCustomerOrInvoice(
            query: _searchQuery,
            customer: item.customer,
            displayCustomer: item.displayCustomer,
            displayNumber: item.displayNumber,
            invoiceNumber: item.invoiceNumber,
          ),
        )
        .toList(growable: false);
  }
}

class _InvoiceListTotals extends StatelessWidget {
  const _InvoiceListTotals({
    required this.count,
    required this.total,
    required this.balance,
  });

  final int count;
  final double total;
  final double balance;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: EdgeInsets.fromLTRB(
        AppResponsive.of(context).pagePadding,
        12,
        AppResponsive.of(context).pagePadding,
        SystemSafe.actionBarBottomPadding(context),
      ),
      decoration: BoxDecoration(
        color: sectionFooter,
        border: Border(
          top: BorderSide(color: sectionCardBorder),
        ),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              count == 1 ? 'Total (1 bill)' : 'Total ($count bills)',
              style: TextStyle(
                color: sectionTextMuted,
                fontSize: 15,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                'Balance  ${InvoiceSummaryModel.formatMoney(balance)}',
                style: TextStyle(
                  color: sectionTextMuted,
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                InvoiceSummaryModel.formatMoney(total),
                style: const TextStyle(
                  color: Color(0xFFE07A2F),
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _NewBillGradientButton extends StatelessWidget {
  const _NewBillGradientButton({
    required this.loading,
    required this.onPressed,
  });

  final bool loading;
  final VoidCallback? onPressed;

  static const _gradient = LinearGradient(
    begin: Alignment.centerLeft,
    end: Alignment.centerRight,
    colors: [
      Color(0xFFE07A2F),
      Color(0xFFE8A04A),
      Color(0xFFC43B2E),
    ],
    stops: [0.0, 0.45, 1.0],
  );

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onPressed,
        borderRadius: BorderRadius.circular(14),
        child: Ink(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 18),
          decoration: BoxDecoration(
            gradient: onPressed == null
                ? LinearGradient(
                    begin: Alignment.centerLeft,
                    end: Alignment.centerRight,
                    colors: [
                      const Color(0xFFE07A2F).withValues(alpha: 0.45),
                      const Color(0xFFE8A04A).withValues(alpha: 0.45),
                      const Color(0xFFC43B2E).withValues(alpha: 0.45),
                    ],
                  )
                : _gradient,
            borderRadius: BorderRadius.circular(14),
            boxShadow: onPressed == null
                ? null
                : [
                    BoxShadow(
                      color: const Color(0xFFE07A2F).withValues(alpha: 0.35),
                      blurRadius: 12,
                      offset: const Offset(0, 4),
                    ),
                  ],
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (loading)
                const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(
                    strokeWidth: 2.2,
                    color: Colors.white,
                  ),
                )
              else
                const Icon(Icons.add_circle_outline, color: Colors.white, size: 22),
              const SizedBox(width: 10),
              Text(
                loading ? 'Loading invoices…' : 'New Bill',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 17,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 0.3,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _InvoiceFilterChips extends StatelessWidget {
  const _InvoiceFilterChips({
    required this.filter,
    required this.onClear,
  });

  final PaymentBookFilter filter;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    final parts = filter.chipParts;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(12, 6, 4, 6),
      decoration: BoxDecoration(
        color: sectionCard,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: sectionCardBorder),
      ),
      child: Row(
        children: [
          const Icon(
            Icons.filter_alt_outlined,
            size: 14,
            color: Color(0xFFE07A2F),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              parts.isEmpty ? 'Filtered' : parts.join(' · '),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: sectionText,
                fontSize: 14,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          IconButton(
            tooltip: 'Clear filters',
            onPressed: onClear,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints.tightFor(width: 32, height: 32),
            icon: const Icon(Icons.close, size: 18, color: sectionText),
          ),
        ],
      ),
    );
  }
}
