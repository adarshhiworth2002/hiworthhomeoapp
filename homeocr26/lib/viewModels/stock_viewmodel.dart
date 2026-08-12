import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../features/services/WebApi/web_api_impl.dart';
import '../features/services/api_request_helper.dart';
import '../features/services/api_response_helper.dart';
import '../features/services/endPoints.dart';
import '../features/services/prefix_search.dart';
import '../models/stock_item_model.dart';
import 'login_viewmodel.dart';

enum StockSortField { stockId, name, mfdDate, expDate }

class _StockFetchResult {
  const _StockFetchResult({required this.items, this.total});
  final List<StockItemModel> items;
  final int? total;
}

class _StockPageSnapshot {
  const _StockPageSnapshot({
    required this.items,
    required this.hasMore,
    required this.useDescTail,
    required this.ascOffset,
    required this.descWindowStart,
    required this.sessionId,
    required this.loadedAt,
  });

  final List<StockItemModel> items;
  final bool hasMore;
  final bool useDescTail;
  final int ascOffset;
  final int descWindowStart;
  final String sessionId;
  final DateTime loadedAt;

  factory _StockPageSnapshot.from(StockViewModel vm) {
    return _StockPageSnapshot(
      items: List<StockItemModel>.from(vm.items),
      hasMore: vm.hasMore,
      useDescTail: vm._useDescTail,
      ascOffset: vm._ascOffset,
      descWindowStart: vm._descWindowStart,
      sessionId: vm._sessionId,
      loadedAt: DateTime.now(),
    );
  }
}

class StockViewModel extends ChangeNotifier {
  static const int pageSize = 100;

  /// Cached across refreshes so open isn't slow every time.
  static int? _cachedLastOffset;
  static _StockPageSnapshot? _sharedSnapshot;
  static const _snapshotTtl = Duration(minutes: 10);

  static Future<void> prefetchFirstPage(
    BuildContext context, {
    bool forceRefresh = false,
  }) async {
    if (!forceRefresh && _isSnapshotFresh()) return;

    final vm = StockViewModel();
    try {
      await vm.fetchStockList(
        context,
        silent: true,
        forceRefresh: forceRefresh,
      );
      if (vm.items.isNotEmpty) {
        _sharedSnapshot = _StockPageSnapshot.from(vm);
      }
    } catch (e, s) {
      if (kDebugMode) debugPrint('Stock prefetch: $e\n$s');
    } finally {
      vm.dispose();
    }
  }

  static void clearGlobalCache() {
    _sharedSnapshot = null;
    // Keep _cachedLastOffset so background id-order refine stays fast.
  }

  static bool _isSnapshotFresh() {
    final snapshot = _sharedSnapshot;
    return snapshot != null &&
        snapshot.items.isNotEmpty &&
        DateTime.now().difference(snapshot.loadedAt) < _snapshotTtl;
  }

  void _applySnapshot(_StockPageSnapshot snapshot) {
    items = List<StockItemModel>.from(snapshot.items);
    hasMore = snapshot.hasMore;
    _useDescTail = snapshot.useDescTail;
    _ascOffset = snapshot.ascOffset;
    _descWindowStart = snapshot.descWindowStart;
    _sessionId = snapshot.sessionId;
    sortField = StockSortField.stockId;
    sortAscending = true;
    searchQuery = '';
    error = '';
    statusText = '${items.length} loaded';
    loading = false;
    searching = false;
    refiningOrder = false;
    initialLoadDone = true;
  }

  void prepareForOpen() {
    if (_isSnapshotFresh()) {
      _applySnapshot(_sharedSnapshot!);
    } else {
      loading = true;
      statusText = 'Loading…';
      error = '';
      initialLoadDone = false;
    }
  }

  void _saveSnapshot() {
    if (items.isEmpty) return;
    _sharedSnapshot = _StockPageSnapshot.from(this);
  }

