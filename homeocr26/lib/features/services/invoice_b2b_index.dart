import 'package:flutter/foundation.dart';

import 'odoo_rpc_helper.dart';

/// Website / backend B2B checkbox on customer invoices (`account.move`).
///
/// Flutter list APIs omit that boolean. We read it from Odoo and treat B2C
/// as every other customer bill (not B2B).
class InvoiceB2bIndex {
  InvoiceB2bIndex._();

  static final Set<int> _b2bMoveIds = {};
  static String? _fieldName;
  static String? _modelName;
  static bool _loaded = false;
  static Future<void>? _inFlight;

  static bool get isReady => _loaded && _fieldName != null;

  static bool isB2bMove(int? moveId) {
    if (moveId == null || moveId <= 0) return false;
    return _b2bMoveIds.contains(moveId);
  }

  static Future<void> loadFromCredentials({
    required String db,
    String? login,
    String? password,
    bool forceRefresh = false,
  }) async {
    if (login == null ||
        login.isEmpty ||
        password == null ||
        password.isEmpty) {
      return;
    }
    final sid = await OdooRpcHelper.cachedWebSessionId(
      db: db,
      login: login,
      password: password,
    );
    if (sid == null || sid.isEmpty) return;
    await load(sid, forceRefresh: forceRefresh);
  }

  static Future<void> load(String sessionId, {bool forceRefresh = false}) async {
    if (_loaded && !forceRefresh) return;
    final pending = _inFlight;
    if (pending != null) {
      await pending;
      return;
    }
    final future = _load(sessionId);
    _inFlight = future;
    try {
      await future;
    } finally {
      if (identical(_inFlight, future)) _inFlight = null;
    }
  }

  static Future<void> _load(String sessionId) async {
    try {
      var ids = await _loadFromAccountMove(sessionId);
      if (ids.isEmpty && _fieldName == null) {
        ids = await _loadFromPharmacyCustomer(sessionId);
      }
      _b2bMoveIds
        ..clear()
        ..addAll(ids);
      _loaded = true;
      if (kDebugMode) {
        debugPrint(
          'B2B checkbox ${_modelName ?? '?'}.${_fieldName ?? '?'} '
          'ids=${_b2bMoveIds.length}',
        );
      }
    } catch (e, s) {
      if (kDebugMode) debugPrint('InvoiceB2bIndex: $e\n$s');
      _loaded = true;
    }
  }

  static Future<Set<int>> _loadFromAccountMove(String sessionId) async {
    final fields = await _discoverBooleanNames(
      sessionId,
      model: 'account.move',
      alsoScanViews: true,
    );
    Set<int> best = {};
    String? bestField;
    for (final field in fields) {
      final ids = await _searchTrueIds(
        sessionId: sessionId,
        model: 'account.move',
        field: field,
        extraDomain: const [
          ['move_type', '=', 'out_invoice'],
        ],
      );
      if (ids.length > best.length) {
        best = ids;
        bestField = field;
      }
    }
    if (bestField != null) {
      _fieldName = bestField;
      _modelName = 'account.move';
    }
    return best;
  }

  static Future<Set<int>> _loadFromPharmacyCustomer(String sessionId) async {
    final names = await _discoverBooleanNames(
      sessionId,
      model: 'pharmacy.customer',
      alsoScanViews: false,
    );
    if (names.isEmpty) return {};
    final field = names.first;
    _fieldName = field;
    _modelName = 'pharmacy.customer';
    final customerIds = await _searchTrueIds(
      sessionId: sessionId,
      model: 'pharmacy.customer',
      field: field,
    );
    if (customerIds.isEmpty) return {};
    final rows = await OdooRpcHelper.callKw(
      sessionId: sessionId,
      model: 'account.move',
      method: 'search_read',
      args: [
        [
          ['move_type', '=', 'out_invoice'],
          ['pharmacy_customer_id', 'in', customerIds.toList()],
        ],
      ],
      kwargs: const {
        'fields': ['id'],
        'limit': 5000,
      },
    );
    return _idsFromRows(rows);
  }

