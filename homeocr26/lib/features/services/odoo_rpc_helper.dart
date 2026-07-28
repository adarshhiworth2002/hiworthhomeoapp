import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../../models/cheque_clearance_model.dart';
import '../../models/invoice_summary_model.dart';
import 'appConfig.dart';
import 'session_helper.dart';

class InvoiceDraftResult {
  const InvoiceDraftResult({
    required this.invoiceId,
    required this.invoiceNumber,
  });

  final int invoiceId;
  final String invoiceNumber;
}

class _PartnerPaymentLineRef {
  const _PartnerPaymentLineRef({
    required this.moveId,
    this.payAmount,
    this.balance,
    this.total,
    this.invoiceLabel,
    this.selected = false,
  });

  final int moveId;
  final double? payAmount;
  final double? balance;
  final double? total;
  final String? invoiceLabel;
  final bool selected;
}

/// Lightweight Odoo JSON-RPC helpers used when Flutter pharmacy APIs
/// (e.g. add_to_invoice generate) reject empty drafts.
class OdooRpcHelper {
  static String? _cachedWebSessionId;
  static String? _cachedWebLoginKey;
  static DateTime? _cachedWebSessionAt;
  static const _webSessionTtl = Duration(minutes: 15);

  /// Flutter `/api/flutter/login` session is not always a valid Odoo
  /// `/web` session. Authenticate the same way as Customer WebView.
  static Future<String?> cachedWebSessionId({
    required String db,
    required String login,
    required String password,
  }) async {
    final key = '$db|$login';
    final now = DateTime.now();
    if (_cachedWebSessionId != null &&
        _cachedWebLoginKey == key &&
        _cachedWebSessionAt != null &&
        now.difference(_cachedWebSessionAt!) < _webSessionTtl) {
      return _cachedWebSessionId;
    }

    final sid = await webSessionId(db: db, login: login, password: password);
    if (sid != null) {
      _cachedWebSessionId = sid;
      _cachedWebLoginKey = key;
      _cachedWebSessionAt = now;
    }
    return sid;
  }

  static void clearWebSessionCache() {
    _cachedWebSessionId = null;
    _cachedWebLoginKey = null;
    _cachedWebSessionAt = null;
    _fieldsCache.clear();
    _fieldsMetaCache.clear();
    _missingModels.clear();
    _potencyDefaultsCache.clear();
    _cachedPotencyRows = null;
    _cachedPotencyModel = null;
  }

  /// Drop web session and field cache so line field lists stay fresh.
  static void invalidateWebSession() {
    _cachedWebSessionId = null;
    _cachedWebLoginKey = null;
    _cachedWebSessionAt = null;
    _fieldsCache.clear();
    _fieldsMetaCache.clear();
    _potencyDefaultsCache.clear();
  }

  /// Flutter `/api/flutter/login` session is not always a valid Odoo
  /// `/web` session. Authenticate the same way as Customer WebView.
  static Future<String?> webSessionId({
    required String db,
    required String login,
    required String password,
  }) async {
    Object? lastError;
    for (var attempt = 0; attempt < 3; attempt++) {
      if (attempt > 0) {
        await Future<void>.delayed(Duration(milliseconds: 400 * attempt));
      }
      try {
        final sid = await _webSessionIdOnce(
          db: db,
          login: login,
          password: password,
        );
        if (sid != null && sid.isNotEmpty) return sid;
      } catch (e) {
        lastError = e;
        if (kDebugMode) {
          debugPrint('webSessionId attempt $attempt failed: $e');
        }
      }
    }
    if (kDebugMode && lastError != null) {
      debugPrint('webSessionId failed: $lastError');
    }
    return null;
  }

  static Future<String?> _webSessionIdOnce({
    required String db,
    required String login,
    required String password,
  }) async {
    final uri = Uri.parse('${AppConfig.baseAppUrl}web/session/authenticate');
    final response = await http
        .post(
          uri,
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({
            'jsonrpc': '2.0',
            'params': {
              'db': db,
              'login': login,
              'password': password,
            },
          }),
        )
        .timeout(const Duration(seconds: 30));

    if (response.statusCode < 200 || response.statusCode >= 300) {
      return null;
    }

    final decoded = jsonDecode(response.body);
    if (decoded is! Map || decoded['error'] != null) return null;
    final result = decoded['result'];
    if (result is! Map || result['uid'] == null || result['uid'] == false) {
      return null;
    }

    final setCookie = response.headers['set-cookie'];
    if (setCookie != null) {
      final m = RegExp(r'session_id=([^;]+)').firstMatch(setCookie);
      if (m != null && m.group(1)!.isNotEmpty) return m.group(1);
    }

    final sid = result['session_id']?.toString();
    if (sid != null && sid.isNotEmpty) return sid;
    return null;
  }

  static Future<dynamic> callKw({
    required String sessionId,
    required String model,
    required String method,
    List<dynamic> args = const [],
    Map<String, dynamic> kwargs = const {},
  }) async {
    final uri = Uri.parse('${AppConfig.baseAppUrl}web/dataset/call_kw');
    final body = {
      'jsonrpc': '2.0',
      'method': 'call',
      'params': {
        'model': model,
        'method': method,
        'args': args,
        'kwargs': kwargs,
      },
      'id': 1,
    };
    final response = await http
        .post(
          uri,
          headers: {
            'Content-Type': 'application/json',
            'Cookie': SessionHelper.cookie(sessionId),
          },
          body: jsonEncode(body),
        )
        .timeout(const Duration(seconds: 45));

    if (kDebugMode) {
      final preview = response.body.length > 500
          ? '${response.body.substring(0, 500)}…'
          : response.body;
      debugPrint('odoo call_kw $model.$method → $preview');
    }

    if (response.statusCode != 200) {
      throw Exception('Odoo HTTP ${response.statusCode}');
    }
    final decoded = jsonDecode(response.body);
    if (decoded is! Map) throw Exception('Unexpected Odoo response');
    if (decoded['error'] != null) {
      final err = decoded['error'];
      final msg = err is Map
          ? (err['data'] is Map
              ? (err['data']['message'] ?? err['message'])
              : err['message'])
          : err;
      throw Exception(msg?.toString() ?? 'Odoo error');
    }
    return decoded['result'];
  }

  /// Create an empty customer invoice draft and return its display number.
  /// Returns `id:123` when created but name is still `/`.
  /// Create empty customer invoice and return id + pharmacy bill number.
  /// Draft `name` is often `/`; bill no. lives in `display_name` (e.g. `0620/2026-27 - date`).
  static Future<InvoiceDraftResult?> createEmptyCustomerInvoiceDraft(
    String sessionId,
  ) async {
    try {
      final created = await callKw(
        sessionId: sessionId,
        model: 'account.move',
        method: 'create',
        args: [
          {
            'move_type': 'out_invoice',
          },
        ],
        kwargs: {
          'context': {
            'default_move_type': 'out_invoice',
          },
        },
      );
      final id = created is int
          ? created
          : int.tryParse(created?.toString() ?? '');
      if (id == null) return null;

      // Clear Odoo default partner (Administrator) so website/app show blank.
      try {
        await callKw(
          sessionId: sessionId,
          model: 'account.move',
          method: 'write',
          args: [
            [id],
            {'partner_id': false},
          ],
        );
      } catch (_) {}

      final rows = await callKw(
        sessionId: sessionId,
        model: 'account.move',
        method: 'read',
        args: [
          [id],
          [
            'name',
            'display_name',
            'payment_reference',
            'ref',
          ],
        ],
      );
      String? number;
      if (rows is List && rows.isNotEmpty && rows.first is Map) {
        final row = _normalizeOdooMap(
          Map<String, dynamic>.from(rows.first as Map),
        );
        number = _pharmacyInvoiceNumber(row);
      }
      number ??= 'DRAFT-$id';
      return InvoiceDraftResult(invoiceId: id, invoiceNumber: number);
    } catch (e) {
      if (kDebugMode) {
        debugPrint('createEmptyCustomerInvoiceDraft failed: $e');
      }
      return null;
    }
  }

  /// Legacy wrapper — prefer [createEmptyCustomerInvoiceDraft].
  static Future<String?> createEmptyCustomerInvoice(String sessionId) async {
    final draft = await createEmptyCustomerInvoiceDraft(sessionId);
    if (draft == null) return null;
    return draft.invoiceNumber;
  }

  /// Draft pharmacy bills often have `name='/'` and are missing from the
  /// Flutter `get_customer_invoice_list?state=draft` API — load them via Odoo.
  static Future<List<InvoiceSummaryModel>> listDraftCustomerInvoices(
    String sessionId, {
    int limit = 100,
  }) async {
    try {
      final available = await _modelFields(sessionId, 'account.move');
      final wanted = <String>[
        'id',
        'name',
        'display_name',
        'invoice_date',
        'date',
        'state',
        'payment_state',
        'amount_untaxed',
        'amount_tax',
        'amount_total',
        'amount_residual',
        'invoice_partner_display_name',
        'partner_id',
        'pharmacy_customer_id',
        'create_uid',
      ];
      // Unknown fields make Odoo search_read fail entirely.
      final fields = available.isEmpty
          ? <String>['id', 'name', 'display_name', 'state', 'amount_total']
          : wanted.where(available.contains).toList(growable: false);
      if (!fields.contains('id')) fields.insert(0, 'id');

      final rows = await callKw(
        sessionId: sessionId,
        model: 'account.move',
        method: 'search_read',
        args: [
          [
            ['move_type', '=', 'out_invoice'],
            ['state', '=', 'draft'],
          ],
        ],
        kwargs: {
          'fields': fields,
          'limit': limit,
          'order': 'id desc',
        },
      );
      if (rows is! List) return const [];

      final list = <InvoiceSummaryModel>[];
      for (final raw in rows) {
        if (raw is! Map) continue;
        final map = _normalizeOdooMap(Map<String, dynamic>.from(raw));
        final billNo = _pharmacyInvoiceNumber(map) ??
            (map['id'] != null ? 'DRAFT-${map['id']}' : null);
        if (billNo == null || billNo.isEmpty) continue;
        map['invoice_number'] = billNo;
        map['status'] = 'draft';
        map['state'] = 'draft';
        map['move_state'] = 'draft';
        list.add(
          InvoiceSummaryModel.fromJson(Map<String, dynamic>.from(map)),
        );
      }
      if (kDebugMode) {
        debugPrint('listDraftCustomerInvoices → ${list.length} drafts');
      }
      return list;
    } catch (e) {
      if (kDebugMode) debugPrint('listDraftCustomerInvoices failed: $e');
      return const [];
    }
  }

  /// Resolve an [entry.stock] row for invoice line create / QR lookup.
  static Future<Map<String, dynamic>?> findEntryStockRow(
    String sessionId, {
    int? stockDisplayId,
    String? medicine,
    String? batch,
    String? potency,
  }) async {
    try {
      final available = await _modelFields(sessionId, 'entry.stock');
      if (available.isEmpty) return null;

      final fields = <String>['id'];
      for (final f in const [
        'uid',
        'barcode',
        'product_barcode',
        'qr_data',
        'qr_code',
        'default_code',
        'stock_display_id',
        'display_id',
        'medicine_id',
        'batch',
        'batch_no',
        'potency_id',
        'packing_id',
        'pharmacy_company_id',
        'pharmacy_group_id',
        'item_qty',
        'stock',
        'mrp',
      ]) {
        if (available.contains(f)) fields.add(f);
      }

      final domains = <List<dynamic>>[];
      if (stockDisplayId != null) {
        if (available.contains('stock_display_id')) {
          domains.add([
            ['stock_display_id', '=', stockDisplayId],
          ]);
        }
        if (available.contains('display_id')) {
          domains.add([
            ['display_id', '=', stockDisplayId],
          ]);
        }
        domains.add([
          ['id', '=', stockDisplayId],
        ]);
      }

      final med = (medicine ?? '').trim();
      if (med.isNotEmpty && available.contains('medicine_id')) {
        final domain = <List<dynamic>>[
          ['medicine_id.name', 'ilike', med],
        ];
        final bat = (batch ?? '').trim();
        if (bat.isNotEmpty) {
          if (available.contains('batch_no')) {
            domain.add(['batch_no', '=', bat]);
          } else if (available.contains('batch')) {
            domain.add(['batch', '=', bat]);
          }
        }
        final pot = (potency ?? '').trim();
        if (pot.isNotEmpty && available.contains('potency_id')) {
          domain.add(['potency_id.name', '=', pot]);
        }
        domains.add(domain);
      }

      for (final domain in domains) {
        final rows = await callKw(
          sessionId: sessionId,
          model: 'entry.stock',
          method: 'search_read',
          args: [domain],
          kwargs: {
            'fields': fields,
            'limit': 5,
            'order': 'id desc',
          },
        );
        if (rows is! List || rows.isEmpty) continue;
        for (final raw in rows) {
          if (raw is! Map) continue;
          return _normalizeOdooMap(Map<String, dynamic>.from(raw));
        }
      }
      return null;
    } catch (e) {
      if (kDebugMode) debugPrint('findEntryStockRow failed: $e');
      return null;
    }
  }

  /// Resolve add_to_invoice qr_data token from pharmacy stock display id / product.
  static Future<String?> findEntryStockQrToken(
    String sessionId, {
    int? stockDisplayId,
    String? medicine,
    String? batch,
    String? potency,
  }) async {
    final map = await findEntryStockRow(
      sessionId,
      stockDisplayId: stockDisplayId,
      medicine: medicine,
      batch: batch,
      potency: potency,
    );
    if (map == null) return null;
    for (final key in const [
      'product_barcode',
      'barcode',
      'qr_data',
      'qr_code',
      'uid',
      'default_code',
    ]) {
      final v = map[key]?.toString().trim();
      if (v != null && v.isNotEmpty && v != 'false') return v;
    }
    return null;
  }

  static int? _m2oId(dynamic value) {
    if (value == null || value == false) return null;
    if (value is int) return value;
    if (value is num) return value.toInt();
    if (value is List && value.isNotEmpty) {
      final first = value.first;
      if (first is int) return first;
      if (first is num) return first.toInt();
    }
    return int.tryParse('$value');
  }

  /// Add a pharmacy invoice line via [stock_entry_id] (no QR barcode required).
  static Future<bool> addStockLineToCustomerInvoice(
    String sessionId, {
    required int invoiceId,
    required Map<String, dynamic> stockRow,
    required double quantity,
    double? priceUnit,
    double? discount,
  }) async {
    if (invoiceId <= 0 || quantity <= 0) return false;
    final stockId = _m2oId(stockRow['id']);
    if (stockId == null || stockId <= 0) return false;

    try {
      final available = await _modelFields(sessionId, 'account.move.line');
      final vals = <String, dynamic>{
        if (available.contains('display_type')) 'display_type': 'product',
      };

      void putM2o(String field, dynamic raw) {
        if (!available.contains(field)) return;
        final id = _m2oId(raw);
        if (id != null && id > 0) vals[field] = id;
      }

      putM2o('stock_entry_id', stockId);
      putM2o('medicine_id', stockRow['medicine_id']);
      putM2o('potency_id', stockRow['potency_id']);
      putM2o('packing_id', stockRow['packing_id']);
      putM2o('pack_id', stockRow['packing_id']);
      putM2o('pharmacy_company_id', stockRow['pharmacy_company_id']);
      putM2o('pharmacy_group_id', stockRow['pharmacy_group_id']);

      final batch = stockRow['batch'] ?? stockRow['batch_no'];
      if (batch != null && batch != false) {
        final b = batch.toString().trim();
        if (b.isNotEmpty) {
          if (available.contains('batch_no')) {
            vals['batch_no'] = b;
          } else if (available.contains('batch')) {
            vals['batch'] = b;
          }
        }
      }

      final medName = (stockRow['medicine_id_name'] ??
              stockRow['display_name'] ??
              'Product')
          .toString()
          .trim();
      if (available.contains('name')) vals['name'] = medName;
      if (available.contains('product_name')) vals['product_name'] = medName;

      final qtyField = available.contains('quantity')
          ? 'quantity'
          : (available.contains('qty') ? 'qty' : null);
      if (qtyField != null) vals[qtyField] = quantity;

      final unit = priceUnit ??
          (stockRow['mrp'] is num ? (stockRow['mrp'] as num).toDouble() : null);
      if (unit != null) {
        if (available.contains('price_unit')) vals['price_unit'] = unit;
        if (available.contains('u_price')) vals['u_price'] = unit;
        if (available.contains('mrp')) vals['mrp'] = unit;
      }
      if (discount != null && discount > 0 && available.contains('discount')) {
        vals['discount'] = discount;
      }

      if (!vals.containsKey('stock_entry_id') &&
          !vals.containsKey('medicine_id')) {
        if (kDebugMode) {
          debugPrint(
            'addStockLineToCustomerInvoice: no stock_entry_id/medicine_id on line model',
          );
        }
        return false;
      }

      if (kDebugMode) {
        debugPrint(
          'addStockLineToCustomerInvoice invoice=$invoiceId stock=$stockId vals=$vals',
        );
      }

      await callKw(
        sessionId: sessionId,
        model: 'account.move',
        method: 'write',
        args: [
          [invoiceId],
          {
            'invoice_line_ids': [
              [0, 0, vals],
            ],
          },
        ],
      );

      // Best-effort stock qty reduction.
      try {
        final stockAvail = await _modelFields(sessionId, 'entry.stock');
        final qtyKey = stockAvail.contains('item_qty')
            ? 'item_qty'
            : (stockAvail.contains('stock') ? 'stock' : null);
        if (qtyKey != null) {
          final current = stockRow[qtyKey];
          final cur = current is num
              ? current.toDouble()
              : double.tryParse('$current') ?? 0;
          final next = (cur - quantity).clamp(0, double.infinity);
          await callKw(
            sessionId: sessionId,
            model: 'entry.stock',
            method: 'write',
            args: [
              [stockId],
              {qtyKey: next},
            ],
          );
        }
      } catch (_) {}

      return true;
    } catch (e) {
      if (kDebugMode) {
        debugPrint('addStockLineToCustomerInvoice failed: $e');
      }
      return false;
    }
  }

