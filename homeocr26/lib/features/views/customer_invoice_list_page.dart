import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/prefix_search.dart';
import '../../models/invoice_summary_model.dart';
import '../../viewModels/customer_invoice_viewmodel.dart';
import '../widgets/system_safe.dart';
import 'customer_new_invoice_page.dart';
import 'invoice_list_widgets.dart';
import 'list_search_field.dart';
import 'live_refresh_mixin.dart';
import '../theme.dart';

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

  static const _tabs = [
    ('all', 'All'),
    ('draft', 'Draft'),
    ('open', 'Open'),
    ('paid', 'Paid'),
  ];

  @override
  void initState() {
    super.initState();
    _viewModel = CustomerInvoiceViewModel();
    _searchController = TextEditingController();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await _viewModel.fetch(context, state: 'all');
      if (!mounted) return;
      await _viewModel.fetch(context, forceRefresh: true, silent: true);
    });
    startLiveRefresh(
      () => _viewModel.fetch(context, forceRefresh: true, silent: true),
    );
  }

  @override
  void dispose() {
    stopLiveRefresh();
    _searchController.dispose();
    _viewModel.dispose();
    super.dispose();
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
              fontSize: 15,
            ),
          ),
          backgroundColor: sectionBg,
          elevation: 0,
          actions: [
            IconButton(
              onPressed: () => _viewModel.fetch(context, forceRefresh: true),
              icon: const Icon(Icons.refresh, color: sectionText),
            ),
          ],
        ),
        body: Consumer<CustomerInvoiceViewModel>(
          builder: (context, model, _) {
            final loadingCatalog = model.loading && model.items.isEmpty;
            return Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 10, 16, 8),
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
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      children: _tabs.map((tab) {
                        final selected = model.selectedState == tab.$1;
                        return Padding(
                          padding: const EdgeInsets.only(right: 8),
                          child: FilterChip(
                            label: Text(tab.$2),
                            selected: selected,
                            showCheckmark: true,
                            checkmarkColor: const Color(0xFFE07A2F),
                            onSelected: (_) =>
                                model.fetch(context, state: tab.$1),
                            selectedColor: Colors.white,
                            backgroundColor: Colors.white,
                            side: BorderSide(
                              color: selected
                                  ? const Color(0xFFE07A2F)
                                  : Colors.black.withValues(alpha: 0.2),
                            ),
                            labelStyle: TextStyle(
                              color: selected
                                  ? const Color(0xFFE07A2F)
                                  : Colors.black,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        );
                      }).toList(),
                    ),
                  ),
                ),
                Expanded(child: _buildBody(model)),
              ],
            );
          },
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
    await _viewModel.fetch(this.context, forceRefresh: true);
  }

  Widget _buildBody(CustomerInvoiceViewModel model) {
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

    final filtered = _filterInvoices(model.items);
    if (model.items.isEmpty) {
      return RefreshIndicator(
        color: const Color(0xFFE07A2F),
        onRefresh: () => model.fetch(context, forceRefresh: true),
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
        onRefresh: () => model.fetch(context, forceRefresh: true),
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
      onRefresh: () => model.fetch(context, forceRefresh: true),
      child: ListView.separated(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: SystemSafe.listPadding(context),
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
          (item) => PrefixSearch.matchesAny(
            [item.displayCustomer, item.displayNumber, item.invoiceNumber],
            _searchQuery,
          ),
        )
        .toList(growable: false);
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
                  fontSize: 15,
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