  bool loading = true;
  bool loadingMore = false;
  bool searching = false;
  /// True while background probe is switching provisional page → id order.
  bool refiningOrder = false;
  bool initialLoadDone = false;
  String error = '';
  List<StockItemModel> items = [];
  bool hasMore = true;
  String searchQuery = '';
  String statusText = 'Loading…';
  String _sessionId = '';
  int _fetchGeneration = 0;
  int _searchGeneration = 0;

  /// Offset for next ascending page when server honors `id asc`.
  int _ascOffset = 0;

  /// Server returns newest-first; we page older→newer via desc offsets.
  bool _useDescTail = false;
  int _descWindowStart = 0;

  StockSortField sortField = StockSortField.stockId;
  bool sortAscending = true;

  /// When set, search UI shows this list (medicine-name prefix matches only).
  List<StockItemModel> _searchHits = const [];

  List<StockItemModel> get visibleItems {
    final query = searchQuery.trim();
    if (query.isNotEmpty) {
      final list = List<StockItemModel>.from(_searchHits);
      _sortList(list, forceName: true);
      return list;
    }
    final list = List<StockItemModel>.from(items);
    _sortList(list);
    return list;
  }

  bool _medicinePrefixMatch(StockItemModel item, String query) {
    return PrefixSearch.matches(item.medicineLabel, query);
  }

  void _rebuildSearchHits() {
    final query = searchQuery.trim();
    if (query.isEmpty) {
      _searchHits = const [];
      return;
    }
    _searchHits = items.where((item) => _medicinePrefixMatch(item, query)).toList();
  }

  /// Apply stock detail edits to the in-memory list without a full reload.
  void replaceLocalItem(StockItemModel updated) {
    final entryId = updated.entryStockId;
    final displayId = updated.stockDisplayId;
    for (var i = 0; i < items.length; i++) {
      final cur = items[i];
      final match = (entryId != null && cur.entryStockId == entryId) ||
          (displayId != null && cur.stockDisplayId == displayId);
      if (match) {
        items[i] = updated;
        break;
      }
    }
    _rebuildSearchHits();
    _saveSnapshot();
    notifyListeners();
  }

  Future<void> fetchStockList(
    BuildContext context, {
    bool forceRefresh = false,
    bool silent = false,
  }) async {
    if (!forceRefresh && _isSnapshotFresh()) {
      _applySnapshot(_sharedSnapshot!);
      notifyListeners();
      return;
    }

    if (forceRefresh) {
      _sharedSnapshot = null;
    }

    final loginModel = Provider.of<LoginViewmodel>(context, listen: false);
    _sessionId = loginModel.sessionId ?? '';
    sortField = StockSortField.stockId;
    sortAscending = true;
    if (!silent) {
      searchQuery = '';
      _searchHits = const [];
    }
    _fetchGeneration++;
    final generation = _fetchGeneration;
    _ascOffset = 0;
    _useDescTail = false;
    _descWindowStart = 0;
    hasMore = true;
    refiningOrder = false;
    error = '';
    loading = true;
    if (!silent) {
      items = [];
      statusText = 'Loading…';
      searching = false;
      notifyListeners();
    } else if (items.isEmpty) {
      statusText = 'Loading…';
      notifyListeners();
    }

    try {
      await _loadFirstPageByStockId(generation);
      _saveSnapshot();
      if (searchQuery.trim().isNotEmpty) {
        _rebuildSearchHits();
      }
    } finally {
      if (generation == _fetchGeneration) {
        loading = false;
        initialLoadDone = true;
        refiningOrder = false;
        if (items.isEmpty && error.isEmpty) {
          statusText = '';
        } else {
          statusText = searchQuery.trim().isNotEmpty
              ? '${_searchHits.length} matches · ${items.length} loaded'
              : '${items.length} loaded';
        }
        notifyListeners();
      }
    }
  }