  /// Find or create a `pharmacy.customer` so the website many2one can show it.
  /// Returns the pharmacy.customer id (never a res.partner id).
  static Future<int?> findOrCreatePharmacyCustomer({
    required String sessionId,
    required String name,
    int? existingId,
    String? address,
    String? phone,
  }) async {
    final want = name.trim();

    if (existingId != null && existingId > 0) {
      try {
        final row = await readPharmacyCustomer(sessionId, existingId);
        if (row != null) return existingId;
      } catch (_) {}
    }

    if (want.isEmpty) return null;

    try {
      // Exact name match first.
      final found = await callKw(
        sessionId: sessionId,
        model: 'pharmacy.customer',
        method: 'search_read',
        args: [
          [
            ['name', '=', want],
          ],
        ],
        kwargs: {
          'fields': ['id', 'name'],
          'limit': 5,
        },
      );
      if (found is List) {
        for (final row in found.whereType<Map>()) {
          final id = row['id'];
          final n = (row['name'] ?? '').toString().trim();
          if (n.toLowerCase() != want.toLowerCase()) continue;
          if (id is int) return id;
          final parsed = int.tryParse(id?.toString() ?? '');
          if (parsed != null) return parsed;
        }
      }

      final ns = await callKw(
        sessionId: sessionId,
        model: 'pharmacy.customer',
        method: 'name_search',
        args: [want, [], '=', 8],
      );
      if (ns is List) {
        for (final row in ns) {
          if (row is! List || row.length < 2) continue;
          final label = row[1]?.toString().trim() ?? '';
          if (label.toLowerCase() != want.toLowerCase()) continue;
          final id = row[0];
          if (id is int) return id;
          final parsed = int.tryParse(id?.toString() ?? '');
          if (parsed != null) return parsed;
        }
      }
    } catch (e) {
      if (kDebugMode) debugPrint('find pharmacy.customer "$want": $e');
    }

    // Create so website Customer many2one has a real record.
    try {
      final available = await _modelFields(sessionId, 'pharmacy.customer');
      final createVals = <String, dynamic>{'name': want};
      final addr = (address ?? '').trim();
      final ph = (phone ?? '').trim();
      if (addr.isNotEmpty) {
        if (available.contains('address')) createVals['address'] = addr;
        if (available.contains('street')) createVals['street'] = addr;
      }
      if (ph.isNotEmpty) {
        if (available.contains('mobile')) {
          createVals['mobile'] = ph;
        } else if (available.contains('phone')) {
          createVals['phone'] = ph;
        }
      }
      final created = await callKw(
        sessionId: sessionId,
        model: 'pharmacy.customer',
        method: 'create',
        args: [createVals],
      );
      if (created is int) return created;
      return int.tryParse(created?.toString() ?? '');
    } catch (e) {
      if (kDebugMode) debugPrint('create pharmacy.customer "$want": $e');
      return null;
    }
  }

  /// Update draft/open customer invoice header fields (website form).
  /// Clears default Administrator partner when [clearCustomer] is true.
  ///
  /// Website Customer field is `pharmacy_customer_id` (many2one). Writing only
  /// `customer_name` makes the app show the name while the website stays blank.
  static Future<bool> updateCustomerInvoiceHeader({
    required String sessionId,
    required int invoiceId,
    String? customerName,
    int? pharmacyCustomerId,
    bool clearCustomer = false,
    String? address,
    String? phone,
    String? doctor,
    int? responsiblePersonId,
    String? responsiblePersonName,
    String? paymentMode,
    String? gstType,
    bool? expiryMedicineBill,
    int? discountCategoryId,
    String? discountType,
    double? discountRate,
    String? remarks,
    String? verifiedBy,
  }) async {
    try {
      final available = await _modelFields(sessionId, 'account.move');
      final moveMeta = await _fieldsMeta(sessionId, 'account.move');
      final vals = <String, dynamic>{};

      void putIf(String key, dynamic value) {
        if (!available.contains(key)) return;
        if (value == null) return;
        vals[key] = value;
      }

      if (clearCustomer ||
          ((customerName ?? '').trim().isEmpty && pharmacyCustomerId == null)) {
        if (available.contains('partner_id')) vals['partner_id'] = false;
        if (available.contains('pharmacy_customer_id')) {
          vals['pharmacy_customer_id'] = false;
        }
        if (available.contains('customer_name')) vals['customer_name'] = false;
      } else {
        final name = (customerName ?? '').trim();
        // Always resolve a real pharmacy.customer — website binds to that M2O.
        int? resolvedPharmacyId = pharmacyCustomerId;
        if (name.isNotEmpty) {
          resolvedPharmacyId = await findOrCreatePharmacyCustomer(
            sessionId: sessionId,
            name: name,
            existingId: pharmacyCustomerId,
            address: address,
            phone: phone,
          );
        } else if (pharmacyCustomerId != null) {
          // Validate existing id still exists.
          resolvedPharmacyId = await findOrCreatePharmacyCustomer(
            sessionId: sessionId,
            name: '',
            existingId: pharmacyCustomerId,
          );
        }

        if (resolvedPharmacyId != null) {
          putIf('pharmacy_customer_id', resolvedPharmacyId);
        }
        if (name.isNotEmpty) {
          putIf('customer_name', name);
        }

        // Also set partner_id the way the website expects:
        // - if relation is pharmacy.customer → use that id
        // - if relation is res.partner → use linked partner / name match
        if (available.contains('partner_id')) {
          final partnerRel =
              moveMeta['partner_id']?['relation']?.toString() ?? 'res.partner';
          if (partnerRel == 'pharmacy.customer' && resolvedPharmacyId != null) {
            vals['partner_id'] = resolvedPharmacyId;
          } else if (resolvedPharmacyId != null) {
            // Prefer partner linked on pharmacy.customer, if any.
            int? linkedPartner;
            try {
              final custMeta =
                  await _fieldsMeta(sessionId, 'pharmacy.customer');
              final partnerField = custMeta.containsKey('partner_id')
                  ? 'partner_id'
                  : (custMeta.containsKey('res_partner_id')
                      ? 'res_partner_id'
                      : null);
              if (partnerField != null) {
                final rows = await callKw(
                  sessionId: sessionId,
                  model: 'pharmacy.customer',
                  method: 'read',
                  args: [
                    [resolvedPharmacyId],
                    [partnerField],
                  ],
                );
                if (rows is List && rows.isNotEmpty && rows.first is Map) {
                  final map = _normalizeOdooMap(
                    Map<String, dynamic>.from(rows.first as Map),
                  );
                  final raw = map[partnerField];
                  if (raw is int) {
                    linkedPartner = raw;
                  } else {
                    linkedPartner = int.tryParse(raw?.toString() ?? '');
                  }
                }
              }
            } catch (e) {
              if (kDebugMode) {
                debugPrint('pharmacy.customer partner link: $e');
              }
            }
            if (linkedPartner != null) {
              vals['partner_id'] = linkedPartner;
            } else if (name.isNotEmpty) {
              final partnerId = await _findPartnerIdByName(sessionId, name);
              if (partnerId != null) vals['partner_id'] = partnerId;
            }
          } else if (name.isNotEmpty) {
            final partnerId = await _findPartnerIdByName(sessionId, name);
            if (partnerId != null) vals['partner_id'] = partnerId;
          }
        }
      }

      putIf('manual_address', (address ?? '').trim().isEmpty ? false : address);
      putIf('address', (address ?? '').trim().isEmpty ? null : address);
      putIf('phone_no', (phone ?? '').trim().isEmpty ? false : phone);
      putIf('phone', (phone ?? '').trim().isEmpty ? null : phone);
      putIf('doctor', (doctor ?? '').trim().isEmpty ? false : doctor);
      putIf('doctor_name', (doctor ?? '').trim().isEmpty ? false : doctor);

      if (responsiblePersonId != null) {
        putIf('responsible_person_id', responsiblePersonId);
      } else if ((responsiblePersonName ?? '').trim().isNotEmpty) {
        putIf('responsible_person', responsiblePersonName!.trim());
      }

      if (paymentMode != null && paymentMode.trim().isNotEmpty) {
        putIf('payment_mode', paymentMode.trim().toLowerCase());
      }

      if (gstType != null) {
        final g = gstType.trim().toLowerCase();
        final mapped = g.contains('plus')
            ? 'plus'
            : (g.contains('igst')
                ? 'igst'
                : (g.contains('no') ? 'no_gst' : 'minus'));
        putIf('gst_type', mapped);
      }

      if (expiryMedicineBill != null) {
        putIf('expiry_medicine_bill', expiryMedicineBill);
      }
      if (discountCategoryId != null) {
        putIf('discount_category_id', discountCategoryId);
      }
      if (discountType != null) {
        final t = discountType.trim().toLowerCase();
        putIf(
          'discount_type',
          t.contains('rupee') || t.contains('amount') ? 'amount' : 'percentage',
        );
      }
      if (discountRate != null) putIf('discount_rate', discountRate);
      putIf('narration', (remarks ?? '').trim().isEmpty ? false : remarks);
      putIf('remarks', (remarks ?? '').trim().isEmpty ? false : remarks);
      putIf(
        'verified_by',
        (verifiedBy ?? '').trim().isEmpty ? false : verifiedBy,
      );

      if (vals.isEmpty) return true;

      await callKw(
        sessionId: sessionId,
        model: 'account.move',
        method: 'write',
        args: [
          [invoiceId],
          vals,
        ],
      );
      if (kDebugMode) {
        debugPrint('updateCustomerInvoiceHeader #$invoiceId → $vals');
      }
      return true;
    } catch (e) {
      if (kDebugMode) debugPrint('updateCustomerInvoiceHeader failed: $e');
      return false;
    }
  }

  static Future<int?> _findPartnerIdByName(
    String sessionId,
    String name,
  ) async {
    try {
      final result = await callKw(
        sessionId: sessionId,
        model: 'res.partner',
        method: 'name_search',
        args: [name, [], 'ilike', 5],
      );
      if (result is! List || result.isEmpty) return null;
      for (final row in result) {
        if (row is List && row.length >= 2) {
          final label = row[1]?.toString().trim().toLowerCase() ?? '';
          if (label == name.toLowerCase() || label.startsWith(name.toLowerCase())) {
            final id = row[0];
            if (id is int) return id;
            return int.tryParse(id?.toString() ?? '');
          }
        }
      }
      final first = result.first;
      if (first is List && first.isNotEmpty) {
        final id = first[0];
        if (id is int) return id;
        return int.tryParse(id?.toString() ?? '');
      }
    } catch (e) {
      if (kDebugMode) debugPrint('_findPartnerIdByName failed: $e');
    }
    return null;
  }

  /// Load partner names for Customer & Doctor dropdowns.
  static Future<List<String>> searchPartnerNames(
    String sessionId, {
    int limit = 120,
  }) async {
    final names = <String>{};

    Future<void> fromModel(String model) async {
      try {
        final result = await callKw(
          sessionId: sessionId,
          model: model,
          method: 'name_search',
          args: ['', [], 'ilike', limit],
        );
        if (result is! List) return;
        for (final row in result) {
          if (row is List && row.length >= 2) {
            final name = row[1]?.toString().trim() ?? '';
            if (name.isNotEmpty) names.add(name);
          } else if (row is Map) {
            final name = (row['display_name'] ?? row['name'] ?? '')
                .toString()
                .trim();
            if (name.isNotEmpty) names.add(name);
          }
        }
      } catch (e) {
        if (kDebugMode) debugPrint('name_search $model: $e');
      }
    }

    await fromModel('res.partner');
    await fromModel('pharmacy.customer');

    final sorted = names.toList()
      ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    return sorted;
  }

  /// Pharmacy customer rows with address / phone / credit flags for New Bill.
  static Future<List<Map<String, dynamic>>> searchPharmacyCustomers(
    String sessionId, {
    int limit = 5000,
  }) async {
    try {
      final available = await _modelFields(sessionId, 'pharmacy.customer');
      final fields = <String>['id', 'name'];
      for (final f in const [
        'mobile',
        'phone',
        'address',
        'place',
        'credit_limit_amount',
        'credit_limit_days',
      ]) {
        if (available.contains(f)) fields.add(f);
      }
      final rows = await callKw(
        sessionId: sessionId,
        model: 'pharmacy.customer',
        method: 'search_read',
        args: const [[]],
        kwargs: {
          'fields': fields,
          'limit': limit,
          'order': 'name asc',
        },
      );
      if (rows is! List) return const [];
      return rows
          .whereType<Map>()
          .map((e) => _normalizeOdooMap(Map<String, dynamic>.from(e)))
          .toList(growable: false);
    } catch (e) {
      if (kDebugMode) debugPrint('searchPharmacyCustomers: $e');
      return const [];
    }
  }

  /// Single pharmacy customer details (address, mobile, credit).
  static Future<Map<String, dynamic>?> readPharmacyCustomer(
    String sessionId,
    int customerId,
  ) async {
    try {
      final rows = await callKw(
        sessionId: sessionId,
        model: 'pharmacy.customer',
        method: 'read',
        args: [
          [customerId],
          [
            'id',
            'name',
            'mobile',
            'address',
            'place',
            'credit_limit_amount',
            'credit_limit_days',
          ],
        ],
      );
      if (rows is! List || rows.isEmpty || rows.first is! Map) return null;
      return _normalizeOdooMap(Map<String, dynamic>.from(rows.first as Map));
    } catch (e) {
      if (kDebugMode) debugPrint('readPharmacyCustomer: $e');
      return null;
    }
  }

  /// Website Responsible Person dropdown (`pharmacy.responsible`).
  static Future<List<Map<String, dynamic>>> searchResponsiblePersons(
    String sessionId, {
    int limit = 100,
  }) async {
    try {
      final rows = await callKw(
        sessionId: sessionId,
        model: 'pharmacy.responsible',
        method: 'search_read',
        args: const [[]],
        kwargs: {
          'fields': ['id', 'name', 'display_name'],
          'limit': limit,
          'order': 'name asc',
        },
      );
      if (rows is! List) return const [];
      return rows
          .whereType<Map>()
          .map((e) => _normalizeOdooMap(Map<String, dynamic>.from(e)))
          .toList(growable: false);
    } catch (e) {
      if (kDebugMode) debugPrint('searchResponsiblePersons: $e');
      return const [];
    }
  }

  /// Website master dropdown values (potency / group / company / pack / …).
  /// Tries known pharmacy models and returns names in website order.
  static Future<List<String>> searchPharmacyMasterNames(
    String sessionId, {
    required List<String> models,
    int limit = 1000,
  }) async {
    for (final model in models) {
      if (_missingModels.contains(model)) continue;
      try {
        final available = await _modelFields(sessionId, model);
        if (available.isEmpty) {
          _missingModels.add(model);
          continue;
        }

        final fields = <String>['id', 'name', 'display_name'];
        if (available.contains('sequence')) fields.add('sequence');

        final order = available.contains('sequence')
            ? 'sequence asc, id asc'
            : (available.contains('name') ? 'name asc, id asc' : 'id asc');

        final names = <String>[];
        final seen = <String>{};
        var offset = 0;
        final pageSize = limit > 200 ? 100 : limit;

        while (names.length < limit) {
          final rows = await callKw(
            sessionId: sessionId,
            model: model,
            method: 'search_read',
            args: const [[]],
            kwargs: {
              'fields': fields,
              'limit': pageSize,
              'offset': offset,
              'order': order,
            },
          );
          if (rows is! List || rows.isEmpty) break;

          for (final row in rows.whereType<Map>()) {
            final map = _normalizeOdooMap(Map<String, dynamic>.from(row));
            final name = (map['display_name'] ?? map['name'] ?? '')
                .toString()
                .trim();
            if (name.isEmpty || name == 'false') continue;
            final key = name.toLowerCase();
            if (seen.add(key)) names.add(name);
            if (names.length >= limit) break;
          }

          if (rows.length < pageSize) break;
          offset += pageSize;
          if (offset > 5000) break;
        }

        if (names.isNotEmpty) return names;
      } catch (e) {
        _missingModels.add(model);
        if (kDebugMode) debugPrint('searchPharmacyMasterNames $model: $e');
      }
    }
    return const [];
  }

  static Future<List<String>> searchPotencyNames(String sessionId) async {
    final rows = await loadPotencyMasterRows(sessionId);
    return rows
        .map((e) => (e['name'] ?? '').trim())
        .where((e) => e.isNotEmpty)
        .toList(growable: false);
  }