  static Future<List<String>> _discoverBooleanNames(
    String sessionId, {
    required String model,
    required bool alsoScanViews,
  }) async {
    final fromView = alsoScanViews
        ? await _fieldFromViews(sessionId, model)
        : null;

    final meta = await OdooRpcHelper.callKw(
      sessionId: sessionId,
      model: model,
      method: 'fields_get',
      args: const [],
      kwargs: const {
        'attributes': ['type', 'string'],
      },
    );
    if (meta is! Map) {
      return fromView == null ? const <String>[] : [fromView];
    }

    final candidates = <_FieldScore>[];
    if (fromView != null) {
      candidates.add(_FieldScore(fromView, 100));
    }

    for (final entry in meta.entries) {
      final name = entry.key.toString();
      final info = entry.value;
      if (info is! Map) continue;
      final type = (info['type'] ?? '').toString().toLowerCase();
      if (type != 'boolean' && type != 'char' && type != 'selection') {
        continue;
      }
      final label = (info['string'] ?? '').toString();
      final blob = '$name $label'.toLowerCase();
      if (!blob.contains('b2b')) continue;
      if (RegExp(r'\bb2c\b').hasMatch(blob) &&
          !RegExp(r'\bb2b\b').hasMatch(blob)) {
        continue;
      }
      var score = 10;
      if (type == 'boolean') score += 20;
      if (name.toLowerCase() == 'is_b2b' || name.toLowerCase() == 'b2b') {
        score = 90;
      } else if (label.trim().toLowerCase() == 'b2b') {
        score = 80;
      } else if (name.toLowerCase().contains('is_b2b')) {
        score = 70;
      }
      candidates.add(_FieldScore(name, score));
    }

    for (final name in const [
      'is_b2b',
      'b2b',
      'is_b2b_invoice',
      'b2b_invoice',
      'b2b_bill',
      'is_b2b_bill',
    ]) {
      if (meta.containsKey(name) &&
          candidates.every((c) => c.name != name)) {
        candidates.add(_FieldScore(name, 5));
      }
    }

    candidates.sort((a, b) => b.score.compareTo(a.score));
    final seen = <String>{};
    return [
      for (final c in candidates)
        if (seen.add(c.name)) c.name,
    ];
  }

  static Future<String?> _fieldFromViews(
    String sessionId,
    String model,
  ) async {
    final fromAction = await _fieldFromWebsiteAction(sessionId);
    if (fromAction != null) return fromAction;
    for (final viewType in const ['form', 'list']) {
      try {
        final view = await OdooRpcHelper.callKw(
          sessionId: sessionId,
          model: model,
          method: 'fields_view_get',
      kwargs: {
        'view_type': viewType,
        'toolbar': false,
        'context': {
          'default_move_type': 'out_invoice',
        },
      },
        );
        if (view is! Map) continue;
        final name = _fieldNameFromArch((view['arch'] ?? '').toString());
        if (name != null) return name;
      } catch (e) {
        if (kDebugMode) debugPrint('fields_view_get $model $viewType: $e');
      }
    }
    return null;
  }

  /// Customer Invoice website action (`action=400`).
  static Future<String?> _fieldFromWebsiteAction(String sessionId) async {
    try {
      final rows = await OdooRpcHelper.callKw(
        sessionId: sessionId,
        model: 'ir.actions.act_window',
        method: 'read',
        args: const [
          [400],
          ['name', 'res_model', 'views', 'view_id'],
        ],
      );
      if (rows is! List || rows.isEmpty || rows.first is! Map) return null;
      final action = Map<String, dynamic>.from(rows.first as Map);
      final views = action['views'];
      final viewIds = <int>[];
      final viewId = action['view_id'];
      if (viewId is List && viewId.isNotEmpty && viewId.first is int) {
        viewIds.add(viewId.first as int);
      } else if (viewId is int) {
        viewIds.add(viewId);
      }
      if (views is List) {
        for (final item in views) {
          if (item is List && item.isNotEmpty && item.first is int) {
            viewIds.add(item.first as int);
          }
        }
      }
      for (final id in viewIds) {
        final viewRows = await OdooRpcHelper.callKw(
          sessionId: sessionId,
          model: 'ir.ui.view',
          method: 'read',
          args: [
            [id],
            ['arch', 'arch_db', 'name'],
          ],
        );
        if (viewRows is! List || viewRows.isEmpty || viewRows.first is! Map) {
          continue;
        }
        final row = Map<String, dynamic>.from(viewRows.first as Map);
        final arch = (row['arch'] ?? row['arch_db'] ?? '').toString();
        final name = _fieldNameFromArch(arch);
        if (name != null) return name;
      }
    } catch (e) {
      if (kDebugMode) debugPrint('B2B action 400 views: $e');
    }
    return _fieldFromArchSearch(sessionId, 'account.move');
  }