  Future<void> _loadFirstPageByStockId(int generation) async {
    // 1) Prefer server order by stock id ascending (lowest id first).
    final ordered = await _fetchPage(
      generation: generation,
      params: _idAscParams(offset: 0),
    );
    if (generation != _fetchGeneration) return;

    if (ordered.items.isNotEmpty && _looksLikeOldestFirst(ordered.items)) {
      _useDescTail = false;
      items = _sortedByStockId(ordered.items);
      _ascOffset = ordered.items.length;
      hasMore = ordered.items.length >= pageSize;
      if (kDebugMode) {
        debugPrint(
          'stock id-asc ok first=${items.first.stockId} '
          'last=${items.last.stockId}',
        );
      }
      return;
    }

    // 2) API returns newest-first. Show that page NOW, then refine to id order.
    _useDescTail = false;
    final newestPage = ordered.items.isNotEmpty
        ? ordered
        : await _fetchPage(
            generation: generation,
            params: _plainParams(offset: 0),
          );
    if (generation != _fetchGeneration) return;
    if (newestPage.items.isEmpty) return;

    items = List<StockItemModel>.from(newestPage.items);
    _ascOffset = newestPage.items.length;
    hasMore = newestPage.items.length >= pageSize;
    loading = false;
    initialLoadDone = true;
    refiningOrder = true;
    statusText = 'Sorting by stock id…';
    notifyListeners();
    _saveSnapshot();

    await _refineToIdOrder(generation, newestPage);
  }

  /// After provisional newest page is visible, find catalog end and swap to
  /// website-style lowest stock ids first.
  Future<void> _refineToIdOrder(
    int generation,
    _StockFetchResult newestPage,
  ) async {
    final lastOffset = newestPage.total != null && newestPage.total! > 0
        ? newestPage.total! - 1
        : await _findLastValidOffset(generation);
    if (generation != _fetchGeneration) return;
    if (lastOffset < 0) {
      refiningOrder = false;
      return;
    }
    _cachedLastOffset = lastOffset;

    if (generation == _fetchGeneration) {
      statusText = 'Loading oldest stock…';
      notifyListeners();
    }

    _useDescTail = true;
    _descWindowStart = math.max(0, lastOffset - pageSize + 1);
    final page = await _fetchPage(
      generation: generation,
      params: _plainParams(
        offset: _descWindowStart,
        limit: lastOffset - _descWindowStart + 1,
      ),
    );
    if (generation != _fetchGeneration) return;

    items = _sortedByStockId(page.items);
    hasMore = _descWindowStart > 0;
    refiningOrder = false;
    statusText = '${items.length} loaded';
    _saveSnapshot();
    notifyListeners();

    if (kDebugMode && items.isNotEmpty) {
      debugPrint(
        'stock desc-tail lastOffset=$lastOffset window=$_descWindowStart '
        'first=${items.first.stockId} last=${items.last.stockId}',
      );
    }
  }