  static String? _cachedPotencyModel;
  static List<Map<String, String>>? _cachedPotencyRows;

  /// Full website potency master — always `pharmacy.potency` (Search: Potency).
  static Future<List<Map<String, String>>> loadPotencyMasterRows(
    String sessionId, {
    int pageSize = 100,
  }) async {
    if (_cachedPotencyRows != null && _cachedPotencyRows!.length >= 50) {
      return _cachedPotencyRows!;
    }

    const model = 'pharmacy.potency';
    _missingModels.remove(model);

    // 1) name_search — same API the website many2one uses (fast, complete).
    try {
      final ns = await callKw(
        sessionId: sessionId,
        model: model,
        method: 'name_search',
        args: ['', [], 'ilike', 500],
      );
      if (ns is List && ns.isNotEmpty) {
        final seen = <String>{};
        final rows = <Map<String, String>>[];
        for (final row in ns) {
          if (row is! List || row.length < 2) continue;
          final name = row[1]?.toString().trim() ?? '';
          if (name.isEmpty || name == 'false') continue;
          // Skip wizard-like garbage labels.
          if (name.contains('medicine.potency.search.wizard')) continue;
          if (!seen.add(name.toLowerCase())) continue;
          final entry = <String, String>{'name': name};
          final id = row[0];
          if (id != null) entry['id'] = id.toString();
          rows.add(entry);
        }
        if (rows.length >= 20) {
          _cachedPotencyModel = model;
          _cachedPotencyRows = rows;
          if (kDebugMode) {
            debugPrint('loadPotencyMasterRows name_search → ${rows.length}');
          }
          return rows;
        }
      }
    } catch (e) {
      if (kDebugMode) debugPrint('pharmacy.potency name_search: $e');
    }

    // 2) search_read fallback (paged) — stop early on network errors.
    try {
      final out = <Map<String, String>>[];
      final seen = <String>{};
      var offset = 0;
      while (offset < 1000) {
        final rows = await callKw(
          sessionId: sessionId,
          model: model,
          method: 'search_read',
          args: const [[]],
          kwargs: {
            'fields': ['id', 'name', 'display_name'],
            'limit': pageSize,
            'offset': offset,
            'order': 'name asc, id asc',
          },
        );
        if (rows is! List || rows.isEmpty) break;
        for (final row in rows.whereType<Map>()) {
          final map = _normalizeOdooMap(Map<String, dynamic>.from(row));
          final name =
              (map['display_name'] ?? map['name'] ?? '').toString().trim();
          if (name.isEmpty || name == 'false') continue;
          if (!seen.add(name.toLowerCase())) continue;
          final entry = <String, String>{'name': name};
          if (map['id'] != null) entry['id'] = map['id'].toString();
          out.add(entry);
        }
        if (rows.length < pageSize) break;
        offset += pageSize;
      }
      // Only cache a complete-ish page walk (avoid locking in ~100 of 222).
      if (out.length >= 150) {
        _cachedPotencyModel = model;
        _cachedPotencyRows = out;
      }
      if (out.isNotEmpty) {
        if (kDebugMode) {
          debugPrint('loadPotencyMasterRows search_read → ${out.length}');
        }
        return out;
      }
    } catch (e) {
      if (kDebugMode) debugPrint('pharmacy.potency search_read: $e');
    }

    // 3) Last resort: distinct potencies already on entry.stock (one page only).
    // Do NOT cache — allow a later retry of name_search to get the full list.
    final fromStock = await _loadPotenciesFromEntryStock(sessionId);
    if (fromStock.isNotEmpty) {
      if (kDebugMode) {
        debugPrint('potency fallback entry.stock count=${fromStock.length}');
      }
      return fromStock;
    }

    if (kDebugMode) debugPrint('loadPotencyMasterRows: empty');
    return const [];
  }

  /// Distinct potency labels (+ sample group/hsn) from pharmacy stock.
  static Future<List<Map<String, String>>> _loadPotenciesFromEntryStock(
    String sessionId,
  ) async {
    try {
      final available = await _modelFields(sessionId, 'entry.stock');
      if (available.isEmpty) return const [];

      final fields = <String>['id'];
      for (final f in const [
        'potency_id',
        'pharmacy_group_id',
        'hsn',
        'hsn_code',
        'pharmacy_company_id',
        'packing_id',
        'rack_id',
      ]) {
        if (available.contains(f)) fields.add(f);
      }
      if (!fields.contains('potency_id')) return const [];

      final byPotency = <String, Map<String, String>>{};
      // Single larger page — avoid hammering the server.
      final rows = await callKw(
        sessionId: sessionId,
        model: 'entry.stock',
        method: 'search_read',
        args: const [[]],
        kwargs: {
          'fields': fields,
          'limit': 400,
          'offset': 0,
          'order': 'id desc',
        },
      );
      if (rows is! List) return const [];

      for (final row in rows.whereType<Map>()) {
        final map = _normalizeOdooMap(Map<String, dynamic>.from(row));
        final name = (map['potency_id_name'] ?? '').toString().trim();
        if (name.isEmpty || name == 'false') continue;
        final key = name.toLowerCase();
        if (byPotency.containsKey(key)) continue;

        String? pick(List<String> keys) {
          for (final k in keys) {
            final v = map[k];
            if (v == null || v == false) continue;
            final t = v.toString().trim();
            if (t.isNotEmpty && t != 'false') return t;
          }
          return null;
        }

        final entry = <String, String>{'name': name};
        final id = map['potency_id'];
        if (id != null) entry['id'] = id.toString();
        final group = pick(const ['pharmacy_group_id_name']);
        final hsn = pick(const ['hsn', 'hsn_code']);
        final company = pick(const ['pharmacy_company_id_name']);
        final pack = pick(const ['packing_id_name']);
        final rack = pick(const ['rack_id_name', 'rack']);
        if (group != null) entry['group'] = group;
        if (hsn != null) entry['hsn'] = hsn;
        if (company != null) entry['company'] = company;
        if (pack != null) entry['pack'] = pack;
        if (rack != null) entry['rack'] = rack;
        byPotency[key] = entry;
      }

      final list = byPotency.values.toList()
        ..sort((a, b) => (a['name'] ?? '').compareTo(b['name'] ?? ''));
      return list;
    } catch (e) {
      if (kDebugMode) debugPrint('_loadPotenciesFromEntryStock: $e');
      return const [];
    }
  }

  static final Map<String, Map<String, String>> _potencyDefaultsCache = {};

  /// Website defaults when potency is chosen without a product (group / hsn / …).
  ///
  /// Priority matches Odoo website:
  /// 1) `pharmacy.group` ↔ `potency_line_ids` (Group + HSN) — NOT newest stock
  /// 2) `entry.stock` only for company / pack / rack (prefer rows in that group)
  static Future<Map<String, String>> readPotencyRelatedDefaults(
    String sessionId,
    String potencyName, {
    int? potencyId,
  }) async {
    final want = potencyName.trim();
    if (want.isEmpty) return const {};

    final cacheKey = want.toLowerCase();
    final cached = _potencyDefaultsCache[cacheKey];
    if (cached != null && cached.isNotEmpty) {
      return Map<String, String>.from(cached);
    }

    final model = _cachedPotencyModel ?? 'pharmacy.potency';

    // Resolve potency id from cache / master (for stock lookups).
    int? resolvedId = potencyId;
    if (resolvedId == null && _cachedPotencyRows != null) {
      for (final r in _cachedPotencyRows!) {
        if ((r['name'] ?? '').trim().toLowerCase() != cacheKey) continue;
        resolvedId = int.tryParse(r['id'] ?? '');
        break;
      }
    }
    if (resolvedId == null) {
      try {
        final ns = await callKw(
          sessionId: sessionId,
          model: model,
          method: 'name_search',
          args: [want, [], '=', 5],
        );
        if (ns is List) {
          for (final row in ns) {
            if (row is! List || row.length < 2) continue;
            final label = row[1]?.toString().trim() ?? '';
            if (label.toLowerCase() != want.toLowerCase()) continue;
            final id = row[0];
            resolvedId = id is int ? id : int.tryParse(id?.toString() ?? '');
            break;
          }
        }
      } catch (e) {
        if (kDebugMode) debugPrint('resolve potency id: $e');
      }
    }

    final defaults = <String, String>{};

    // 1) Website source of truth: pharmacy.group linked to this potency.
    final fromGroup = await _defaultsFromPharmacyGroupPotencyLink(
      sessionId,
      want,
      potencyId: resolvedId,
    );
    if (fromGroup.isNotEmpty) {
      defaults.addAll(fromGroup);
    }

    // 1b) Homeopathy decimal potencies (0/1, 0/16, …) default to DIL on website
    // when no explicit potency-line row exists yet.
    if ((defaults['group'] ?? '').isEmpty &&
        RegExp(r'^\d+\s*/\s*\d+$').hasMatch(want)) {
      try {
        final dil = await callKw(
          sessionId: sessionId,
          model: 'pharmacy.group',
          method: 'search_read',
          args: [
            [
              '|',
              ['name', '=', 'DIL'],
              ['name', 'ilike', 'DIL'],
            ],
          ],
          kwargs: {
            'fields': ['id', 'name', 'hsn'],
            'limit': 5,
            'order': 'name asc',
          },
        );
        if (dil is List) {
          for (final row in dil.whereType<Map>()) {
            final map = _normalizeOdooMap(Map<String, dynamic>.from(row));
            final name = (map['name'] ?? '').toString().trim();
            if (name.toUpperCase() != 'DIL') continue;
            defaults['group'] = name;
            final hsn = (map['hsn'] ?? '').toString().trim();
            if (hsn.isNotEmpty && hsn != 'false') defaults['hsn'] = hsn;
            if (kDebugMode) {
              debugPrint('potency decimal→DIL fallback "$want" → $defaults');
            }
            break;
          }
        }
      } catch (e) {
        if (kDebugMode) debugPrint('DIL fallback: $e');
      }
    }

    // 2) entry.stock: fill company/pack/rack; only fill group/hsn if link missing.
    // Prefer stock rows whose group matches the website group (e.g. DIL not LM).
    try {
      final available = await _modelFields(sessionId, 'entry.stock');
      if (available.isNotEmpty && available.contains('potency_id')) {
        final fields = <String>['id', 'potency_id'];
        for (final f in const [
          'pharmacy_group_id',
          'group_id',
          'group',
          'hsn',
          'hsn_code',
          'pharmacy_company_id',
          'company_id',
          'packing_id',
          'pack_id',
          'rack',
          'rack_id',
        ]) {
          if (available.contains(f)) fields.add(f);
        }

        // Match by id OR by potency name (duplicate potency ids exist).
        final List<dynamic> stockDomain;
        if (resolvedId != null) {
          stockDomain = [
            '|',
            ['potency_id', '=', resolvedId],
            ['potency_id.name', '=', want],
          ];
        } else {
          stockDomain = [
            ['potency_id.name', '=', want],
          ];
        }

        final wantGroup = (defaults['group'] ?? '').trim().toLowerCase();
        Map<String, String>? best;
        var bestScore = -1;
        final groupCounts = <String, int>{};
        final groupSamples = <String, Map<String, String>>{};

        final found = await callKw(
          sessionId: sessionId,
          model: 'entry.stock',
          method: 'search_read',
          args: [stockDomain],
          kwargs: {
            'fields': fields,
            'limit': 80,
            'order': 'id desc',
          },
        );

        if (found is List && found.isNotEmpty) {
          for (final row in found.whereType<Map>()) {
            final map = _normalizeOdooMap(Map<String, dynamic>.from(row));
            String? pick(List<String> keys) {
              for (final k in keys) {
                final v = map[k];
                if (v == null || v == false) continue;
                final t = v.toString().trim();
                if (t.isNotEmpty && t != 'false') return t;
              }
              return null;
            }

            final entry = <String, String>{};
            final group = pick(const [
              'pharmacy_group_id_name',
              'group_id_name',
              'group',
            ]);
            final hsn = pick(const ['hsn', 'hsn_code']);
            final company = pick(const [
              'pharmacy_company_id_name',
              'company_id_name',
            ]);
            final pack = pick(const ['packing_id_name', 'pack_id_name']);
            final rack = pick(const ['rack', 'rack_id_name']);
            if (group != null) entry['group'] = group;
            if (hsn != null) entry['hsn'] = hsn;
            if (company != null) entry['company'] = company;
            if (pack != null) entry['pack'] = pack;
            if (rack != null) entry['rack'] = rack;
            if (entry.isEmpty) continue;

            if (group != null) {
              final gk = group.toLowerCase();
              groupCounts[gk] = (groupCounts[gk] ?? 0) + 1;
              groupSamples.putIfAbsent(
                gk,
                () => Map<String, String>.from(entry),
              );
            }

            var score = 0;
            if (wantGroup.isNotEmpty &&
                (group ?? '').toLowerCase() == wantGroup) {
              score += 100;
            } else if (wantGroup.isNotEmpty) {
              score -= 50;
            }
            if ((entry['company'] ?? '').isNotEmpty) score += 2;
            if ((entry['pack'] ?? '').isNotEmpty) score += 2;
            if ((entry['rack'] ?? '').isNotEmpty) score += 1;
            if ((entry['hsn'] ?? '').isNotEmpty) score += 1;

            if (score > bestScore) {
              bestScore = score;
              best = entry;
            }
          }
        }

        // If website group unknown, use most common stock group (not newest).
        if (wantGroup.isEmpty && groupCounts.isNotEmpty) {
          var modeKey = '';
          var modeCount = -1;
          groupCounts.forEach((k, c) {
            if (c > modeCount) {
              modeCount = c;
              modeKey = k;
            }
          });
          // Prefer DIL-style over "LM potency" when counts are close.
          final preferred = _pickPreferredGroupDefaults([
            for (final e in groupSamples.entries)
              {'group': e.value['group'] ?? e.key, ...e.value},
          ]);
          if (preferred != null) {
            best = preferred;
          } else {
            best = groupSamples[modeKey];
          }
          if (kDebugMode) {
            debugPrint(
              'potency stock mode group="${best?['group']}" counts=$groupCounts',
            );
          }
        }

        if (best != null && best.isNotEmpty) {
          // When website group is known, only take stock extras from matching rows.
          final bestGroup = (best['group'] ?? '').trim().toLowerCase();
          final groupOk =
              wantGroup.isEmpty || bestGroup.isEmpty || bestGroup == wantGroup;

          if ((defaults['group'] ?? '').isEmpty &&
              (best['group'] ?? '').isNotEmpty) {
            defaults['group'] = best['group']!;
          }
          if ((defaults['hsn'] ?? '').isEmpty &&
              (best['hsn'] ?? '').isNotEmpty &&
              groupOk) {
            defaults['hsn'] = best['hsn']!;
          }
          if (groupOk) {
            for (final key in const ['company', 'pack', 'rack']) {
              if ((defaults[key] ?? '').isEmpty &&
                  (best[key] ?? '').isNotEmpty) {
                defaults[key] = best[key]!;
              }
            }
          }
        }
      }
    } catch (e) {
      if (kDebugMode) debugPrint('readPotencyRelatedDefaults stock: $e');
    }

    // Fill HSN from group master if still missing.
    if (defaults.isNotEmpty) {
      await _fillHsnFromPharmacyGroup(
        sessionId,
        defaults,
        potencyName: want,
        potencyId: resolvedId,
      );
    }

    if (defaults.isNotEmpty) {
      if (kDebugMode) {
        debugPrint('potency defaults "$want" id=$resolvedId → $defaults');
      }
      _potencyDefaultsCache[cacheKey] = Map<String, String>.from(defaults);
      return defaults;
    }

    if (kDebugMode) {
      debugPrint('No potency defaults for "$want" id=$resolvedId');
    }
    return const {};
  }

  /// Fill missing HSN from `pharmacy.group.hsn` (website stores HSN on group).
  static Future<void> _fillHsnFromPharmacyGroup(
    String sessionId,
    Map<String, String> defaults, {
    required String potencyName,
    int? potencyId,
  }) async {
    if ((defaults['hsn'] ?? '').trim().isNotEmpty) return;
    final groupName = (defaults['group'] ?? '').trim();
    if (groupName.isEmpty) return;
    try {
      final found = await callKw(
        sessionId: sessionId,
        model: 'pharmacy.group',
        method: 'search_read',
        args: [
          [
            '|',
            ['name', '=', groupName],
            ['display_name', '=', groupName],
          ],
        ],
        kwargs: {
          'fields': ['id', 'name', 'hsn'],
          'limit': 3,
        },
      );
      if (found is! List || found.isEmpty) return;
      for (final row in found.whereType<Map>()) {
        final map = _normalizeOdooMap(Map<String, dynamic>.from(row));
        final hsn = (map['hsn'] ?? '').toString().trim();
        if (hsn.isEmpty || hsn == 'false') continue;
        defaults['hsn'] = hsn;
        return;
      }
    } catch (e) {
      if (kDebugMode) debugPrint('_fillHsnFromPharmacyGroup: $e');
    }
  }

  static final Map<String, Map<String, Map<String, dynamic>>> _fieldsMetaCache =
      {};

