import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../../models/stock_item_model.dart';
import 'WebApi/web_api_impl.dart';
import 'api_request_helper.dart';
import 'endPoints.dart';
import 'label_ocr_parser.dart';

/// Stock search and label matching helpers for OCR scanner flow.
class LabelStockService {
  LabelStockService._();

  static Future<List<StockItemModel>> searchStock(
    String sessionId,
    String query, {
    int limit = 200,
  }) async {
    if (sessionId.isEmpty) return const [];

    final trimmed = query.trim();
    final params = <String, dynamic>{
      'get_all': false,
      'limit': trimmed.length <= 2 ? 300 : limit,
      'offset': 0,
      if (trimmed.isNotEmpty) ...{
        'search': trimmed,
        'medicine': trimmed,
        'medicine_name': trimmed,
        'name': trimmed,
      },
    };

    try {
      final webApi = WebApiImpl();
      final response = await webApi.fetchInvoiceList(
        endpointPath: EndPoint.stockList.path,
        userDetails: ApiRequestHelper.jsonRpcCall(params),
        sessionId: sessionId,
        logResponseBody: false,
        timeout: const Duration(seconds: 45),
      );
      if (response.statusCode != 200) return const [];

      final body = jsonDecode(response.body);
      if (body is! Map<String, dynamic>) return const [];

      var items = StockItemModel.parseList(body);
      if (trimmed.isEmpty) return items;

      var ranked = _rankByQuery(items, trimmed);
      if (ranked.isNotEmpty) return ranked;

      if (trimmed.length <= 2) {
        final broadResponse = await webApi.fetchInvoiceList(
          endpointPath: EndPoint.stockList.path,
          userDetails: ApiRequestHelper.jsonRpcCall({
            'get_all': false,
            'limit': 500,
            'offset': 0,
          }),
          sessionId: sessionId,
          logResponseBody: false,
          timeout: const Duration(seconds: 45),
        );
        if (broadResponse.statusCode == 200) {
          final broadBody = jsonDecode(broadResponse.body);
          if (broadBody is Map<String, dynamic>) {
            items = StockItemModel.parseList(broadBody);
            ranked.addAll(_rankByQuery(items, trimmed));
          }
        }
      }

      return ranked;
    } catch (e) {
      if (kDebugMode) debugPrint('label stock search: $e');
      return const [];
    }
  }

  static Future<List<StockItemModel>> findMatches(
    String sessionId,
    LabelOcrParseResult parsed,
  ) async {
    final queries = parsed.searchQueries.isNotEmpty
        ? parsed.searchQueries
        : <String>[
            if ((parsed.medicineName ?? '').trim().isNotEmpty)
              parsed.medicineName!.trim(),
          ];

    if (queries.isEmpty) return const [];

    final seenId = <int>{};
    final merged = <StockItemModel>[];

    for (final query in queries.take(3)) {
      final batch = await searchStock(sessionId, query);
      for (final item in batch) {
        if (!_itemMatchesQuery(item, query, parsed)) continue;
        final id = item.entryStockId ?? item.stockDisplayId ?? item.stockId;
        if (id != null && !seenId.add(id)) continue;
        merged.add(item);
      }

      if (merged.isNotEmpty) {
        final ranked = rankMatches(merged, parsed);
        if (ranked.isNotEmpty && _scoreItem(ranked.first, parsed) >= 35) {
          if (kDebugMode) {
            debugPrint(
              'label stock match early: query=$query '
              'top=${ranked.first.medicineLabel}',
            );
          }
          return _finalizeRanked(ranked, parsed);
        }
      }
    }

    if (merged.isEmpty) return const [];

    final ranked = rankMatches(merged, parsed);
    if (kDebugMode) {
      debugPrint(
        'label stock match: queries=${queries.join(" | ")} '
        'hits=${ranked.length} top=${ranked.first.medicineLabel}',
      );
    }
    return _finalizeRanked(ranked, parsed);
  }

  static List<StockItemModel> _finalizeRanked(
    List<StockItemModel> ranked,
    LabelOcrParseResult parsed,
  ) {
    final strong =
        ranked.where((item) => _scoreItem(item, parsed) >= 20).toList();
    if (strong.isNotEmpty) return strong.take(30).toList();
    return ranked.take(20).toList();
  }

  static bool _itemMatchesQuery(
    StockItemModel item,
    String query,
    LabelOcrParseResult parsed,
  ) {
    final q = query.toLowerCase().trim();
    final med = item.medicineLabel.toLowerCase();
    if (q.isEmpty) return false;

    if (med.contains(q) || q.contains(med)) return true;

    final qWords = q.split(RegExp(r'\s+')).where((w) => w.length >= 3);
    var hits = 0;
    for (final word in qWords) {
      if (med.contains(word)) hits++;
    }
    if (hits >= 2) return true;
    if (hits == 1 && qWords.length == 1) return true;

    final parsedName = parsed.medicineName?.toLowerCase().trim();
    if (parsedName != null && parsedName.isNotEmpty) {
      if (med.contains(parsedName) || parsedName.contains(med)) return true;
    }

    return _scoreItem(item, parsed) >= 20;
  }