  /// Largest offset that still returns a row (0-based).
  Future<int> _findLastValidOffset(int generation) async {
    final cached = _cachedLastOffset;
    if (cached != null && cached >= 0) {
      final stillGood = await _fetchPage(
        generation: generation,
        params: _plainParams(offset: cached, limit: 1),
        retries: 1,
        timeout: const Duration(seconds: 30),
      );
      if (stillGood.items.isNotEmpty) {
        final past = await _fetchPage(
          generation: generation,
          params: _plainParams(offset: cached + 1, limit: 1),
          retries: 1,
          timeout: const Duration(seconds: 30),
        );
        if (past.items.isEmpty) {
          if (kDebugMode) {
            debugPrint('stock lastValidOffset cache hit=$cached');
          }
          return cached;
        }
      }
    }

    var lastGood = 0;
    var offset = pageSize;
    var jump = pageSize;

    while (offset <= 500000 && generation == _fetchGeneration) {
      if (generation == _fetchGeneration) {
        statusText = 'Sorting by stock id…';
        notifyListeners();
      }
      final probe = await _fetchPage(
        generation: generation,
        params: _plainParams(offset: offset, limit: 1),
        retries: 1,
        timeout: const Duration(seconds: 30),
      );
      if (probe.items.isEmpty) break;
      lastGood = offset;
      offset += jump;
      jump = math.min(jump * 2, 5000);
    }

    var lo = lastGood;
    var hi = offset;
    while (lo < hi && generation == _fetchGeneration) {
      final mid = (lo + hi + 1) ~/ 2;
      final probe = await _fetchPage(
        generation: generation,
        params: _plainParams(offset: mid, limit: 1),
        retries: 1,
        timeout: const Duration(seconds: 30),
      );
      if (probe.items.isEmpty) {
        hi = mid - 1;
      } else {
        lo = mid;
      }
    }

    if (kDebugMode) {
      debugPrint('stock lastValidOffset=$lo');
    }
    return lo;
  }

  Future<void> loadMore(BuildContext context) async {
    if (loading ||
        loadingMore ||
        refiningOrder ||
        !hasMore ||
        searchQuery.trim().isNotEmpty) {
      return;
    }
    final loginModel = Provider.of<LoginViewmodel>(context, listen: false);
    _sessionId = loginModel.sessionId ?? _sessionId;
    final generation = _fetchGeneration;
    loadingMore = true;
    statusText = 'Loading next…';
    notifyListeners();

    try {
      if (_useDescTail) {
        if (_descWindowStart <= 0) {
          hasMore = false;
          return;
        }
        final nextStart = math.max(0, _descWindowStart - pageSize);
        final page = await _fetchPage(
          generation: generation,
          params: _plainParams(offset: nextStart, limit: _descWindowStart - nextStart),
        );
        if (generation != _fetchGeneration) return;
        _descWindowStart = nextStart;
        final added = _merge(page.items);
        hasMore = _descWindowStart > 0 && added > 0;
        if (added == 0 && _descWindowStart > 0) {
          // Skip empty/duplicate window.
          _descWindowStart = math.max(0, _descWindowStart - pageSize);
          hasMore = _descWindowStart > 0;
        }
      } else {
        final page = await _fetchPage(
          generation: generation,
          params: _idAscParams(offset: _ascOffset),
        );
        if (generation != _fetchGeneration) return;
        if (page.items.isEmpty) {
          hasMore = false;
          return;
        }
        final added = _merge(page.items);
        _ascOffset += page.items.length;
        hasMore = page.items.length >= pageSize && added > 0;
      }
      statusText = '${items.length} loaded';
    } finally {
      if (generation == _fetchGeneration) {
        loadingMore = false;
        notifyListeners();
      }
    }
  }

  Future<void> setSearchQuery(String value, {BuildContext? context}) async {
    final trimmed = value.trim();
    final changed = searchQuery != trimmed;
    if (changed) {
      searchQuery = trimmed;
      _rebuildSearchHits();
      statusText = trimmed.isEmpty
          ? (items.isEmpty ? '' : '${items.length} loaded')
          : '${_searchHits.length} matches · ${items.length} loaded';
      notifyListeners();
    } else if (trimmed.isNotEmpty) {
      _rebuildSearchHits();
    }

    if (context == null || trimmed.isEmpty) {
      if (trimmed.isEmpty) {
        _searchHits = const [];
        notifyListeners();
      }
      return;
    }

    final loginModel = Provider.of<LoginViewmodel>(context, listen: false);
    _sessionId = loginModel.sessionId ?? _sessionId;
    final searchId = ++_searchGeneration;
    searching = true;
    notifyListeners();

    try {
      // Server often ignores search params — still request them, then
      // keep only medicines whose name starts with the typed prefix.
      final page = await _fetchPage(
        generation: _fetchGeneration,
        params: {
          'get_all': false,
          'limit': pageSize,
          'offset': 0,
          'search': trimmed,
          'medicine': trimmed,
          'medicine_name': trimmed,
          'name': trimmed,
        },
        retries: 1,
        timeout: const Duration(seconds: 45),
      );
      if (searchId != _searchGeneration) return;

      final prefixHits = page.items
          .where((item) => _medicinePrefixMatch(item, trimmed))
          .toList(growable: false);
      if (prefixHits.isNotEmpty) {
        _merge(prefixHits);
      }
      _rebuildSearchHits();
      statusText = '${_searchHits.length} matches · ${items.length} loaded';
    } finally {
      if (searchId == _searchGeneration) {
        searching = false;
        notifyListeners();
      }
    }
  }