  /// fields_get with type + relation (for one2many / many2one discovery).
  static Future<Map<String, Map<String, dynamic>>> _fieldsMeta(
    String sessionId,
    String model,
  ) async {
    final cached = _fieldsMetaCache[model];
    if (cached != null) return cached;
    try {
      final result = await callKw(
        sessionId: sessionId,
        model: model,
        method: 'fields_get',
        args: const [],
        kwargs: const {
          'attributes': ['type', 'string', 'relation'],
        },
      );
      if (result is Map) {
        final out = <String, Map<String, dynamic>>{};
        for (final e in result.entries) {
          final v = e.value;
          if (v is Map) {
            out[e.key.toString()] = Map<String, dynamic>.from(v);
          }
        }
        _fieldsMetaCache[model] = out;
        // Keep name set cache in sync.
        _fieldsCache[model] = out.keys.toSet();
        return out;
      }
    } catch (e) {
      if (kDebugMode) debugPrint('fields_meta $model: $e');
    }
    return const <String, Map<String, dynamic>>{};
  }

  /// Pick the best group row (prefer DIL-style medicine groups over "LM potency").
  static Map<String, String>? _pickPreferredGroupDefaults(
    List<Map<String, String>> candidates,
  ) {
    if (candidates.isEmpty) return null;
    Map<String, String>? preferred;
    for (final out in candidates) {
      final group = (out['group'] ?? '').trim();
      if (group.isEmpty) continue;
      final gLower = group.toLowerCase();
      final looksLikeMedicineGroup = gLower == 'dil' ||
          gLower.startsWith('dil') ||
          gLower.contains('biochem') ||
          gLower.contains('bio chem') ||
          gLower.contains('bio combination') ||
          gLower.contains('tablet') ||
          gLower.contains('mother') ||
          gLower.contains('cosmetic');
      final looksLikePersonOrMisc = gLower.contains('potency') ||
          gLower.contains('james') ||
          gLower.startsWith('lm ') ||
          gLower == 'lm';
      if (looksLikeMedicineGroup && !looksLikePersonOrMisc) {
        return out;
      }
      if (preferred == null &&
          group.length <= 16 &&
          !looksLikePersonOrMisc) {
        preferred = out;
      }
    }
    return preferred ?? candidates.first;
  }

  /// Group + HSN via pharmacy.group potency lines (website linkage).
  ///
  /// Does NOT use dotted domains like `potency_line_ids.potency_id.name`
  /// — those fail because `pharmacy.potency.line` has no `potency_id`.
  static Future<Map<String, String>> _defaultsFromPharmacyGroupPotencyLink(
    String sessionId,
    String potencyName, {
    int? potencyId,
  }) async {
    try {
      final groupMeta = await _fieldsMeta(sessionId, 'pharmacy.group');
      final lineModels = <String>{};
      for (final key in const [
        'potency_line_ids',
        'group_line_ids',
        'potency_ids',
      ]) {
        final rel = groupMeta[key]?['relation']?.toString().trim();
        if (rel != null && rel.isNotEmpty) lineModels.add(rel);
      }
      // Known Odoo pharmacy line model from server error messages.
      lineModels.add('pharmacy.potency.line');

      final candidates = <Map<String, String>>[];

      for (final lineModel in lineModels) {
        final lineMeta = await _fieldsMeta(sessionId, lineModel);
        if (lineMeta.isEmpty) continue;

        // Parent group field on the line.
        String? groupField;
        for (final e in lineMeta.entries) {
          if (e.value['type']?.toString() != 'many2one') continue;
          final rel = e.value['relation']?.toString() ?? '';
          if (rel == 'pharmacy.group' || e.key.contains('group')) {
            groupField = e.key;
            break;
          }
        }
        groupField ??= lineMeta.containsKey('group_id')
            ? 'group_id'
            : (lineMeta.containsKey('pharmacy_group_id')
                ? 'pharmacy_group_id'
                : null);

        // Potency reference on the line (many2one or char — NOT always potency_id).
        final potencyM2o = <String>[];
        final potencyChar = <String>[];
        for (final e in lineMeta.entries) {
          final type = e.value['type']?.toString() ?? '';
          final rel = e.value['relation']?.toString() ?? '';
          final key = e.key;
          final keyL = key.toLowerCase();
          if (type == 'many2one' &&
              (rel.contains('potency') || keyL.contains('potency'))) {
            potencyM2o.add(key);
          } else if ((type == 'char' || type == 'text') &&
              (keyL.contains('potency') ||
                  key == 'name' ||
                  key == 'display_name')) {
            potencyChar.add(key);
          }
        }
        // Prefer explicit potency fields over generic name.
        potencyChar.sort((a, b) {
          int rank(String k) {
            final l = k.toLowerCase();
            if (l.contains('potency')) return 0;
            if (l == 'name') return 1;
            return 2;
          }
          return rank(a).compareTo(rank(b));
        });

        if (kDebugMode) {
          debugPrint(
            'potency-line $lineModel groupField=$groupField '
            'm2o=$potencyM2o char=$potencyChar',
          );
        }

        final readFields = <String>{'id'};
        if (groupField != null) readFields.add(groupField);
        readFields.addAll(potencyM2o);
        readFields.addAll(potencyChar.take(3));
        if (lineMeta.containsKey('name')) readFields.add('name');
        if (lineMeta.containsKey('display_name')) {
          readFields.add('display_name');
        }

        final domains = <List<dynamic>>[];
        for (final f in potencyM2o) {
          if (potencyId != null) {
            domains.add([
              [f, '=', potencyId],
            ]);
          }
          domains.add([
            ['$f.name', '=', potencyName],
          ]);
        }
        for (final f in potencyChar) {
          domains.add([
            [f, '=', potencyName],
          ]);
          domains.add([
            [f, 'ilike', potencyName],
          ]);
        }
        // Last resort: name / display_name on the line.
        if (lineMeta.containsKey('name') &&
            !potencyChar.contains('name')) {
          domains.add([
            ['name', '=', potencyName],
          ]);
        }

        for (final domain in domains) {
          List? found;
          try {
            found = await callKw(
              sessionId: sessionId,
              model: lineModel,
              method: 'search_read',
              args: [domain],
              kwargs: {
                'fields': readFields.toList(),
                'limit': 40,
              },
            ) as List?;
          } catch (e) {
            if (kDebugMode) {
              debugPrint('potency-line search $lineModel $domain: $e');
            }
            continue;
          }
          if (found == null || found.isEmpty) continue;

          for (final row in found.whereType<Map>()) {
            final map = _normalizeOdooMap(Map<String, dynamic>.from(row));
            String? groupName;
            if (groupField != null) {
              groupName = (map['${groupField}_name'] ?? map[groupField])
                  ?.toString()
                  .trim();
            }
            // Some lines store only group id — resolve name/hsn next.
            int? groupId;
            if (groupField != null) {
              final raw = map[groupField];
              if (raw is int) {
                groupId = raw;
              } else {
                groupId = int.tryParse(raw?.toString() ?? '');
              }
            }

            if ((groupName == null ||
                    groupName.isEmpty ||
                    groupName == 'false') &&
                groupId != null) {
              try {
                final gRows = await callKw(
                  sessionId: sessionId,
                  model: 'pharmacy.group',
                  method: 'read',
                  args: [
                    [groupId],
                    ['id', 'name', 'display_name', 'hsn', 'type'],
                  ],
                );
                if (gRows is List && gRows.isNotEmpty) {
                  final g = _normalizeOdooMap(
                    Map<String, dynamic>.from(gRows.first as Map),
                  );
                  groupName =
                      (g['name'] ?? g['display_name'] ?? '').toString().trim();
                  final hsn = (g['hsn'] ?? '').toString().trim();
                  if (groupName.isNotEmpty && groupName != 'false') {
                    final out = <String, String>{'group': groupName};
                    if (hsn.isNotEmpty && hsn != 'false') out['hsn'] = hsn;
                    candidates.add(out);
                  }
                  continue;
                }
              } catch (_) {}
            }

            if (groupName == null ||
                groupName.isEmpty ||
                groupName == 'false') {
              continue;
            }
            final out = <String, String>{'group': groupName};
            // HSN may live on the group, not the line — filled later.
            candidates.add(out);
          }

          if (candidates.isNotEmpty) break;
        }
        if (candidates.isNotEmpty) break;
      }

      // Enrich HSN from pharmacy.group for each candidate, then pick preferred.
      final enriched = <Map<String, String>>[];
      for (final c in candidates) {
        final copy = Map<String, String>.from(c);
        await _fillHsnFromPharmacyGroup(
          sessionId,
          copy,
          potencyName: potencyName,
          potencyId: potencyId,
        );
        enriched.add(copy);
      }

      final chosen = _pickPreferredGroupDefaults(enriched);
      if (chosen != null) {
        if (kDebugMode) {
          debugPrint('potency group-link "$potencyName" → $chosen');
        }
        return chosen;
      }
    } catch (e) {
      if (kDebugMode) {
        debugPrint('_defaultsFromPharmacyGroupPotencyLink: $e');
      }
    }
    return const {};
  }

  static Future<List<String>> searchGroupNames(String sessionId) {
    return searchPharmacyMasterNames(
      sessionId,
      models: const [
        'pharmacy.group',
        'pharmacy.medicine.group',
        'product.group',
      ],
    );
  }

  static Future<List<String>> searchCompanyNames(String sessionId) {
    return searchPharmacyMasterNames(
      sessionId,
      models: const [
        'pharmacy.company',
        'pharmacy.medicine.company',
      ],
    );
  }

  static Future<List<String>> searchPackingNames(String sessionId) {
    return searchPharmacyMasterNames(
      sessionId,
      models: const [
        'pharmacy.packing',
        'pharmacy.pack',
        'product.packing',
      ],
    );
  }

  /// Website Discount Category (`cus.discount` → account.move.discount_category_id).
  static Future<List<Map<String, dynamic>>> searchCustomerDiscounts(
    String sessionId, {
    int limit = 100,
  }) async {
    try {
      final rows = await callKw(
        sessionId: sessionId,
        model: 'cus.discount',
        method: 'search_read',
        args: const [[]],
        kwargs: {
          'fields': [
            'id',
            'cus_dis',
            'display_name',
            'discount_type',
            'percentage',
          ],
          'limit': limit,
          'order': 'id asc',
        },
      );
      if (rows is! List) return const [];
      return rows
          .whereType<Map>()
          .map((e) => _normalizeOdooMap(Map<String, dynamic>.from(e)))
          .toList(growable: false);
    } catch (e) {
      if (kDebugMode) debugPrint('searchCustomerDiscounts: $e');
      return const [];
    }
  }

  static final Map<String, Set<String>> _fieldsCache = {};
  static final Set<String> _missingModels = {};

  /// Load pharmacy customer invoice header + product lines from Odoo.
  /// Website bills are `account.move`.
  static Future<InvoiceSummaryModel?> readPharmacyInvoice(
    String sessionId,
    int invoiceId,
  ) async {
    return _readInvoiceModel(
      sessionId: sessionId,
      model: 'account.move',
      lineModel: 'account.move.line',
      invoiceId: invoiceId,
    );
  }

  static Future<InvoiceSummaryModel?> _readInvoiceModel({
    required String sessionId,
    required String model,
    required String lineModel,
    required int invoiceId,
  }) async {
    try {
      final available = await _modelFields(sessionId, model);
      if (available.isEmpty) return null;

      final headerFields = _intersect(available, const [
        'name',
        'display_name',
        'invoice_number',
        'invoice_no',
        'ref',
        'payment_reference',
        'invoice_date',
        'date',
        'date_invoice',
        'invoice_partner_display_name',
        'customer_name',
        'partner_id',
        'pharmacy_customer_id',
        'address',
        'manual_address',
        'street',
        'phone',
        'phone_no',
        'mobile',
        'pharmacy_supplier_phone',
        'responsible_person',
        'responsible_person_id',
        'doctor',
        'doctor_name',
        'payment_mode',
        'gst_type',
        'expiry_medicine_bill',
        'discount_category',
        'discount_category_id',
        'discount_type',
        'discount_rate',
        'billed_by',
        'billed_by_name',
        'verify_status',
        'verified_by',
        'create_uid',
        'subtotal',
        'amount_untaxed',
        'discount_total',
        'tax_amount',
        'amount_tax',
        'expense',
        'expense_amt',
        'total',
        'amount_total',
        'balance',
        'amount_residual',
        'remarks',
        'narration',
        'state',
        'payment_state',
        'invoice_line_ids',
        'line_ids',
        // You Gave / supplier bill header (website).
        'supplier_invoice_no',
        'pharmacy_purchase_order_id',
        'supplier_invoice_amount',
        'select_previous_invoice_id',
        'delivery_date',
        'pharmacy_supplier_id',
      ]).toList();
      if (headerFields.isEmpty) return null;

      // Force relation ids even if fields_get omitted them.
      for (final key in const ['invoice_line_ids', 'line_ids', 'display_name']) {
        if (!headerFields.contains(key)) {
          headerFields.add(key);
        }
      }

      final rows = await callKw(
        sessionId: sessionId,
        model: model,
        method: 'read',
        args: [
          [invoiceId],
          headerFields,
        ],
      );
      if (rows is! List || rows.isEmpty || rows.first is! Map) return null;

      final header = _normalizeOdooMap(
        Map<String, dynamic>.from(rows.first as Map),
      );

      // Pharmacy lines use display_type="product" with product_id=false.
      var lines = await _searchProductLines(
        sessionId: sessionId,
        lineModel: lineModel,
        moveId: invoiceId,
      );

      if (lines.isEmpty) {
        final lineIds = _odooIds(
          header['invoice_line_ids'] ?? header['line_ids'],
        );
        if (kDebugMode) {
          debugPrint(
            'readPharmacyInvoice #$invoiceId '
            'invoice_line_ids=${_odooIds(header['invoice_line_ids']).length} '
            'line_ids=${_odooIds(header['line_ids']).length}',
          );
        }
        if (lineIds.isNotEmpty) {
          lines = await _readInvoiceLines(
            sessionId: sessionId,
            lineModel: lineModel,
            lineIds: lineIds,
          );
        }
      }

      if (kDebugMode) {
        debugPrint(
          'readPharmacyInvoice #$invoiceId lines=${lines.length} '
          'subtotal=${header['amount_untaxed'] ?? header['subtotal']} '
          'billNo=${_pharmacyInvoiceNumber(header)}',
        );
      }

      final billNo = _pharmacyInvoiceNumber(header);
      final partnerLabel = (header['partner_id_name'] ??
              header['invoice_partner_display_name'] ??
              '')
          .toString()
          .trim();
      final pharmacyCustomerLabel = (header['pharmacy_customer_id_name'] ??
              header['customer_name'] ??
              '')
          .toString()
          .trim();
      // Prefer pharmacy customer; ignore Odoo "#Created by: Administrator".
      final resolvedCustomer = () {
        if (pharmacyCustomerLabel.isNotEmpty &&
            !InvoiceSummaryModel.isPlaceholderCustomerName(
              pharmacyCustomerLabel,
            )) {
          return pharmacyCustomerLabel;
        }
        if (partnerLabel.isNotEmpty &&
            !InvoiceSummaryModel.isPlaceholderCustomerName(partnerLabel)) {
          return partnerLabel;
        }
        return null;
      }();

      final parsed = InvoiceSummaryModel.fromJson({
        'id': invoiceId,
        'invoice_id': invoiceId,
        ...header,
        if (billNo != null) 'invoice_number': billNo,
        // Force blank when Odoo only has Created-by placeholder.
        'customer_name': resolvedCustomer ?? '',
        'customer': resolvedCustomer ?? '',
        'invoice_partner_display_name': resolvedCustomer ?? '',
        'partner_id_name': resolvedCustomer ?? '',
        if (header['pharmacy_supplier_id_name'] != null)
          'partner_name': header['pharmacy_supplier_id_name'],
        if (header['manual_address'] != null &&
            (header['address'] == null || header['address'] == false))
          'address': header['manual_address'],
        if (header['pharmacy_supplier_phone'] != null &&
            (header['phone'] == null || header['phone'] == false))
          'phone': header['pharmacy_supplier_phone'],
        if (header['responsible_person_id_name'] != null &&
            header['responsible_person'] == null)
          'responsible_person': header['responsible_person_id_name'],
        if (header['pharmacy_purchase_order_id_name'] != null)
          'po_number': header['pharmacy_purchase_order_id_name'],
        if (header['select_previous_invoice_id_name'] != null)
          'previous_invoice': header['select_previous_invoice_id_name'],
        if (header['create_uid_name'] != null && header['billed_by'] == null)
          'billed_by_name': header['create_uid_name'],
        if (header['narration'] != null && header['remarks'] == null)
          'remarks': header['narration'],
        if (lines.isNotEmpty)
          'invoice_lines': lines
              .map(
                (l) => {
                  'product_name': l.productName,
                  'potency': l.potency,
                  'company': l.company,
                  'batch': l.batch,
                  'manufacturer': l.manufacturer,
                  'mfd': l.mfd,
                  'expiry': l.expiry,
                  'packing': l.packing,
                  'group': l.group,
                  'qty': l.qty,
                  'ordered_qty': l.orderedQty,
                  'free_qty': l.freeQty,
                  'mrp': l.mrp,
                  'discount': l.discount,
                  'dis2_percent': l.dis2Percent,
                  'unit': l.unit,
                  'unit_p': l.unitPrice,
                  'u_price': l.uPrice,
                  'tax': l.tax,
                  'tax_amount': l.taxAmount,
                  'total': l.total,
                  'hsn': l.hsn,
                  'rack': l.rack,
                },
              )
              .toList(),
      });

      if (parsed.lines.isNotEmpty ||
          parsed.subtotal != null ||
          parsed.total != null) {
        return parsed;
      }
    } catch (e) {
      if (kDebugMode) debugPrint('readPharmacyInvoice $model: $e');
    }
    return null;
  }

