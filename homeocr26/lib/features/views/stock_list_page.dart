import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/stock_item_model.dart';
import '../../viewModels/stock_viewmodel.dart';
import 'invoice_list_widgets.dart';
import '../widgets/system_safe.dart';
import 'live_refresh_mixin.dart';
import 'stock_detail_page.dart';
import '../theme.dart';

class StockListPage extends StatefulWidget {
  const StockListPage({super.key});

  @override
  State<StockListPage> createState() => _StockListPageState();
}

class _StockListPageState extends State<StockListPage> with LiveRefreshMixin {
  late final StockViewModel _viewModel;
  late final ScrollController _scrollController;
  late final TextEditingController _searchController;
  Timer? _searchDebounce;

  @override
  void initState() {
    super.initState();
    _viewModel = StockViewModel();
    _searchController = TextEditingController();
    _scrollController = ScrollController()..addListener(_onScroll);
    _viewModel.prepareForOpen();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      // One load: first page shows immediately, id-order refines in background.
      unawaited(_viewModel.fetchStockList(context, silent: true));
    });
    startLiveRefresh(
      () {
        if (_viewModel.searchQuery.trim().isNotEmpty) {
          return Future<void>.value();
        }
        // Soft refresh — keep cached last-offset for fast refine.
        return _viewModel.fetchStockList(context, silent: true);
      },
    );
  }

  void _onScroll() {
    // Manual "Next" only — no auto prefetch (keeps open/refresh fast).
  }

  void _onSearchChanged(String value) {
    // Local filter immediately for snappy search (e.g. W).
    _viewModel.setSearchQuery(value);
    _searchDebounce?.cancel();
    _searchDebounce = Timer(const Duration(milliseconds: 350), () {
      if (!mounted) return;
      _viewModel.setSearchQuery(value, context: context);
    });
  }

  @override
  void dispose() {
    stopLiveRefresh();
    _searchDebounce?.cancel();
    _searchController.dispose();
    _scrollController.dispose();
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
            'Stock',
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
              onPressed: () => _viewModel.fetchStockList(context, forceRefresh: true),
              icon: const Icon(Icons.refresh, color: sectionText),
            ),
          ],
        ),
        body: Consumer<StockViewModel>(
          builder: (context, model, _) {
            final visible = model.visibleItems;

            return Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
                  child: TextField(
                    controller: _searchController,
                    onChanged: _onSearchChanged,
                    style: const TextStyle(color: sectionText, fontSize: 14),
                    decoration: InputDecoration(
                      hintText: 'Search medicine (first letters)…',
                      hintStyle: TextStyle(
                        color: sectionTextMuted,
                      ),
                      prefixIcon:
                          const Icon(Icons.search, color: sectionTextMuted),
                      suffixIcon: _searchController.text.isEmpty
                          ? null
                          : IconButton(
                              icon: const Icon(Icons.clear,
                                  color: sectionTextMuted),
                              onPressed: () {
                                _searchController.clear();
                                _viewModel.setSearchQuery('',
                                    context: context);
                                setState(() {});
                              },
                            ),
                      filled: true,
                      fillColor: Colors.white.withValues(alpha: 0.1),
                      contentPadding: const EdgeInsets.symmetric(vertical: 0),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide.none,
                      ),
                    ),
                  ),
                ),
                if (model.loadingMore ||
                    model.searching ||
                    model.refiningOrder ||
                    model.statusText.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: Text(
                      model.statusText.isEmpty
                          ? (model.refiningOrder
                              ? 'Sorting by stock id…'
                              : 'Loading…')
                          : model.statusText,
                      style: TextStyle(
                        color: sectionTextMuted,
                        fontSize: 11,
                      ),
                    ),
                  ),
                Expanded(child: _buildBody(model, visible)),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _buildBody(StockViewModel model, List<StockItemModel> visible) {
    if ((model.loading || !model.initialLoadDone) && model.items.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(color: Color(0xFFE07A2F)),
            const SizedBox(height: 12),
            Text(
              model.statusText.isEmpty ? 'Loading stock…' : model.statusText,
              style: TextStyle(
                color: sectionTextMuted,
                fontSize: 13,
              ),
            ),
          ],
        ),
      );
    }

    if (model.error.isNotEmpty && model.items.isEmpty) {
      return InvoiceListError(
        message: model.error,
        onRetry: () => model.fetchStockList(context, forceRefresh: true),
      );
    }

    if (visible.isEmpty) {
      if (model.loading || model.searching || !model.initialLoadDone) {
        return Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const CircularProgressIndicator(color: Color(0xFFE07A2F)),
              const SizedBox(height: 12),
              Text(
                model.statusText.isEmpty ? 'Loading…' : model.statusText,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: sectionTextMuted,
                  fontSize: 13,
                ),
              ),
            ],
          ),
        );
      }
      return RefreshIndicator(
        color: const Color(0xFFE07A2F),
        onRefresh: () => model.fetchStockList(context, forceRefresh: true),
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          children: [
            SizedBox(
              height: MediaQuery.sizeOf(context).height * 0.4,
              child: Center(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 24),
                  child: Text(
                    model.searchQuery.isNotEmpty
                        ? 'No matches for "${model.searchQuery}"'
                        : 'No stock records found',
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: sectionTextMuted),
                  ),
                ),
              ),
            ),
          ],
        ),
      );
    }

    final showFooter = model.searchQuery.trim().isEmpty &&
        !model.refiningOrder &&
        (model.loadingMore || model.hasMore);
    return RefreshIndicator(
      color: const Color(0xFFE07A2F),
      onRefresh: () => model.fetchStockList(context, forceRefresh: true),
      child: ListView.separated(
        physics: const AlwaysScrollableScrollPhysics(),
        controller: _scrollController,
        padding: SystemSafe.listPadding(context),
        itemCount: visible.length + (showFooter ? 1 : 0),
        separatorBuilder: (_, _) => const SizedBox(height: 8),
        itemBuilder: (context, index) {
          if (index >= visible.length) {
            return Padding(
              padding: const EdgeInsets.symmetric(vertical: 16),
              child: Center(
                child: model.loadingMore
                    ? const SizedBox(
                        width: 22,
                        height: 22,
                        child: CircularProgressIndicator(
                          strokeWidth: 2.5,
                          color: const Color(0xFFE07A2F),
                        ),
                      )
                    : FilledButton(
                        onPressed: () => model.loadMore(context),
                        style: FilledButton.styleFrom(
                          backgroundColor: const Color(0xFFE07A2F),
                          foregroundColor: Colors.white,
                        ),
                        child: Text('Next (${model.items.length} loaded)'),
                      ),
              ),
            );
          }
          final item = visible[index];
          return StockListCard(
            item: item,
            onTap: () async {
              final updated = await openStockDetail(context, item);
              if (updated != null && context.mounted) {
                model.replaceLocalItem(updated);
              }
            },
          );
        },
      ),
    );
  }
}