  static Future<String?> _fieldFromArchSearch(
    String sessionId,
    String model,
  ) async {
    try {
      final rows = await OdooRpcHelper.callKw(
        sessionId: sessionId,
        model: 'ir.ui.view',
        method: 'search_read',
        args: const [
          [
            ['model', '=', 'account.move'],
            '|',
            ['arch_db', 'ilike', 'b2b'],
            ['arch_db', 'ilike', 'B2B'],
          ],
        ],
        kwargs: const {
          'fields': ['name', 'arch_db', 'type'],
          'limit': 20,
        },
      );
      if (rows is! List) return null;
      for (final row in rows) {
        if (row is! Map) continue;
        final name = _fieldNameFromArch((row['arch_db'] ?? '').toString());
        if (name != null) return name;
      }
    } catch (e) {
      if (kDebugMode) debugPrint('B2B arch search: $e');
    }
    return null;
  }

  static String? _fieldNameFromArch(String arch) {
    if (arch.isEmpty) return null;
    final named = RegExp(
      r'name="([^"]*b2b[^"]*)"',
      caseSensitive: false,
    ).allMatches(arch);
    for (final match in named) {
      final name = match.group(1);
      if (name == null) continue;
      final lower = name.toLowerCase();
      if (lower.contains('b2c') && !lower.contains('b2b')) continue;
      return name;
    }
    final labeled = RegExp(
      r'''name=["']([^"']+)["'][^>]*>[\s\S]{0,120}?B2B''',
      caseSensitive: false,
    ).firstMatch(arch);
    return labeled?.group(1);
  }

  static Future<Set<int>> _searchTrueIds({
    required String sessionId,
    required String model,
    required String field,
    List<List<dynamic>> extraDomain = const [],
  }) async {
    Future<Set<int>> run(List<dynamic> domain) async {
      final rows = await OdooRpcHelper.callKw(
        sessionId: sessionId,
        model: model,
        method: 'search_read',
        args: [domain],
        kwargs: {
          'fields': ['id', field],
          'limit': 5000,
        },
      );
      return _idsFromRows(rows, requireTrueField: field);
    }

    try {
      return await run([
        ...extraDomain,
        [field, '=', true],
      ]);
    } catch (e) {
      if (kDebugMode) debugPrint('B2B search $model.$field: $e');
      if (extraDomain.isEmpty) return {};
      try {
        return await run([
          [field, '=', true],
        ]);
      } catch (e2) {
        if (kDebugMode) debugPrint('B2B search retry $model.$field: $e2');
        return {};
      }
    }
  }

  static Set<int> _idsFromRows(dynamic rows, {String? requireTrueField}) {
    if (rows is! List) return {};
    final out = <int>{};
    for (final row in rows) {
      if (row is! Map) continue;
      if (requireTrueField != null) {
        final flag = row[requireTrueField];
        if (flag != true && flag != 1) continue;
      }
      final id = row['id'];
      if (id is int) {
        out.add(id);
      } else {
        final parsed = int.tryParse(id?.toString() ?? '');
        if (parsed != null) out.add(parsed);
      }
    }
    return out;
  }
}

class _FieldScore {
  const _FieldScore(this.name, this.score);
  final String name;
  final int score;
}