  /// Website bill no. like `0514/2026-27` (not Odoo `INV/2026/00161`).
  static String? _pharmacyInvoiceNumber(Map<String, dynamic> header) {
    for (final key in const [
      'invoice_number',
      'invoice_no',
      'pharmacy_invoice_number',
      'bill_number',
      'bill_no',
    ]) {
      final value = header[key]?.toString().trim();
      if (value == null ||
          value.isEmpty ||
          value == 'false' ||
          value.startsWith('INV/')) {
        continue;
      }
      final match = RegExp(r'(\d{3,5}/\d{4}-\d{2})').firstMatch(value);
      if (match != null) return match.group(1);
      return value;
    }

    final display = header['display_name']?.toString() ?? '';
    final fromDisplay =
        RegExp(r'(\d{3,5}/\d{4}-\d{2})').firstMatch(display);
    if (fromDisplay != null) return fromDisplay.group(1);

    final name = header['name']?.toString().trim();
    if (name != null &&
        name.isNotEmpty &&
        name != '/' &&
        name != 'false') {
      return name;
    }
    return null;
  }

  /// Load product rows for an invoice via search_read (website-equivalent).
  static Future<List<InvoiceLineModel>> _searchProductLines({
    required String sessionId,
    required String lineModel,
    required int moveId,
  }) async {
    try {
      final available = await _modelFields(sessionId, lineModel);
      if (available.isEmpty) return const [];

      final lineFields = _pharmacyLineFields(available);
      // Always request supplier qty columns when present (You Gave website).
      for (final key in const [
        'ordered_qty',
        'free_qty',
        'quantity',
        'dis2_percent',
        'u_price',
      ]) {
        if (available.contains(key) && !lineFields.contains(key)) {
          lineFields.add(key);
        }
      }
      // Ensure qty columns are requested even if fields_get used a short fallback.
      for (final key in const ['ordered_qty', 'free_qty', 'quantity']) {
        if (!lineFields.contains(key)) lineFields.add(key);
      }
      if (lineFields.isEmpty) return const [];

      if (kDebugMode) {
        debugPrint(
          'pharmacy line fields include ordered=${lineFields.contains('ordered_qty')} '
          'free=${lineFields.contains('free_qty')} qty=${lineFields.contains('quantity')}',
        );
      }

      // Pharmacy lines: display_type="product", product_id often false.
      final domains = <List<dynamic>>[
        [
          ['move_id', '=', moveId],
          ['display_type', '=', 'product'],
        ],
        [
          ['move_id', '=', moveId],
        ],
      ];

      List<dynamic>? lineRows;
      for (final domain in domains) {
        try {
          final result = await callKw(
            sessionId: sessionId,
            model: lineModel,
            method: 'search_read',
            args: [domain],
            kwargs: {
              'fields': lineFields,
              'limit': 500,
            },
          );
          if (result is List && result.isNotEmpty) {
            lineRows = result;
            break;
          }
        } catch (e) {
          if (kDebugMode) {
            debugPrint('search_read $lineModel domain failed: $e');
          }
        }
      }

      if (lineRows == null || lineRows.isEmpty) return const [];
      return _parseLineRows(sessionId, lineRows);
    } catch (e) {
      if (kDebugMode) debugPrint('searchProductLines $lineModel: $e');
      return const [];
    }
  }

  static List<String> _pharmacyLineFields(Set<String> available) {
    final preferred = <String>[
      'display_type',
      'product_id',
      'product_name',
      'name',
      'medicine_id',
      // Website pharmacy columns (exact Odoo field names).
      'potency_id',
      'pack_id',
      'pharmacy_company_id',
      'pharmacy_group_id',
      'rack_id',
      'batch_no',
      'mfd_date',
      'stock_entry_id',
      'potency',
      'power',
      'drug_potency',
      'company',
      'comp',
      'medicine_company',
      'brand',
      'batch',
      'batch_id',
      'lot_id',
      'manufacturer',
      'manuf',
      'manf',
      'expiry',
      'expiry_date',
      'exp_date',
      'expiration_date',
      'packing',
      'pack',
      'pack_size',
      'group',
      'medicine_group',
      'product_group',
      'qty',
      'quantity',
      'ordered_qty',
      'free_qty',
      'dis2_percent',
      'u_price',
      'product_uom_id',
      'product_uom',
      'mrp',
      'discount',
      'dis',
      'price_unit',
      'unit_price',
      'unit_p',
      'tax_ids',
      'tax',
      'tax_percent',
      'tax_amount',
      'amount_tax',
      'price_subtotal',
      'price_total',
      'total',
      'amount_total',
      'hsn',
      'hsn_code',
      'rack',
      'rack_no',
      'move_id',
    ];

    final selected = _intersect(available, preferred).toList(growable: true);
    for (final name in available) {
      final lower = name.toLowerCase();
      if (lower.contains('compute_all_tax') || lower.contains('binary')) {
        continue;
      }
      final interesting = lower.contains('poten') ||
          lower.contains('batch') ||
          lower.contains('pack') ||
          lower.contains('group') ||
          lower.contains('rack') ||
          lower.contains('manuf') ||
          lower.contains('mfd') ||
          lower.contains('expir') ||
          lower.contains('medicine') ||
          lower == 'company' ||
          lower == 'comp' ||
          lower == 'mrp' ||
          lower == 'unit_p' ||
          lower == 'u_price' ||
          lower == 'ordered_qty' ||
          lower == 'free_qty' ||
          lower == 'dis2_percent' ||
          lower == 'tax' ||
          lower.contains('hsn') ||
          lower.contains('pharmacy_');
      if (interesting && !selected.contains(name)) {
        selected.add(name);
      }
    }
    return selected;
  }

  static Future<List<InvoiceLineModel>> _readInvoiceLines({
    required String sessionId,
    required String lineModel,
    required List<int> lineIds,
  }) async {
    try {
      final available = await _modelFields(sessionId, lineModel);
      if (available.isEmpty) return const [];

      final lineFields = _pharmacyLineFields(available);
      for (final key in const [
        'ordered_qty',
        'free_qty',
        'quantity',
        'dis2_percent',
        'u_price',
      ]) {
        if (available.contains(key) && !lineFields.contains(key)) {
          lineFields.add(key);
        }
      }
      // Pharmacy servers always expose these on product lines — request even
      // when fields_get fell back to a short list (stale cache without them).
      for (final key in const ['ordered_qty', 'free_qty', 'quantity']) {
        if (!lineFields.contains(key)) lineFields.add(key);
      }
      if (lineFields.isEmpty) return const [];

      final lineRows = await callKw(
        sessionId: sessionId,
        model: lineModel,
        method: 'read',
        args: [lineIds, lineFields],
      );
      if (lineRows is! List) return const [];
      return _parseLineRows(sessionId, lineRows);
    } catch (e) {
      if (kDebugMode) debugPrint('readInvoiceLines $lineModel: $e');
      return const [];
    }
  }

  static Future<List<InvoiceLineModel>> _parseLineRows(
    String sessionId,
    List<dynamic> lineRows,
  ) async {
    final taxRates = await _taxRatesForLines(sessionId, lineRows);
    final lines = <InvoiceLineModel>[];

    for (final row in lineRows) {
      if (row is! Map) continue;
      final map = _normalizeOdooMap(Map<String, dynamic>.from(row));

      final displayType = (map['display_type'] ?? '').toString().trim();
      if (displayType.isNotEmpty &&
          displayType != 'false' &&
          displayType != 'product') {
        continue;
      }

      // Supplier (You Gave) lines often have name=false; product is medicine_id.
      if (map['medicine_id_name'] != null) {
        map['product_name'] = map['medicine_id_name'];
      } else if (map['product_id_name'] != null) {
        map['product_name'] = map['product_id_name'];
      }

      final hasProduct = map['product_id'] != null ||
          map['product_id_name'] != null ||
          map['medicine_id'] != null ||
          map['medicine_id_name'] != null ||
          (map['product_name']?.toString().trim().isNotEmpty ?? false);
      final label = (map['name'] == null || map['name'] == false)
          ? ''
          : map['name'].toString().trim();
      if (!hasProduct && label.isEmpty) continue;

      // Skip pure tax / receivable accounting rows without qty/price.
      final qty = map['quantity'] ?? map['qty'];
      final price = map['price_unit'] ?? map['unit_price'] ?? map['unit_p'];
      if (!hasProduct &&
          (qty == null || qty == 0 || qty == 0.0) &&
          (price == null || price == 0 || price == 0.0)) {
        continue;
      }

      // Prefer medicine name when the accounting name is blank.
      if ((map['product_name'] == null ||
              map['product_name'].toString().trim().isEmpty) &&
          label.isNotEmpty) {
        map['product_name'] = label;
      }

      // Website pharmacy many2one labels → canonical keys.
      _aliasField(map, 'potency', const [
        'potency_id_name',
        'potency_name',
        'power',
        'drug_potency',
      ]);
      _aliasField(map, 'company', const [
        'pharmacy_company_id_name',
        'comp',
        'medicine_company',
        'brand',
        'company_name',
      ]);
      _aliasField(map, 'batch', const [
        'batch_no',
        'batch_id',
        'lot_id_name',
      ]);
      _aliasField(map, 'packing', const [
        'pack_id_name',
        'pack',
        'pack_size',
      ]);
      _aliasField(map, 'group', const [
        'pharmacy_group_id_name',
        'medicine_group',
        'product_group',
        'group_id_name',
      ]);
      _aliasField(map, 'rack', const [
        'rack_id_name',
        'rack_no',
      ]);
      _aliasField(map, 'mfd', const [
        'mfd_date',
        'manufacturing_date',
        'manuf',
        'manf',
        'manufacturer',
      ]);
      _aliasField(
        map,
        'expiry',
        const ['expiry_date', 'exp_date', 'expiration_date'],
      );
      if ((map['hsn'] == null || map['hsn'] == false) &&
          map['hsn_code'] != null) {
        map['hsn'] = map['hsn_code'];
      }
      if (map['product_uom_id_name'] != null && map['unit'] == null) {
        map['unit'] = map['product_uom_id_name'];
      }

      // Preserve supplier qty columns for You Gave (do not drop 0.0).
      if (map['ordered_qty'] == null && map['ordered_quantity'] != null) {
        map['ordered_qty'] = map['ordered_quantity'];
      }
      if (map['free_qty'] == null && map['free_quantity'] != null) {
        map['free_qty'] = map['free_quantity'];
      }

      final taxIds = _odooIds(map['tax_ids']);
      if (taxIds.isNotEmpty &&
          map['tax'] == null &&
          map['tax_percent'] == null) {
        double? rate;
        for (final id in taxIds) {
          final r = taxRates[id];
          if (r != null) rate = (rate ?? 0) + r;
        }
        if (rate != null) map['tax_percent'] = rate;
      }

      if (map['tax_amount'] == null &&
          map['amount_tax'] == null &&
          map['price_subtotal'] is num &&
          map['price_total'] is num) {
        final sub = (map['price_subtotal'] as num).toDouble();
        final tot = (map['price_total'] as num).toDouble();
        map['tax_amount'] = tot - sub;
      }

      final parsed = InvoiceLineModel.fromJson(map);
      if (parsed.productName == null || parsed.productName!.trim().isEmpty) {
        continue;
      }
      lines.add(parsed);
    }
    return lines;
  }

  static void _aliasField(
    Map<String, dynamic> map,
    String target,
    List<String> aliases,
  ) {
    final current = map[target];
    if (current != null &&
        current != false &&
        current.toString().trim().isNotEmpty) {
      return;
    }
    for (final key in aliases) {
      final value = map[key];
      if (value != null &&
          value != false &&
          value.toString().trim().isNotEmpty) {
        map[target] = value;
        return;
      }
    }
  }

  static Future<Map<int, double>> _taxRatesForLines(
    String sessionId,
    List<dynamic> lineRows,
  ) async {
    final ids = <int>{};
    for (final row in lineRows) {
      if (row is Map) ids.addAll(_odooIds(row['tax_ids']));
    }
    if (ids.isEmpty) return const {};

    try {
      final taxRows = await callKw(
        sessionId: sessionId,
        model: 'account.tax',
        method: 'read',
        args: [
          ids.toList(),
          ['amount'],
        ],
      );
      if (taxRows is! List) return const {};
      final map = <int, double>{};
      for (final row in taxRows) {
        if (row is! Map) continue;
        final id = row['id'];
        final amount = row['amount'];
        if (id is num && amount is num) {
          map[id.toInt()] = amount.toDouble();
        }
      }
      return map;
    } catch (_) {
      return const {};
    }
  }

  static Future<Set<String>> _modelFields(
    String sessionId,
    String model,
  ) async {
    if (_missingModels.contains(model)) return const {};
    final cached = _fieldsCache[model];
    if (cached != null) return cached;

    try {
      final result = await callKw(
        sessionId: sessionId,
        model: model,
        method: 'fields_get',
        args: const [],
        kwargs: const {
          'attributes': ['type', 'string'],
        },
      );
      if (result is Map) {
        final keys = result.keys.map((e) => e.toString()).toSet();
        _fieldsCache[model] = keys;
        return keys;
      }
    } catch (e) {
      if (kDebugMode) debugPrint('fields_get $model: $e');
      final msg = e.toString().toLowerCase();
      if (msg.contains('keyerror') || msg.contains('does not exist')) {
        _missingModels.add(model);
        return const {};
      }
    }

    // Fallback: known-safe defaults per model so read can still proceed.
    final fallback = model == 'account.move'
        ? {
            'name',
            'display_name',
            'partner_id',
            'invoice_partner_display_name',
            'invoice_date',
            'date',
            'amount_untaxed',
            'amount_tax',
            'amount_total',
            'amount_residual',
            'state',
            'payment_state',
            'narration',
            'ref',
            'invoice_line_ids',
            'line_ids',
            'create_uid',
          }
        : model == 'account.move.line'
            ? {
                'display_type',
                'product_id',
                'medicine_id',
                'name',
                'quantity',
                'price_unit',
                'discount',
                'tax_ids',
                'tax',
                'price_subtotal',
                'price_total',
                'product_uom_id',
                'move_id',
                'mrp',
                'unit_p',
                'hsn_code',
                'batch_no',
                'mfd_date',
                'potency_id',
                'pack_id',
                'pharmacy_company_id',
                'pharmacy_group_id',
                'rack_id',
                'stock_entry_id',
                'ordered_qty',
                'free_qty',
                'dis2_percent',
                'u_price',
              }
            : <String>{};
    if (fallback.isNotEmpty) {
      _fieldsCache[model] = fallback;
    }
    return fallback;
  }

  static List<String> _intersect(Set<String> available, List<String> wanted) {
    return wanted.where(available.contains).toList(growable: false);
  }

  /// Flatten Odoo many2one `[id, name]` into `key` id + `key_name`.
  static Map<String, dynamic> _normalizeOdooMap(Map<String, dynamic> raw) {
    final out = Map<String, dynamic>.from(raw);
    for (final entry in raw.entries) {
      final value = entry.value;
      if (value is List && value.length >= 2) {
        final id = value[0];
        final name = value[1]?.toString().trim();
        if (id is num) out[entry.key] = id.toInt();
        if (name != null && name.isNotEmpty && name != 'false') {
          out['${entry.key}_name'] = name;
        }
      } else if (value == false) {
        out[entry.key] = null;
      }
    }
    return out;
  }

  static List<int> _odooIds(dynamic value) {
    if (value is! List) return const [];
    return value
        .whereType<num>()
        .map((e) => e.toInt())
        .where((id) => id > 0)
        .toList();
  }

  /// Last timer model that returned rows (for faster subsequent loads).
  static String? lastTimerModelUsed;