  void setSortField(StockSortField field) {
    if (sortField == field) {
      sortAscending = !sortAscending;
    } else {
      sortField = field;
      sortAscending = true;
    }
    notifyListeners();
  }

  void setSortAscending(bool ascending) {
    sortAscending = ascending;
    notifyListeners();
  }

  /// True when page is ascending by stock id (lowest id first).
  bool _looksLikeOldestFirst(List<StockItemModel> page) {
    if (page.isEmpty) return false;
    final ids = page.map((e) => e.stockId).whereType<int>().toList();
    if (ids.isEmpty) return false;
    final first = ids.first;
    final last = ids.last;
    final minId = ids.reduce(math.min);
    final maxId = ids.reduce(math.max);
    // Ascending with lowest first — reject newest-first (high id first).
    final ascending = first <= last && minId == first;
    final newestFirst = first >= last && maxId == first && first != last;
    return ascending && !newestFirst;
  }

  Map<String, dynamic> _idAscParams({required int offset}) {
    return {
      'get_all': false,
      'limit': pageSize,
      'offset': offset,
      'order': 'id asc',
      'sort_by': 'id',
      'sort_order': 'asc',
      'order_by': 'id',
      'ascending': true,
      // Also send display-id keys some Odoo flutter APIs use.
      'order_field': 'stock_display_id',
    };
  }

  Map<String, dynamic> _plainParams({required int offset, int? limit}) {
    return {
      'get_all': false,
      'limit': limit ?? pageSize,
      'offset': offset,
    };
  }

  List<StockItemModel> _sortedByStockId(List<StockItemModel> page) {
    final list = List<StockItemModel>.from(page);
    list.sort((a, b) => (a.stockId ?? 0).compareTo(b.stockId ?? 0));
    return list;
  }

  int _merge(List<StockItemModel> page) {
    final existingIds = items.map((e) => e.stockId).toSet();
    var added = 0;
    for (final item in _sortedByStockId(page)) {
      if (!existingIds.contains(item.stockId)) {
        items.add(item);
        existingIds.add(item.stockId);
        added++;
      }
    }
    // Keep overall list ordered by stock id ascending.
    items = _sortedByStockId(items);
    return added;
  }