/// Compact single-line row: Name · Company · Potency · Packing · Group · Mrp.
class StockListCard extends StatelessWidget {
  const StockListCard({super.key, required this.item, this.onTap});

  final StockItemModel item;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final card = Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: sectionCard,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: sectionCardBorder),
      ),
      child: Row(
        children: [
          Expanded(
            flex: 3,
            child: _LineCell(
              label: 'Name',
              value: item.medicineLabel,
              emphasize: true,
            ),
          ),
          Expanded(
            flex: 2,
            child: _LineCell(
              label: 'Company',
              value: item.company ?? '—',
            ),
          ),
          Expanded(
            flex: 2,
            child: _LineCell(
              label: 'Potency',
              value: item.potency ?? '—',
            ),
          ),
          Expanded(
            flex: 2,
            child: _LineCell(
              label: 'Packing',
              value: item.packing ?? '—',
            ),
          ),
          Expanded(
            flex: 2,
            child: _LineCell(
              label: 'Group',
              value: item.group ?? '—',
            ),
          ),
          Expanded(
            flex: 2,
            child: _LineCell(
              label: 'Mrp',
              value: StockItemModel.money(item.mrp),
              alignEnd: true,
            ),
          ),
          if (onTap != null) ...[
            const SizedBox(width: 4),
            Icon(
              Icons.chevron_right,
              color: sectionTextMuted,
              size: 20,
            ),
          ],
        ],
      ),
    );

    if (onTap == null) return card;

    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: onTap,
      child: card,
    );
  }
}

class _LineCell extends StatelessWidget {
  const _LineCell({
    required this.label,
    required this.value,
    this.emphasize = false,
    this.alignEnd = false,
  });

  final String label;
  final String value;
  final bool emphasize;
  final bool alignEnd;

  @override
  Widget build(BuildContext context) {
    final align = alignEnd ? TextAlign.right : TextAlign.left;
    return Column(
      crossAxisAlignment:
          alignEnd ? CrossAxisAlignment.end : CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          textAlign: align,
          style: TextStyle(
            color: sectionTextMuted,
            fontSize: 9,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          value,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          textAlign: align,
          style: TextStyle(
            color: sectionText,
            fontWeight: emphasize ? FontWeight.w700 : FontWeight.w600,
            fontSize: emphasize ? 12 : 11,
          ),
        ),
      ],
    );
  }
}