  /// Cash/Credit Timer Logs that are currently Running / In Progress.
  static Future<List<Map<String, dynamic>>> searchActiveTimerLogs(
    String sessionId, {
    String? preferredModel,
  }) async {
    lastTimerModelUsed = null;
    final modelCandidates = <String>[
      if (preferredModel != null && preferredModel.trim().isNotEmpty)
        preferredModel.trim(),
      'pharmacy.cash.credit.timer',
      'pharmacy.timer.log',
      'cash.credit.timer.log',
      'pharmacy.billing.timer',
      'employee.performance.timer',
      'pharmacy.invoice.timer',
    ];

    // Only discover models when we don't already know a working one.
    if (preferredModel == null || preferredModel.trim().isEmpty) {
      try {
        final found = await callKw(
          sessionId: sessionId,
          model: 'ir.model',
          method: 'search_read',
          args: [
            [
              '|',
              '|',
              ['model', 'ilike', 'timer'],
              ['name', 'ilike', 'timer'],
              ['name', 'ilike', 'Cash/Credit'],
            ],
          ],
          kwargs: {
            'fields': ['model', 'name'],
            'limit': 15,
          },
        );
        if (found is List) {
          for (final row in found) {
            if (row is! Map) continue;
            final m = row['model']?.toString().trim();
            if (m != null && m.isNotEmpty && !modelCandidates.contains(m)) {
              modelCandidates.add(m);
            }
          }
        }
      } catch (e) {
        if (kDebugMode) debugPrint('timer model discovery: $e');
      }
    }

    // Deduplicate while keeping order.
    final seen = <String>{};
    final models = <String>[];
    for (final m in modelCandidates) {
      if (seen.add(m)) models.add(m);
    }

    for (final model in models) {
      try {
        final fields = await _modelFields(sessionId, model);
        if (fields.isEmpty) continue;

        // Lean field set for faster search_read.
        const preferred = {
          'name',
          'display_name',
          'create_uid',
          'invoice_id',
          'invoice_no',
          'move_id',
          'worked_by',
          'worked_by_id',
          'started_by',
          'started_by_id',
          'user_id',
          'employee_id',
          'billing',
          'billing_type',
          'billing_stage',
          'status',
          'state',
          'start',
          'start_time',
          'date_start',
          'end',
          'end_time',
          'date_end',
          'break_time',
          'break_duration',
          'work_duration',
          'session_work_duration',
          'duration',
          'completed_by',
        };
        final useFields = preferred.where(fields.contains).toList();
        if (useFields.isEmpty) {
          useFields.addAll(
            fields.where((f) {
              final n = f.toLowerCase();
              return n.contains('invoice') ||
                  n.contains('start') ||
                  n.contains('status') ||
                  n.contains('state') ||
                  n.contains('bill') ||
                  n.contains('work') ||
                  n.contains('duration') ||
                  n == 'name' ||
                  n == 'create_uid';
            }).take(25),
          );
          if (useFields.isEmpty) continue;
        }

        List<dynamic> domain;
        if (fields.contains('status')) {
          domain = [
            '|',
            '|',
            ['status', 'ilike', 'running'],
            ['status', 'ilike', 'progress'],
            ['status', '=', 'in_progress'],
          ];
        } else if (fields.contains('state')) {
          domain = [
            '|',
            '|',
            ['state', 'ilike', 'running'],
            ['state', 'ilike', 'progress'],
            ['state', '=', 'in_progress'],
          ];
        } else if (fields.contains('end') || fields.contains('end_time')) {
          final endField = fields.contains('end') ? 'end' : 'end_time';
          domain = [
            '|',
            [endField, '=', false],
            [endField, '=', null],
          ];
        } else {
          continue;
        }

        final rows = await callKw(
          sessionId: sessionId,
          model: model,
          method: 'search_read',
          args: [domain],
          kwargs: {
            'fields': useFields,
            'limit': 10,
            'order': fields.contains('start')
                ? 'start desc'
                : (fields.contains('start_time')
                    ? 'start_time desc'
                    : 'id desc'),
          },
        );
        if (rows is! List) continue;

        final normalized = rows
            .whereType<Map>()
            .map((e) => _normalizeOdooMap(Map<String, dynamic>.from(e)))
            .where(_looksLikeRunningTimer)
            .toList(growable: false);
        lastTimerModelUsed = model;
        return normalized;
      } catch (e) {
        if (kDebugMode) debugPrint('timer logs $model: $e');
      }
    }
    return const [];
  }

  static bool _looksLikeRunningTimer(Map<String, dynamic> row) {
    final status = (row['status'] ?? row['state'] ?? '')
        .toString()
        .toLowerCase()
        .trim();
    if (status.contains('run') || status.contains('progress')) return true;
    final end = row['end'] ?? row['end_time'] ?? row['date_end'];
    if (end == null || end == false) return true;
    final endText = end.toString().trim();
    return endText.isEmpty || endText == 'false';
  }

  /// Find customer invoice (`account.move`) id by display bill number.
  /// Draft pharmacy bills often have `name='/'` and bill no. in `display_name`.
  static Future<int?> findCustomerInvoiceId(
    String sessionId,
    String invoiceNumber,
  ) async {
    final name = invoiceNumber.trim();
    if (name.isEmpty) return null;

    final domains = <List<dynamic>>[
      [
        ['display_name', 'ilike', name],
        ['move_type', '=', 'out_invoice'],
      ],
      [
        ['display_name', 'ilike', name],
      ],
      [
        ['name', '=', name],
        ['move_type', '=', 'out_invoice'],
      ],
      [
        ['name', '=', name],
      ],
      [
        ['payment_reference', '=', name],
      ],
      [
        ['ref', '=', name],
      ],
    ];

    for (final domain in domains) {
      try {
        final rows = await callKw(
          sessionId: sessionId,
          model: 'account.move',
          method: 'search_read',
          args: [domain],
          kwargs: {
            'fields': ['id', 'name', 'display_name'],
            'limit': 5,
            'order': 'id desc',
          },
        );
        if (rows is! List || rows.isEmpty) continue;
        for (final raw in rows) {
          if (raw is! Map) continue;
          final map = _normalizeOdooMap(Map<String, dynamic>.from(raw));
          final bill = _pharmacyInvoiceNumber(map) ??
              (map['display_name']?.toString() ?? '');
          if (!bill.contains(name) && map['name']?.toString() != name) {
            continue;
          }
          final id = map['id'];
          if (id is int) return id;
          final parsed = int.tryParse(id?.toString() ?? '');
          if (parsed != null) return parsed;
        }
      } catch (e) {
        if (kDebugMode) {
          debugPrint('findCustomerInvoiceId domain failed: $e');
        }
      }
    }
    return null;
  }

  /// Remove a QR-added product line from a draft customer invoice and restore
  /// pharmacy `entry.stock` qty (unlink alone does not always put stock back).
  ///
  /// Returns true when stock was restored and/or the line was removed.
  static Future<bool> removeCustomerInvoiceProduct({
    required String sessionId,
    required String invoiceNumber,
    required String productName,
    String? batch,
    String? potency,
    double quantity = 0,
    int? invoiceId,
  }) async {
    final moveId = invoiceId ??
        await findCustomerInvoiceId(sessionId, invoiceNumber);
    if (moveId == null) {
      if (kDebugMode) {
        debugPrint(
          'removeCustomerInvoiceProduct: invoice not found '
          '($invoiceNumber / id=$invoiceId)',
        );
      }
      return false;
    }

    final available = await _modelFields(sessionId, 'account.move.line');
    // Never request fields that do not exist (product_name is not on AML).
    const preferred = <String>[
      'id',
      'name',
      'display_type',
      'quantity',
      'product_id',
      'medicine_id',
      'batch_no',
      'batch',
      'lot_id',
      'potency_id',
      'potency',
      'stock_entry_id',
    ];
    final fields = available.isEmpty
        ? const [
            'id',
            'name',
            'display_type',
            'quantity',
            'medicine_id',
            'batch_no',
            'potency_id',
            'stock_entry_id',
          ]
        : preferred
            .where((f) => f == 'id' || available.contains(f))
            .toList(growable: false);

    List<dynamic> lineRows = const [];
    for (final domain in [
      [
        ['move_id', '=', moveId],
        ['display_type', '=', 'product'],
      ],
      [
        ['move_id', '=', moveId],
      ],
    ]) {
      try {
        final result = await callKw(
          sessionId: sessionId,
          model: 'account.move.line',
          method: 'search_read',
          args: [domain],
          kwargs: {'fields': fields, 'limit': 200},
        );
        if (result is List && result.isNotEmpty) {
          lineRows = result;
          break;
        }
      } catch (e) {
        if (kDebugMode) {
          debugPrint('removeCustomerInvoiceProduct search lines: $e');
        }
      }
    }

    if (lineRows.isEmpty) return false;

    final wantProduct = productName.trim().toLowerCase();
    final wantBatch = (batch ?? '').trim().toLowerCase();
    final wantPotency = (potency ?? '').trim().toLowerCase();
    var remaining = quantity > 0 ? quantity : double.infinity;

    final toUnlink = <int>[];
    final toReduce = <int, double>{};
    // entry.stock id → qty to put back
    final restoreByEntry = <int, double>{};

    for (final raw in lineRows) {
      if (remaining <= 0) break;
      if (raw is! Map) continue;
      final map = _normalizeOdooMap(Map<String, dynamic>.from(raw));

      final displayType = (map['display_type'] ?? '').toString().trim();
      if (displayType.isNotEmpty &&
          displayType != 'false' &&
          displayType != 'product') {
        continue;
      }

      final lineProduct = (
        map['product_name'] ??
            map['medicine_id_name'] ??
            map['product_id_name'] ??
            map['name'] ??
            ''
      ).toString().trim().toLowerCase();
      if (wantProduct.isNotEmpty &&
          lineProduct.isNotEmpty &&
          lineProduct != wantProduct &&
          !lineProduct.contains(wantProduct) &&
          !wantProduct.contains(lineProduct)) {
        continue;
      }

      final lineBatch = (
        map['batch'] ??
            map['batch_no'] ??
            map['lot_id_name'] ??
            ''
      ).toString().trim().toLowerCase();
      if (wantBatch.isNotEmpty &&
          lineBatch.isNotEmpty &&
          lineBatch != wantBatch) {
        continue;
      }

      final linePotency = (
        map['potency'] ??
            map['potency_id_name'] ??
            ''
      ).toString().trim().toLowerCase();
      if (wantPotency.isNotEmpty &&
          linePotency.isNotEmpty &&
          linePotency != wantPotency) {
        continue;
      }

      final idRaw = map['id'];
      final id = idRaw is int
          ? idRaw
          : int.tryParse(idRaw?.toString() ?? '');
      if (id == null) continue;

      final lineQty =
          (map['quantity'] as num?)?.toDouble() ??
          (map['qty'] as num?)?.toDouble() ??
          0;
      if (lineQty <= 0) continue;

      final entryId = map['stock_entry_id'] is int
          ? map['stock_entry_id'] as int
          : int.tryParse(map['stock_entry_id']?.toString() ?? '');

      double take;
      if (!remaining.isFinite || remaining >= lineQty - 1e-9) {
        take = lineQty;
        toUnlink.add(id);
        remaining -= lineQty;
      } else {
        take = remaining;
        toReduce[id] = lineQty - remaining;
        remaining = 0;
      }

      if (entryId != null && entryId > 0 && take > 0) {
        restoreByEntry[entryId] = (restoreByEntry[entryId] ?? 0) + take;
      }
    }

    if (toUnlink.isEmpty && toReduce.isEmpty) {
      if (kDebugMode) {
        debugPrint(
          'removeCustomerInvoiceProduct: no matching line on move $moveId '
          'for $productName / $batch',
        );
      }
      return false;
    }

    // Restore pharmacy stock first (add_to_invoice deducted entry.stock).
    var stockRestored = false;
    for (final entry in restoreByEntry.entries) {
      final ok = await _increaseEntryStock(
        sessionId: sessionId,
        entryId: entry.key,
        qty: entry.value,
      );
      if (ok) stockRestored = true;
    }

    var lineChanged = false;

    if (toUnlink.isNotEmpty) {
      try {
        await callKw(
          sessionId: sessionId,
          model: 'account.move.line',
          method: 'unlink',
          args: [toUnlink],
        );
        lineChanged = true;
        if (kDebugMode) {
          debugPrint(
            'removeCustomerInvoiceProduct unlinked $toUnlink '
            'on move $moveId',
          );
        }
      } catch (e) {
        if (kDebugMode) {
          debugPrint('removeCustomerInvoiceProduct unlink failed: $e');
        }
        for (final id in toUnlink) {
          try {
            await callKw(
              sessionId: sessionId,
              model: 'account.move.line',
              method: 'write',
              args: [
                [id],
                {'quantity': 0},
              ],
            );
            lineChanged = true;
          } catch (e2) {
            if (kDebugMode) {
              debugPrint('removeCustomerInvoiceProduct qty=0 failed: $e2');
            }
          }
        }
      }
    }

    for (final entry in toReduce.entries) {
      try {
        await callKw(
          sessionId: sessionId,
          model: 'account.move.line',
          method: 'write',
          args: [
            [entry.key],
            {'quantity': entry.value},
          ],
        );
        lineChanged = true;
      } catch (e) {
        if (kDebugMode) {
          debugPrint('removeCustomerInvoiceProduct reduce failed: $e');
        }
      }
    }

    return stockRestored || lineChanged;
  }

  /// Put qty back onto pharmacy `entry.stock` after a bill line is removed.
  static Future<bool> _increaseEntryStock({
    required String sessionId,
    required int entryId,
    required double qty,
  }) async {
    if (qty <= 0) return false;

    final qtyFields = const [
      'qty',
      'quantity',
      'stock_qty',
      'available_qty',
      'remaining_qty',
      'product_qty',
    ];

    try {
      final available = await _modelFields(sessionId, 'entry.stock');
      final readFields = [
        'id',
        ...qtyFields.where(available.contains),
      ];
      if (readFields.length == 1) {
        // fields_get failed — still try common names.
        readFields.addAll(qtyFields);
      }

      final rows = await callKw(
        sessionId: sessionId,
        model: 'entry.stock',
        method: 'read',
        args: [
          [entryId],
          readFields,
        ],
      );
      if (rows is! List || rows.isEmpty || rows.first is! Map) {
        if (kDebugMode) {
          debugPrint('_increaseEntryStock: entry $entryId not readable');
        }
        return false;
      }

      final map = Map<String, dynamic>.from(rows.first as Map);
      String? field;
      double current = 0;
      for (final key in qtyFields) {
        if (!map.containsKey(key)) continue;
        final v = map[key];
        if (v is num) {
          field = key;
          current = v.toDouble();
          break;
        }
      }
      field ??= available.contains('qty')
          ? 'qty'
          : (available.contains('quantity') ? 'quantity' : 'stock_qty');

      final next = current + qty;
      final writeVal = next == next.roundToDouble() ? next.toInt() : next;
      await callKw(
        sessionId: sessionId,
        model: 'entry.stock',
        method: 'write',
        args: [
          [entryId],
          {field: writeVal},
        ],
      );
      if (kDebugMode) {
        debugPrint(
          '_increaseEntryStock #$entryId $field: $current + $qty → $writeVal',
        );
      }
      return true;
    } catch (e) {
      if (kDebugMode) debugPrint('_increaseEntryStock failed: $e');
      return false;
    }
  }