  static int _scoreItem(StockItemModel item, LabelOcrParseResult parsed) {
    var s = 0;
    final name = parsed.medicineName?.toLowerCase().trim();
    final potency = parsed.potency?.toLowerCase().trim();
    final packing = parsed.packing?.toLowerCase().trim();
    final med = item.medicineLabel.toLowerCase();
    final pot = (item.potency ?? '').toLowerCase();
    final pack = (item.packing ?? '').toLowerCase();

    if (name != null && name.isNotEmpty) {
      if (med == name) {
        s += 50;
      } else if (med.startsWith(name)) {
        s += 40;
      } else if (med.contains(name)) {
        s += 25;
      } else if (name.contains(med) && med.length >= 4) {
        s += 15;
      }
    }

    if (potency != null && potency.isNotEmpty && pot.isNotEmpty) {
      if (pot == potency) {
        s += 30;
      } else if (pot.contains(potency) || potency.contains(pot)) {
        s += 15;
      }
    }

    if (packing != null && packing.isNotEmpty && pack.isNotEmpty) {
      if (pack == packing) {
        s += 20;
      } else if (pack.contains(packing) || packing.contains(pack)) {
        s += 10;
      }
    }

    return s;
  }

  static List<StockItemModel> rankMatches(
    List<StockItemModel> items,
    LabelOcrParseResult parsed,
  ) {
    final sorted = [...items]
      ..sort((a, b) => _scoreItem(b, parsed).compareTo(_scoreItem(a, parsed)));
    return sorted;
  }

  static List<String> uniqueMedicines(List<StockItemModel> items) {
    final set = <String>{};
    final out = <String>[];
    for (final item in items) {
      final label = item.medicineLabel.trim();
      if (label.isEmpty || label == 'Unknown') continue;
      if (set.add(label.toUpperCase())) {
        out.add(label);
      }
    }
    out.sort((a, b) => a.compareTo(b));
    return out;
  }

  static List<String> potenciesFor(
    List<StockItemModel> items,
    String medicine,
  ) {
    final med = medicine.trim().toLowerCase();
    final set = <String>{};
    final out = <String>[];
    for (final item in items) {
      if (item.medicineLabel.toLowerCase() != med) continue;
      final pot = (item.potency ?? '').trim();
      if (pot.isEmpty) continue;
      if (set.add(pot.toUpperCase())) out.add(pot);
    }
    out.sort((a, b) => a.compareTo(b));
    return out;
  }

  static List<String> packingsFor(
    List<StockItemModel> items,
    String medicine,
    String? potency,
  ) {
    final med = medicine.trim().toLowerCase();
    final pot = potency?.trim().toLowerCase();
    final set = <String>{};
    final out = <String>[];
    for (final item in items) {
      if (item.medicineLabel.toLowerCase() != med) continue;
      final itemPot = (item.potency ?? '').trim().toLowerCase();
      if (pot != null && pot.isNotEmpty && itemPot != pot) continue;
      final pack = (item.packing ?? '').trim();
      if (pack.isEmpty) continue;
      if (set.add(pack.toUpperCase())) out.add(pack);
    }
    out.sort((a, b) => a.compareTo(b));
    return out;
  }

  static StockItemModel? resolveSelection(
    List<StockItemModel> items, {
    String? medicine,
    String? potency,
    String? packing,
  }) {
    final med = medicine?.trim();
    if (med == null || med.isEmpty) return null;

    final medLower = med.toLowerCase();
    final potLower = potency?.trim().toLowerCase();
    final packLower = packing?.trim().toLowerCase();

    StockItemModel? best;
    var bestScore = -1;

    for (final item in items) {
      if (item.medicineLabel.toLowerCase() != medLower) continue;

      var score = 10;
      final itemPot = (item.potency ?? '').trim().toLowerCase();
      final itemPack = (item.packing ?? '').trim().toLowerCase();

      if (potLower != null && potLower.isNotEmpty) {
        if (itemPot == potLower) {
          score += 5;
        } else {
          continue;
        }
      }

      if (packLower != null && packLower.isNotEmpty) {
        if (itemPack == packLower) {
          score += 5;
        } else {
          continue;
        }
      }

      if (score > bestScore) {
        bestScore = score;
        best = item;
      }
    }

    return best;
  }

  static List<StockItemModel> _rankByQuery(
    List<StockItemModel> items,
    String query,
  ) {
    final q = query.toLowerCase();
    final starts = <StockItemModel>[];
    final contains = <StockItemModel>[];
    for (final item in items) {
      final name = item.medicineLabel.toLowerCase();
      if (name.startsWith(q)) {
        starts.add(item);
      } else if (name.contains(q)) {
        contains.add(item);
      }
    }
    return [...starts, ...contains];
  }
}