  Future<_StockFetchResult> _fetchPage({
    required int generation,
    required Map<String, dynamic> params,
    int retries = 2,
    Duration timeout = const Duration(seconds: 60),
  }) async {
    if (_sessionId.isEmpty) {
      error = 'Session expired. Please log in again.';
      return const _StockFetchResult(items: []);
    }

    Object? lastError;
    for (var attempt = 0; attempt <= retries; attempt++) {
      if (generation != _fetchGeneration) {
        return const _StockFetchResult(items: []);
      }
      try {
        if (attempt > 0) {
          await Future<void>.delayed(Duration(milliseconds: 350 * attempt));
        }
        final webApi = WebApiImpl();
        final response = await webApi.fetchInvoiceList(
          endpointPath: EndPoint.stockList.path,
          userDetails: ApiRequestHelper.jsonRpcCall(params),
          sessionId: _sessionId,
          timeout: timeout,
          logResponseBody: false,
        );
        if (generation != _fetchGeneration) {
          return const _StockFetchResult(items: []);
        }

        if (kDebugMode) {
          debugPrint(
            'get_stock_list params=$params attempt=$attempt '
            'status=${response.statusCode} bytes=${response.bodyBytes.length}',
          );
        }

        if (response.statusCode != 200) {
          lastError = 'HTTP ${response.statusCode}';
          continue;
        }

        final body = await compute(_decodeJsonMap, response.body);
        if (generation != _fetchGeneration) {
          return const _StockFetchResult(items: []);
        }
        if (body['result'] is Map &&
            (body['result'] as Map)['status'] == 'error') {
          error = ApiResponseHelper.errorMessage(
            body,
            fallback: 'Failed to load stock list',
          );
          return const _StockFetchResult(items: []);
        }
        final parsed = StockItemModel.parseList(body);
        final total = _parseTotal(body);
        if (kDebugMode && parsed.isNotEmpty) {
          debugPrint(
            'get_stock_list ids=${parsed.take(3).map((e) => e.stockId).join(",")} '
            'names=${parsed.take(3).map((e) => e.medicineLabel).join(", ")} '
            'total=$total',
          );
        }
        return _StockFetchResult(items: parsed, total: total);
      } catch (e, s) {
        lastError = e;
        if (kDebugMode) debugPrint('stock fetch retry $attempt: $e\n$s');
      }
    }

    if (items.isEmpty && lastError != null) {
      final text = lastError.toString().toLowerCase();
      if (text.contains('connection closed') || text.contains('timeout')) {
        error =
            'Connection closed while loading stock. Pull to refresh and try again.';
      } else {
        error = 'Network error. Please check your connection and try again.';
      }
    }
    return const _StockFetchResult(items: []);
  }

  int? _parseTotal(Map<String, dynamic> body) {
    final result = body['result'];
    if (result is! Map) return null;
    for (final key in ['total', 'count', 'length', 'total_count', 'records_total']) {
      final value = result[key];
      if (value is int) return value;
      if (value is num) return value.toInt();
      final parsed = int.tryParse(value?.toString() ?? '');
      if (parsed != null) return parsed;
    }
    return null;
  }

  void _sortList(List<StockItemModel> list, {bool forceName = false}) {
    list.sort((a, b) {
      int result;
      final field = forceName ? StockSortField.name : sortField;
      switch (field) {
        case StockSortField.stockId:
          result = (a.stockId ?? 0).compareTo(b.stockId ?? 0);
          break;
        case StockSortField.name:
          result = _compareNames(a.medicineLabel, b.medicineLabel);
          break;
        case StockSortField.mfdDate:
          result = _compareDates(a.mfdDate, b.mfdDate);
          break;
        case StockSortField.expDate:
          result = _compareDates(a.expDate, b.expDate);
          break;
      }
      // Search results: always A→Z by medicine name.
      if (forceName) return result;
      return sortAscending ? result : -result;
    });
  }

  int _compareNames(String a, String b) {
    final left = a.trim().toLowerCase();
    final right = b.trim().toLowerCase();
    final leftEmpty = left.isEmpty || left == 'unknown';
    final rightEmpty = right.isEmpty || right == 'unknown';
    if (leftEmpty && rightEmpty) return 0;
    if (leftEmpty) return 1;
    if (rightEmpty) return -1;
    return left.compareTo(right);
  }

  int _compareDates(DateTime? a, DateTime? b) {
    if (a == null && b == null) return 0;
    if (a == null) return 1;
    if (b == null) return -1;
    return a.compareTo(b);
  }
}

Map<String, dynamic> _decodeJsonMap(String body) {
  final decoded = json.decode(body);
  if (decoded is Map<String, dynamic>) return decoded;
  if (decoded is Map) return Map<String, dynamic>.from(decoded);
  return <String, dynamic>{};
}