  /// Enrich a cheque-clearance row with payment + linked invoice details
  /// (Customer / Resp. Person / Financials / invoice 0458/…).
  ///
  /// Website models:
  /// - `cheque.entry` (CHQ/0023)
  /// - `partner.payment` (PAY/0236) — NEVER `account.payment` (PCSH…)
  /// - `account.move` via cheque `invoice_ids` (0458/…)
  static Future<ChequeClearanceModel?> enrichChequeClearance(
    String sessionId,
    ChequeClearanceModel cheque,
  ) async {
    try {
      var current = cheque;
      List<int> invoiceIds = const [];

      // 1) cheque.entry — source of truth for CHQ + linked invoices + PAY id.
      Map<String, dynamic>? chequeRow;
      if (cheque.id != null) {
        chequeRow = await _readChequeEntry(sessionId, cheque.id!);
      }
      if (chequeRow == null) {
        final serial = cheque.serialNumber?.trim();
        if (serial != null &&
            serial.isNotEmpty &&
            serial.toUpperCase().startsWith('CHQ')) {
          chequeRow = await _findChequeEntryByName(sessionId, serial);
        }
      }

      if (chequeRow != null) {
        invoiceIds = _odooIds(chequeRow['invoice_ids']);
        final payId =
            _asInt(chequeRow['partner_payment_id']) ?? cheque.partnerPaymentId;
        final payName = chequeRow['partner_payment_id_name']?.toString() ??
            ChequeClearanceModel.formatPartnerPaymentName(payId);

        current = current.mergedWith(
          ChequeClearanceModel.fromJson({
            'id': chequeRow['id'] ?? cheque.id,
            'serial_number': chequeRow['name'] ?? cheque.serialNumber,
            'name': chequeRow['name'] ?? cheque.serialNumber,
            'date': chequeRow['date'] ?? cheque.date,
            'cheque_no': chequeRow['cheque_no'] ?? cheque.chequeNumber,
            'cheque_date': chequeRow['cheque_date'] ?? cheque.chequeDate,
            'clearance_date': chequeRow['clearance_date'] ??
                chequeRow['deposit_date'] ??
                cheque.clearanceDate,
            'deposit_date': chequeRow['deposit_date'],
            'cheque_amount': chequeRow['cheque_amount'] ?? cheque.chequeAmount,
            'list_cheque_amount':
                chequeRow['cheque_amount'] ?? cheque.chequeAmount,
            'balance_amount':
                chequeRow['balance_amount'] ?? cheque.balance,
            'list_balance_amount':
                chequeRow['balance_amount'] ?? cheque.balance,
            'partner_id': chequeRow['partner_id'] ?? cheque.partnerId,
            'partner_name':
                chequeRow['partner_id_name'] ?? cheque.partnerName,
            'bank_id_name': chequeRow['bank_id_name'] ?? cheque.bank,
            'bank_name': chequeRow['bank_id_name'] ?? cheque.bank,
            'branch': chequeRow['branch'] ?? cheque.branch,
            'ifsc': chequeRow['ifsc'] ?? cheque.ifsc,
            'state': chequeRow['state'] ?? cheque.state,
            'partner_payment_id': payId,
            'customer_payment': payName,
            'credited_to': chequeRow['bank_id_name'] ?? cheque.bank,
            'validated_by': chequeRow['create_uid_name'],
            'responsible_person': chequeRow['responsible_person'] ??
                chequeRow['responsible_id_name'] ??
                chequeRow['responsible_person_id_name'],
          }),
        );
      }

      // 2) partner.payment (PAY/…) — never account.payment / PCSH.
      //    Customer Payment invoices come from payment lines (all rows),
      //    each with its own pay amount (e.g. 0605/0, 0606/500, 0607/0).
      final payId = current.partnerPaymentId;
      List<_PartnerPaymentLineRef> paymentLines = const [];
      if (payId != null) {
        final paymentRow = await _readPartnerPaymentRow(sessionId, payId);
        if (paymentRow != null) {
          paymentLines =
              await _readPartnerPaymentLines(sessionId, payId);
          if (paymentLines.isEmpty) {
            // Fallback: one2many ids on partner.payment.
            final embeddedLineIds = <int>{
              ..._odooIds(paymentRow['line_ids']),
              ..._odooIds(paymentRow['payment_line_ids']),
              ..._odooIds(paymentRow['invoice_line_ids']),
            };
            if (embeddedLineIds.isNotEmpty) {
              paymentLines = await _readPartnerPaymentLinesByIds(
                sessionId,
                embeddedLineIds.toList(),
              );
            }
          }
          final lineInvoiceIds = <int>{
            ..._odooIds(paymentRow['invoice_ids']),
            ..._odooIds(paymentRow['reconciled_invoice_ids']),
            ...paymentLines.map((e) => e.moveId),
          };
          // Prefer payment-line invoice set (full Customer Payment table).
          if (lineInvoiceIds.isNotEmpty) {
            invoiceIds = lineInvoiceIds.toList();
          }

          final payName = paymentRow['name']?.toString();
          final safePayName =
              (payName != null &&
                      payName.toUpperCase().contains('PCSH'))
                  ? ChequeClearanceModel.formatPartnerPaymentName(payId)
                  : (payName ?? current.displayCustomerPayment);

          current = current.mergedWith(
            ChequeClearanceModel.fromJson({
              'customer_payment': safePayName,
              'partner_payment_id': payId,
              'partner_name':
                  paymentRow['partner_id_name'] ?? current.partnerName,
              'payment_amount': paymentRow['amount'] ??
                  paymentRow['payment_amount'] ??
                  paymentRow['cheque_amount'] ??
                  current.chequeAmount,
              'cheque_amount': current.chequeAmount ??
                  paymentRow['cheque_amount'] ??
                  paymentRow['amount'],
              'list_cheque_amount': current.chequeAmount ??
                  paymentRow['amount'] ??
                  paymentRow['cheque_amount'],
              'advance_amount': paymentRow['advance_amount'] ?? 0,
              'old_balance': paymentRow['old_balance'] ?? 0,
              'payment_mode': paymentRow['payment_mode'] ?? 'Cheque',
              'validated_by': paymentRow['create_uid_name'] ??
                  paymentRow['validated_by_name'] ??
                  current.validatedBy,
              'responsible_person': paymentRow['responsible_person'] ??
                  paymentRow['responsible_id_name'] ??
                  paymentRow['responsible_person_id_name'],
              'date': paymentRow['date'] ??
                  paymentRow['payment_date'] ??
                  current.date,
              'clearance_date':
                  paymentRow['clearance_date'] ?? current.clearanceDate,
              'credited_to': paymentRow['credited_to'] ??
                  paymentRow['bank_id_name'] ??
                  current.creditedTo ??
                  current.bank,
              'cheque_no':
                  paymentRow['cheque_no'] ?? current.chequeNumber,
              'payment_bank': paymentRow['bank_name'] ??
                  paymentRow['bank'] ??
                  paymentRow['cheque_bank'],
              'branch': paymentRow['branch'] ?? current.branch,
              'ifsc': paymentRow['ifsc'] ??
                  paymentRow['ifsc_code'] ??
                  current.ifsc,
            }),
          );
        }
      }

      // 3) Invoices from partner.payment.line (select / balance / pay).
      // Website:
      // - Cheque Details TOTAL AMOUNT = selected line.balance (815), not
      //   cheque.entry.balance_amount (3985).
      // - Customer Payment rows use line.balance + move amount_total +
      //   pay = payment_amount when select=true else 0.
      final chequeSelectedIds = <int>{
        ..._odooIds(chequeRow?['invoice_ids']),
      };
      if (invoiceIds.isNotEmpty || paymentLines.isNotEmpty) {
        final paymentTotal = current.displayPaymentAmount ?? 0;
        final payByMove = <int, double?>{};
        final balanceByMove = <int, double?>{};
        final totalByMove = <int, double?>{};
        final selectedByMove = <int, bool>{};

        for (final line in paymentLines) {
          final selected = line.selected ||
              chequeSelectedIds.contains(line.moveId);
          selectedByMove[line.moveId] = selected;
          balanceByMove[line.moveId] = line.balance;
          if (line.total != null) totalByMove[line.moveId] = line.total;
          // Lines often have no pay_amount — website uses payment total on
          // the selected row only.
          payByMove[line.moveId] = line.payAmount ??
              (selected ? paymentTotal : 0);
        }

        for (final id in chequeSelectedIds) {
          selectedByMove[id] = true;
          payByMove[id] = payByMove[id] ?? paymentTotal;
        }
        for (final id in invoiceIds) {
          selectedByMove.putIfAbsent(id, () => false);
          payByMove.putIfAbsent(
            id,
            () => (selectedByMove[id] == true) ? paymentTotal : 0,
          );
        }

        final orderedIds = <int>[];
        if (paymentLines.isNotEmpty) {
          for (final line in paymentLines) {
            if (!orderedIds.contains(line.moveId)) orderedIds.add(line.moveId);
          }
          for (final id in invoiceIds) {
            if (!orderedIds.contains(id)) orderedIds.add(id);
          }
        } else {
          orderedIds.addAll(invoiceIds);
        }

        final invoices = await _readMovesAsLinkedInvoices(
          sessionId,
          orderedIds,
          payAmountByMove: payByMove,
          balanceByMove: balanceByMove,
          totalByMove: totalByMove,
          selectedByMove: selectedByMove,
          partnerName: current.partnerName,
        );
        if (invoices.isNotEmpty) {
          current = current.copyWith(invoices: invoices);

          // Party Details TOTAL AMOUNT = selected payment-line balance (815).
          double? selectedBalance;
          for (final line in paymentLines) {
            if (line.selected || chequeSelectedIds.contains(line.moveId)) {
              selectedBalance = line.balance;
              break;
            }
          }
          selectedBalance ??= invoices
              .where((e) => e.selected)
              .map((e) => e.balance)
              .whereType<double>()
              .cast<double?>()
              .firstWhere((e) => e != null, orElse: () => null);
          if (selectedBalance != null) {
            current = current.copyWith(balance: selectedBalance);
          }

          final withResp = invoices.where(
            (e) => (e.responsiblePerson ?? '').trim().isNotEmpty,
          );
          final resp = (withResp.isNotEmpty
                  ? withResp.first
                  : invoices.first)
              .responsiblePerson
              ?.trim();
          if (resp != null && resp.isNotEmpty) {
            current = current.copyWith(responsiblePerson: resp);
          }
        }
      }

      current = current.copyWith(
        paymentMode: () {
          final mode = current.paymentMode?.trim();
          if (mode == null || mode.isEmpty) return 'Cheque';
          if (mode.toLowerCase() == 'cheque') return 'Cheque';
          return mode;
        }(),
        advanceAmount: current.advanceAmount ?? 0,
        oldBalance: current.oldBalance ?? 0,
        creditedTo: (current.creditedTo?.trim().isNotEmpty == true)
            ? current.creditedTo
            : current.bank,
        customerPayment: current.hasCustomerPayment
            ? current.displayCustomerPayment
            : current.customerPayment,
      );

      return current;
    } catch (e, s) {
      if (kDebugMode) debugPrint('enrichChequeClearance: $e\n$s');
      return cheque;
    }
  }

  static Future<Map<String, dynamic>?> _findChequeEntryByName(
    String sessionId,
    String name,
  ) async {
    try {
      final rows = await callKw(
        sessionId: sessionId,
        model: 'cheque.entry',
        method: 'search_read',
        args: [
          [
            ['name', '=', name],
          ],
        ],
        kwargs: {
          'fields': ['id', 'name'],
          'limit': 1,
        },
      );
      if (rows is! List || rows.isEmpty || rows.first is! Map) return null;
      final id = _asInt((rows.first as Map)['id']);
      if (id == null) return null;
      return _readChequeEntry(sessionId, id);
    } catch (e) {
      if (kDebugMode) debugPrint('_findChequeEntryByName: $e');
      return null;
    }
  }

  static Future<Map<String, dynamic>?> _readChequeEntry(
    String sessionId,
    int chequeId,
  ) async {
    try {
      final available = await _modelFields(sessionId, 'cheque.entry');
      if (available.isEmpty) return null;
      final fields = <String>['id', 'name'];
      for (final f in const [
        'serial_number',
        'date',
        'cheque_no',
        'cheque_number',
        'cheque_date',
        'clearance_date',
        'deposit_date',
        'cheque_amount',
        'balance_amount',
        'partner_id',
        'bank_id',
        'branch',
        'ifsc',
        'state',
        'partner_payment_id',
        'invoice_ids',
        'responsible_person',
        'responsible_id',
        'user_id',
        'create_uid',
      ]) {
        if (available.contains(f)) fields.add(f);
      }
      final rows = await callKw(
        sessionId: sessionId,
        model: 'cheque.entry',
        method: 'read',
        args: [
          [chequeId],
          fields,
        ],
      );
      if (rows is List && rows.isNotEmpty && rows.first is Map) {
        return _normalizeOdooMap(Map<String, dynamic>.from(rows.first as Map));
      }
    } catch (e) {
      if (kDebugMode) debugPrint('_readChequeEntry: $e');
    }
    return null;
  }

  static Future<Map<String, dynamic>?> _readPartnerPaymentRow(
    String sessionId,
    int paymentId,
  ) async {
    try {
      final available = await _modelFields(sessionId, 'partner.payment');
      if (available.isEmpty) return null;
      final fields = <String>['id', 'name'];
      for (final f in const [
        'partner_id',
        'amount',
        'amount_total',
        'payment_amount',
        'date',
        'payment_date',
        'clearance_date',
        'payment_type',
        'payment_mode',
        'journal_id',
        'ref',
        'state',
        'memo',
        'cheque_no',
        'cheque_number',
        'cheque_date',
        'cheque_amount',
        'bank',
        'bank_name',
        'bank_id',
        'branch',
        'ifsc',
        'ifsc_code',
        'advance_amount',
        'old_balance',
        'create_uid',
        'user_id',
        'responsible_person',
        'responsible_id',
        'validated_by',
        'invoice_ids',
        'line_ids',
        'payment_line_ids',
        'credited_to',
        'credit_to',
      ]) {
        if (available.contains(f)) fields.add(f);
      }
      final rows = await callKw(
        sessionId: sessionId,
        model: 'partner.payment',
        method: 'read',
        args: [
          [paymentId],
          fields,
        ],
      );
      if (rows is List && rows.isNotEmpty && rows.first is Map) {
        return _normalizeOdooMap(Map<String, dynamic>.from(rows.first as Map));
      }
    } catch (e) {
      if (kDebugMode) debugPrint('_readPartnerPaymentRow: $e');
    }
    return null;
  }

  static Future<ChequeClearanceModel?> _readPartnerPayment(
    String sessionId,
    int paymentId,
  ) async {
    final row = await _readPartnerPaymentRow(sessionId, paymentId);
    if (row == null) return null;
    final name = row['name']?.toString() ?? '';
    final safeName = name.toUpperCase().contains('PCSH')
        ? ChequeClearanceModel.formatPartnerPaymentName(paymentId)
        : (name.isNotEmpty
            ? name
            : ChequeClearanceModel.formatPartnerPaymentName(paymentId));
    return ChequeClearanceModel.fromJson({
      'customer_payment': safeName,
      'partner_payment_id': paymentId,
      'partner_name': row['partner_id_name'],
      'payment_amount': row['amount'] ?? row['payment_amount'],
      'cheque_amount': row['cheque_amount'] ?? row['amount'],
      'list_cheque_amount': row['amount'] ?? row['cheque_amount'],
      'payment_mode': row['payment_mode'] ?? 'Cheque',
      'validated_by': row['create_uid_name'] ?? row['validated_by'],
      // Never fall back to user_id/create_uid (Administrator).
      'responsible_person': row['responsible_person'] ??
          row['responsible_id_name'] ??
          row['responsible_person_id_name'],
      'credited_to': row['credited_to'] ??
          row['bank_id_name'] ??
          row['journal_id_name'],
      'payment_bank': row['bank_name'] ?? row['bank'],
      'cheque_no': row['cheque_no'],
      'branch': row['branch'],
      'ifsc': row['ifsc'] ?? row['ifsc_code'],
      'date': row['date'] ?? row['payment_date'],
      'clearance_date': row['clearance_date'],
      'advance_amount': row['advance_amount'] ?? 0,
      'old_balance': row['old_balance'] ?? 0,
    });
  }

  static Future<List<_PartnerPaymentLineRef>> _readPartnerPaymentLines(
    String sessionId,
    int paymentId,
  ) async {
    try {
      final available = await _modelFields(sessionId, 'partner.payment.line');
      if (available.isEmpty) return const [];
      final fields = _partnerPaymentLineFields(available);

      String? parentField;
      for (final candidate in const [
        'partner_payment_id',
        'payment_id',
      ]) {
        if (available.contains(candidate)) {
          parentField = candidate;
          break;
        }
      }
      if (parentField == null) return const [];

      final rows = await callKw(
        sessionId: sessionId,
        model: 'partner.payment.line',
        method: 'search_read',
        args: [
          [
            [parentField, '=', paymentId],
          ],
        ],
        kwargs: {
          'fields': fields,
          'limit': 100,
          'order': 'id asc',
        },
      );
      return _parsePartnerPaymentLines(rows);
    } catch (e) {
      if (kDebugMode) debugPrint('_readPartnerPaymentLines: $e');
      return const [];
    }
  }

  static Future<List<_PartnerPaymentLineRef>> _readPartnerPaymentLinesByIds(
    String sessionId,
    List<int> lineIds,
  ) async {
    if (lineIds.isEmpty) return const [];
    try {
      final available = await _modelFields(sessionId, 'partner.payment.line');
      if (available.isEmpty) return const [];
      final fields = _partnerPaymentLineFields(available);
      final rows = await callKw(
        sessionId: sessionId,
        model: 'partner.payment.line',
        method: 'read',
        args: [lineIds, fields],
      );
      return _parsePartnerPaymentLines(rows);
    } catch (e) {
      if (kDebugMode) debugPrint('_readPartnerPaymentLinesByIds: $e');
      return const [];
    }
  }

  static List<String> _partnerPaymentLineFields(Set<String> available) {
    final fields = <String>['id'];
    for (final f in const [
      'move_id',
      'invoice_id',
      'account_move_id',
      'payment_id',
      'partner_payment_id',
      'amount',
      'pay_amount',
      'amount_total',
      'total',
      'amount_residual',
      'balance',
      'selected',
      'is_selected',
      'select',
    ]) {
      if (available.contains(f)) fields.add(f);
    }
    return fields;
  }

  static List<_PartnerPaymentLineRef> _parsePartnerPaymentLines(dynamic rows) {
    if (rows is! List) return const [];
    final out = <_PartnerPaymentLineRef>[];
    for (final raw in rows) {
      if (raw is! Map) continue;
      final map = _normalizeOdooMap(Map<String, dynamic>.from(raw));
      final move = _asInt(map['move_id']) ??
          _asInt(map['invoice_id']) ??
          _asInt(map['account_move_id']);
      if (move == null) continue;
      final pay = _asDouble(map['pay_amount']) ?? _asDouble(map['amount']);
      final balance = _asDouble(map['balance']) ??
          _asDouble(map['amount_residual']);
      final total = _asDouble(map['total']) ?? _asDouble(map['amount_total']);
      final label = map['invoice_id_name']?.toString() ??
          map['move_id_name']?.toString() ??
          map['account_move_id_name']?.toString();
      final selectedRaw =
          map['selected'] ?? map['is_selected'] ?? map['select'];
      final selected = selectedRaw == true ||
          selectedRaw == 1 ||
          (pay != null && pay > 0);
      out.add(_PartnerPaymentLineRef(
        moveId: move,
        payAmount: pay,
        balance: balance,
        total: total,
        invoiceLabel: label,
        selected: selected,
      ));
    }
    return out;
  }

