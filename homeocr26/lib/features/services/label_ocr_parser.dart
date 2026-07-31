/// Parses OCR text from medicine labels into name, potency, and packing.
class LabelOcrParseResult {
  const LabelOcrParseResult({
    required this.rawText,
    this.medicineName,
    this.potency,
    this.packing,
    this.searchQueries = const [],
  });

  final String rawText;
  final String? medicineName;
  final String? potency;
  final String? packing;
  final List<String> searchQueries;

  bool get hasAnyField =>
      (medicineName?.trim().isNotEmpty ?? false) ||
      (potency?.trim().isNotEmpty ?? false) ||
      (packing?.trim().isNotEmpty ?? false) ||
      searchQueries.isNotEmpty;
}

class LabelOcrParser {
  static final RegExp _potencyPattern = RegExp(
    r'\b(\d+\s*/\s*\d+|\d+\s*(?:CH|C|X|M|LM|D|DH|DIL))\b',
    caseSensitive: false,
  );

  static final RegExp _packingPattern = RegExp(
    r'\b(\d+(?:\.\d+)?\s*(?:ML|MG|GM|G|TAB|TABLETS?|CAPS?(?:ULES?)?|PCS?))\b',
    caseSensitive: false,
  );

  static final RegExp _noiseLine = RegExp(
    r'\b(MFG|EXP|BATCH|B\.?NO|LOT|MRp|MRP|RS\.?|INR|UID|BK_|STOCK|QTY)\b',
    caseSensitive: false,
  );

  static final RegExp _uiNoise = RegExp(
    r'(search\s+for|brands?\s+and\s+more|products?|medicines?|q\s+sear|'
    r'click\s+here|add\s+to\s+cart|www\.|https?://|\.com\b|offers?|discount)',
    caseSensitive: false,
  );

  static LabelOcrParseResult parse(String rawText) {
    final text = rawText.replaceAll('\r', '\n').trim();
    if (text.isEmpty) {
      return const LabelOcrParseResult(rawText: '');
    }

    String? potency;
    String? packing;
    final potencyMatch = _potencyPattern.firstMatch(text);
    if (potencyMatch != null) {
      potency = _normalizeToken(potencyMatch.group(1)!);
    }

    final packingMatch = _packingPattern.firstMatch(text);
    if (packingMatch != null) {
      packing = _normalizePacking(packingMatch.group(1)!);
    }

    final lines = text
        .split('\n')
        .map((l) => l.trim())
        .where((l) => l.length >= 2)
        .toList();

    final medicineName = _extractMedicineName(lines);
    final searchQueries = _buildSearchQueries(lines, medicineName);

    return LabelOcrParseResult(
      rawText: text,
      medicineName: medicineName,
      potency: potency,
      packing: packing,
      searchQueries: searchQueries,
    );
  }

  static String? _extractMedicineName(List<String> lines) {
    final botanicalRuns = <String>[];
    final buffer = <String>[];

    void flush() {
      if (buffer.isEmpty) return;
      botanicalRuns.add(_normalizeToken(buffer.join(' ')));
      buffer.clear();
    }

    for (final line in lines) {
      if (_isBotanicalLine(line)) {
        buffer.add(line.trim().toUpperCase());
      } else {
        flush();
      }
    }
    flush();

    botanicalRuns.sort((a, b) => _medicineLineScore(b).compareTo(_medicineLineScore(a)));

    for (final candidate in botanicalRuns) {
      if (candidate.length >= 4 && !_isUiNoise(candidate)) {
        return candidate;
      }
    }

    final scored = lines
        .where((l) => l.length >= 4 && !_isUiNoise(l) && !_noiseLine.hasMatch(l))
        .toList()
      ..sort((a, b) => _medicineLineScore(b).compareTo(_medicineLineScore(a)));

    if (scored.isNotEmpty) {
      return _normalizeToken(scored.first);
    }

    return null;
  }

  static List<String> _buildSearchQueries(
    List<String> lines,
    String? medicineName,
  ) {
    final out = <String>[];
    final seen = <String>{};

    void add(String? value) {
      final trimmed = value?.trim();
      if (trimmed == null || trimmed.length < 3) return;
      if (_isUiNoise(trimmed)) return;
      final key = trimmed.toLowerCase();
      if (!seen.add(key)) return;
      out.add(trimmed);
    }

    add(medicineName);

    if (medicineName != null) {
      final words = medicineName.split(RegExp(r'\s+'));
      if (words.length >= 2) {
        add(words.first);
      }
    }

    for (final line in lines) {
      if (!_isBotanicalLine(line)) continue;
      add(line);
      if (out.length >= 3) break;
    }

    return out.take(3).toList();
  }

  static bool _isBotanicalLine(String line) {
    final t = line.trim().toUpperCase();
    if (t.length < 3 || t.length > 40) return false;
    if (_isUiNoise(t)) return false;
    if (_noiseLine.hasMatch(t)) return false;
    if (_packingPattern.hasMatch(t) && t.length < 10) return false;

    final compact = t.replaceAll(RegExp(r'[^A-Z]'), '');
    if (compact.length < 3) return false;

    final letters = RegExp(r'[A-Z]').allMatches(t).length;
    final digits = RegExp(r'\d').allMatches(t).length;
    if (digits > letters) return false;

    return letters >= t.replaceAll(' ', '').length * 0.7;
  }

  static bool _isUiNoise(String line) {
    if (_uiNoise.hasMatch(line)) return true;
    if (line.split(RegExp(r'\s+')).length > 6) return true;
    return false;
  }

  static String _normalizeToken(String value) {
    return value.replaceAll(RegExp(r'\s+'), ' ').trim().toUpperCase();
  }

  static int _medicineLineScore(String line) {
    if (_isUiNoise(line)) return 0;
    final letters = RegExp(r'[A-Za-z]').allMatches(line).length;
    final digits = RegExp(r'\d').allMatches(line).length;
    if (letters == 0) return 0;
    var score = letters * 10 + line.length - digits * 8;
    if (line.contains(' ')) score += 8;
    return score;
  }

  static String _normalizePacking(String value) {
    return value
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim()
        .toUpperCase()
        .replaceAll(RegExp(r'\bGMS\b'), 'GM')
        .replaceAll(RegExp(r'\bTABLETS\b'), 'TAB')
        .replaceAll(RegExp(r'\bCAPSULES\b'), 'CAP')
        .replaceAll(RegExp(r'\bCAPS\b'), 'CAP');
  }
}