  static Future<List<ChequeLinkedInvoice>> _readMovesAsLinkedInvoices(
    String sessionId,
    List<int> moveIds, {
    double? payAmount,
    Map<int, double?>? payAmountByMove,
    Map<int, double?>? balanceByMove,
    Map<int, double?>? totalByMove,
    Map<int, bool>? selectedByMove,
    String? partnerName,
  }) async {
    if (moveIds.isEmpty) return const [];
    try {
      final available = await _modelFields(sessionId, 'account.move');
      final fields = <String>['id', 'name', 'display_name'];
      for (final f in const [
        'invoice_date',
        'date',
        'amount_total',
        'amount_untaxed',
        'amount_tax',
        'amount_residual',
        'payment_state',
        'state',
        'partner_id',
        'invoice_user_id',
        'user_id',
        'narration',
        'invoice_number',
        'invoice_no',
        'pharmacy_invoice_number',
        'bill_number',
        'bill_no',
        'total',
        'subtotal',
        'responsible_person',
        'responsible_person_id',
        'billed_by',
        'billed_by_name',
        'salesperson_id',
      ]) {
        if (available.contains(f)) fields.add(f);
      }
      // Pharmacy TOTAL column uses custom `total` when present (0607 → 1183.50).
      for (final key in const ['total', 'amount_total', 'amount_untaxed']) {
        if (!fields.contains(key) && available.contains(key)) {
          fields.add(key);
        }
      }
      final rows = await callKw(
        sessionId: sessionId,
        model: 'account.move',
        method: 'read',
        args: [moveIds, fields],
      );
      if (rows is! List) return const [];

      final byId = <int, Map<String, dynamic>>{};
      for (final raw in rows.whereType<Map>()) {
        final map = _normalizeOdooMap(Map<String, dynamic>.from(raw));
        final id = _asInt(map['id']);
        if (id != null) byId[id] = map;
      }

      final ordered = <Map<String, dynamic>>[];
      for (final id in moveIds) {
        final map = byId[id];
        if (map != null) ordered.add(map);
      }

      return ordered.map((map) {
        final id = _asInt(map['id']);
        final number = _pharmacyInvoiceNumber(map) ??
            map['name']?.toString() ??
            map['display_name']?.toString();
        final paymentState =
            map['payment_state']?.toString() ?? map['state']?.toString();
        final resp = _firstNonEmpty([
          map['responsible_person']?.toString(),
          map['responsible_person_id_name']?.toString(),
          map['billed_by']?.toString(),
          map['billed_by_name']?.toString(),
          map['invoice_user_id_name']?.toString(),
          map['salesperson_id_name']?.toString(),
        ]);
        final linePay = id == null ? null : payAmountByMove?[id];
        final lineBalance = id == null ? null : balanceByMove?[id];
        final lineTotal = id == null ? null : totalByMove?[id];
        final selected = id == null
            ? ((linePay ?? payAmount ?? 0) > 0)
            : (selectedByMove?[id] ?? ((linePay ?? 0) > 0));
        final resolvedPay = payAmountByMove != null
            ? (linePay ?? 0)
            : (linePay ?? payAmount);
        // Prefer pharmacy `total` (website TOTAL) over amount_total when set.
        final resolvedTotal = lineTotal ??
            _asDouble(map['total']) ??
            _asDouble(map['amount_total']) ??
            _asDouble(map['subtotal']) ??
            _asDouble(map['amount_untaxed']);
        // Website BALANCE column = payment-line.balance (not always residual).
        final resolvedBalance =
            lineBalance ?? _asDouble(map['amount_residual']);
        return ChequeLinkedInvoice(
          moveId: id,
          number: number,
          invoiceDate:
              map['invoice_date']?.toString() ?? map['date']?.toString(),
          total: resolvedTotal,
          balance: resolvedBalance,
          payAmount: resolvedPay,
          status: _prettyInvoiceStatus(paymentState),
          responsiblePerson: resp,
          partnerName: map['partner_id_name']?.toString() ?? partnerName,
          narration: map['narration']?.toString(),
          selected: selected,
        );
      }).toList();
    } catch (e) {
      if (kDebugMode) debugPrint('_readMovesAsLinkedInvoices: $e');
      return const [];
    }
  }

  static String? _firstNonEmpty(List<String?> values) {
    for (final value in values) {
      final text = value?.trim();
      if (text == null || text.isEmpty || text == 'false') continue;
      return text;
    }
    return null;
  }

  static String? _prettyInvoiceStatus(String? status) {
    if (status == null || status.trim().isEmpty) return null;
    final raw = status.trim();
    final lower = raw.toLowerCase().replaceAll('_', ' ');
    if (lower == 'in payment') return 'In Payment';
    if (lower == 'not paid') return 'Not Paid';
    if (lower == 'partial' || lower == 'partially paid') return 'Partially Paid';
    return raw[0].toUpperCase() + raw.substring(1);
  }

  static int? _asInt(dynamic value) {
    if (value == null || value == false || value == true) return null;
    if (value is int) return value;
    if (value is num) return value.toInt();
    if (value is List && value.isNotEmpty) {
      return _asInt(value.first);
    }
    return int.tryParse(value.toString());
  }

  /// Load Customer Payment (e.g. PAY/0236) via partner.payment only.
  static Future<ChequeClearanceModel?> fetchCustomerPaymentByName(
    String sessionId,
    String paymentName, {
    ChequeClearanceModel? base,
    int? paymentId,
  }) async {
    final resolvedId = paymentId ??
        base?.partnerPaymentId ??
        _paymentIdFromName(paymentName.trim());
    if (resolvedId == null) return base;

    try {
      // CRITICAL: partner.payment — never account.payment (PCSH…).
      final fromPartner = await _readPartnerPayment(sessionId, resolvedId);
      if (fromPartner != null) {
        return base?.mergedWith(fromPartner) ?? fromPartner;
      }

      // Fallback: search partner.payment by name PAY/0236.
      final name = paymentName.trim();
      if (name.isNotEmpty && name != '—') {
        final rows = await callKw(
          sessionId: sessionId,
          model: 'partner.payment',
          method: 'search_read',
          args: [
            [
              ['name', '=', name],
            ],
          ],
          kwargs: {
            'fields': ['id', 'name'],
            'limit': 1,
          },
        );
        if (rows is List && rows.isNotEmpty && rows.first is Map) {
          final id = _asInt((rows.first as Map)['id']);
          if (id != null) {
            final found = await _readPartnerPayment(sessionId, id);
            if (found != null) {
              return base?.mergedWith(found) ?? found;
            }
          }
        }
      }
      return base;
    } catch (e, s) {
      if (kDebugMode) debugPrint('fetchCustomerPaymentByName: $e\n$s');
      return base;
    }
  }

  static int? _paymentIdFromName(String name) {
    final match = RegExp(r'PAY/0*(\d+)', caseSensitive: false).firstMatch(name);
    if (match == null) return null;
    return int.tryParse(match.group(1) ?? '');
  }

  static Future<int?> findPartnerIdByName(
    String sessionId,
    String name,
  ) =>
      _findPartnerIdByName(sessionId, name);

  /// Create a draft Customer Payment (`partner.payment`) — syncs to website.
  static Future<int?> createPartnerPaymentDraft(
    String sessionId, {
    Map<String, dynamic>? values,
  }) async {
    try {
      final available = await _modelFields(sessionId, 'partner.payment');
      if (available.isEmpty) return null;
      final vals = <String, dynamic>{};
      final incoming = values ?? const <String, dynamic>{};
      for (final entry in incoming.entries) {
        if (available.contains(entry.key) && entry.value != null) {
          vals[entry.key] = entry.value;
        }
      }
      if (available.contains('payment_mode') && !vals.containsKey('payment_mode')) {
        vals['payment_mode'] = 'cash';
      }
      if (available.contains('date') && !vals.containsKey('date')) {
        vals['date'] = _ymd(DateTime.now());
      }
      if (available.contains('clearance_date') &&
          !vals.containsKey('clearance_date')) {
        vals['clearance_date'] = _ymd(DateTime.now());
      }
      if (available.contains('payment_amount') &&
          !vals.containsKey('payment_amount')) {
        vals['payment_amount'] = 0;
      }
      final created = await callKw(
        sessionId: sessionId,
        model: 'partner.payment',
        method: 'create',
        args: [vals],
      );
      if (created is int) return created;
      if (created is num) return created.toInt();
      return int.tryParse(created?.toString() ?? '');
    } catch (e, s) {
      if (kDebugMode) debugPrint('createPartnerPaymentDraft: $e\n$s');
      rethrow;
    }
  }

  static String _ymd(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-'
      '${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';

  /// Write fields on partner.payment (live sync with website form).
  static Future<bool> updatePartnerPayment(
    String sessionId,
    int paymentId,
    Map<String, dynamic> values,
  ) async {
    try {
      final available = await _modelFields(sessionId, 'partner.payment');
      if (available.isEmpty) return false;
      final vals = <String, dynamic>{};
      for (final entry in values.entries) {
        if (!available.contains(entry.key)) continue;
        vals[entry.key] = entry.value;
      }
      if (vals.isEmpty) return true;
      await callKw(
        sessionId: sessionId,
        model: 'partner.payment',
        method: 'write',
        args: [
          [paymentId],
          vals,
        ],
      );
      return true;
    } catch (e, s) {
      if (kDebugMode) debugPrint('updatePartnerPayment: $e\n$s');
      rethrow;
    }
  }

  /// Payment mode selection labels from partner.payment.payment_mode.
  static Future<List<String>> partnerPaymentModes(String sessionId) async {
    try {
      final meta = await callKw(
        sessionId: sessionId,
        model: 'partner.payment',
        method: 'fields_get',
        args: [
          ['payment_mode'],
        ],
        kwargs: const {
          'attributes': ['type', 'string', 'selection'],
        },
      );
      if (meta is! Map) {
        return const ['Cash', 'Cheque', 'Bank', 'UPI'];
      }
      final field = meta['payment_mode'];
      if (field is! Map) return const ['Cash', 'Cheque', 'Bank', 'UPI'];
      final selection = field['selection'];
      if (selection is! List || selection.isEmpty) {
        return const ['Cash', 'Cheque', 'Bank', 'UPI'];
      }
      final labels = <String>[];
      for (final row in selection) {
        if (row is List && row.length >= 2) {
          final label = row[1]?.toString().trim() ?? '';
          if (label.isNotEmpty) labels.add(label);
        }
      }
      return labels.isEmpty
          ? const ['Cash', 'Cheque', 'Bank', 'UPI']
          : labels;
    } catch (e) {
      if (kDebugMode) debugPrint('partnerPaymentModes: $e');
      return const ['Cash', 'Cheque', 'Bank', 'UPI'];
    }
  }

  static String partnerPaymentModeValue(String label) {
    final lower = label.trim().toLowerCase();
    if (lower.contains('cheque') || lower.contains('check')) return 'cheque';
    if (lower.contains('bank')) return 'bank';
    if (lower.contains('upi')) return 'upi';
    if (lower.contains('card')) return 'card';
    return 'cash';
  }

  /// Open invoices shown on Customer Payment = partner.payment.line rows.
  static Future<List<ChequeLinkedInvoice>> invoicesFromPartnerPayment(
    String sessionId,
    int paymentId, {
    double? defaultPayAmount,
  }) async {
    final lines = await _readPartnerPaymentLines(sessionId, paymentId);
    if (lines.isEmpty) {
      // Fallback: read embedded line ids then parse.
      final header = await _readPartnerPaymentRow(sessionId, paymentId);
      if (header == null) return const [];
      final lineIds = <int>{
        ..._odooIds(header['payment_line_ids']),
        ..._odooIds(header['line_ids']),
      };
      if (lineIds.isEmpty) return const [];
      final byIds =
          await _readPartnerPaymentLinesByIds(sessionId, lineIds.toList());
      return _linesToLinkedInvoices(byIds, defaultPayAmount: defaultPayAmount);
    }
    return _linesToLinkedInvoices(lines, defaultPayAmount: defaultPayAmount);
  }

  static List<ChequeLinkedInvoice> _linesToLinkedInvoices(
    List<_PartnerPaymentLineRef> lines, {
    double? defaultPayAmount,
  }) {
    return lines.map((line) {
      final selected = line.selected || ((line.payAmount ?? 0) > 0);
      final pay = line.payAmount ??
          (selected ? (defaultPayAmount ?? 0) : 0);
      final number = (line.invoiceLabel ?? '').trim().isNotEmpty
          ? line.invoiceLabel
          : 'INV/${line.moveId}';
      return ChequeLinkedInvoice(
        moveId: line.moveId,
        number: number,
        total: line.total,
        balance: line.balance,
        payAmount: pay,
        selected: selected,
        status: selected
            ? 'In Payment'
            : ((line.balance ?? 0) > 0 ? 'Not Paid' : 'Paid'),
      );
    }).toList();
  }

  /// Open customer invoices for the payment form table.
  static Future<List<ChequeLinkedInvoice>> openInvoicesForPartner(
    String sessionId, {
    int? partnerId,
    String? partnerName,
  }) async {
    try {
      final domain = <dynamic>[
        ['move_type', '=', 'out_invoice'],
        ['state', '=', 'posted'],
        ['payment_state', 'in', ['not_paid', 'partial', 'in_payment']],
      ];
      if (partnerId != null) {
        domain.add(['partner_id', '=', partnerId]);
      } else if ((partnerName ?? '').trim().isNotEmpty) {
        domain.add([
          'partner_id.name',
          'ilike',
          partnerName!.split(',').first.trim(),
        ]);
      } else {
        return const [];
      }

      final available = await _modelFields(sessionId, 'account.move');
      final fields = <String>['id', 'name', 'display_name'];
      for (final f in const [
        'invoice_date',
        'date',
        'amount_total',
        'amount_residual',
        'payment_state',
        'state',
        'partner_id',
        'responsible_person',
        'responsible_person_id',
        'total',
        'narration',
      ]) {
        if (available.contains(f)) fields.add(f);
      }

      final rows = await callKw(
        sessionId: sessionId,
        model: 'account.move',
        method: 'search_read',
        args: [domain],
        kwargs: {
          'fields': fields,
          'limit': 50,
          'order': 'invoice_date desc, id desc',
        },
      );
      if (rows is! List) return const [];
      return rows.whereType<Map>().map((raw) {
        final map = _normalizeOdooMap(Map<String, dynamic>.from(raw));
        final number = _pharmacyInvoiceNumber(map) ??
            map['name']?.toString() ??
            map['display_name']?.toString();
        return ChequeLinkedInvoice(
          moveId: _asInt(map['id']),
          number: number,
          invoiceDate:
              map['invoice_date']?.toString() ?? map['date']?.toString(),
          total: _asDouble(map['total']) ?? _asDouble(map['amount_total']),
          balance: _asDouble(map['amount_residual']),
          payAmount: 0,
          status: _prettyInvoiceStatus(
            map['payment_state']?.toString() ?? map['state']?.toString(),
          ),
          responsiblePerson: map['responsible_person']?.toString() ??
              map['responsible_person_id_name']?.toString(),
          partnerName: map['partner_id_name']?.toString() ?? partnerName,
          narration: map['narration']?.toString(),
          selected: false,
        );
      }).toList();
    } catch (e) {
      if (kDebugMode) debugPrint('openInvoicesForPartner: $e');
      return const [];
    }
  }

  static Future<Map<String, dynamic>?> readPartnerPaymentHeader(
    String sessionId,
    int paymentId,
  ) async {
    return _readPartnerPaymentRow(sessionId, paymentId);
  }

  /// Run website button on partner.payment (Pay Bill / Confirm / Cancel).
  static Future<bool> runPartnerPaymentAction(
    String sessionId,
    int paymentId,
    List<String> methodCandidates,
  ) async {
    Object? lastError;
    for (final method in methodCandidates) {
      try {
        await callKw(
          sessionId: sessionId,
          model: 'partner.payment',
          method: method,
          args: [
            [paymentId],
          ],
        );
        return true;
      } catch (e) {
        lastError = e;
        if (kDebugMode) {
          debugPrint('partner.payment.$method failed: $e');
        }
      }
    }
    if (lastError != null) throw Exception(lastError.toString());
    return false;
  }

  static Future<bool> confirmPartnerPayment(
    String sessionId,
    int paymentId,
  ) =>
      runPartnerPaymentAction(sessionId, paymentId, const [
        'action_confirm',
        'button_confirm',
        'action_validate',
        'action_post',
        'button_validate',
      ]);

  static Future<bool> payBillPartnerPayment(
    String sessionId,
    int paymentId,
  ) =>
      runPartnerPaymentAction(sessionId, paymentId, const [
        'action_pay_bill',
        'button_pay_bill',
        'action_pay',
        'button_pay',
        'action_register_payment',
      ]);

  static Future<bool> cancelPartnerPayment(
    String sessionId,
    int paymentId,
  ) async {
    try {
      final ok = await runPartnerPaymentAction(sessionId, paymentId, const [
        'action_cancel',
        'button_cancel',
        'action_draft',
      ]);
      if (ok) return true;
    } catch (_) {}
    try {
      await callKw(
        sessionId: sessionId,
        model: 'partner.payment',
        method: 'unlink',
        args: [
          [paymentId],
        ],
      );
      return true;
    } catch (e) {
      if (kDebugMode) debugPrint('cancelPartnerPayment unlink: $e');
      rethrow;
    }
  }

  static double? _asDouble(dynamic value) {
    if (value == null || value == false) return null;
    if (value is num) return value.toDouble();
    return double.tryParse(value.toString().replaceAll(',', '').trim());
  }
}
