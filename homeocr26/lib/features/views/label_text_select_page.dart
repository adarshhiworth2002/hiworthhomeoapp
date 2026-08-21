import 'dart:math';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../services/label_ocr_recognition.dart';
import '../services/label_ocr_service.dart';
import '../theme.dart';

/// Google Lens–style screen: photo with selectable OCR text overlays.
class LabelTextSelectPage extends StatefulWidget {
  const LabelTextSelectPage({
    super.key,
    required this.imageBytes,
    this.recognition,
    this.recognitionFuture,
  });

  final Uint8List imageBytes;
  final LabelOcrRecognitionResult? recognition;
  final Future<LabelOcrRecognitionResult>? recognitionFuture;

  /// Opens the picker and returns the user-selected text, or null if cancelled.
  static Future<String?> show(
    BuildContext context, {
    required Uint8List imageBytes,
    LabelOcrRecognitionResult? recognition,
    Future<LabelOcrRecognitionResult>? recognitionFuture,
  }) {
    return Navigator.of(context).push<String>(
      MaterialPageRoute<String>(
        fullscreenDialog: true,
        builder: (_) => LabelTextSelectPage(
          imageBytes: imageBytes,
          recognition: recognition,
          recognitionFuture: recognitionFuture ??
              (recognition == null
                  ? LabelOcrService.recognizeImageBytesDetailed(imageBytes)
                  : null),
        ),
      ),
    );
  }

  @override
  State<LabelTextSelectPage> createState() => _LabelTextSelectPageState();
}

class _LabelTextSelectPageState extends State<LabelTextSelectPage> {
  final Set<int> _selectedIds = {};
  final TextEditingController _textController = TextEditingController();
  final FocusNode _textFocus = FocusNode();
  int? _dragAnchorOrder;
  LabelOcrTextElement? _dragAnchorElement;
  Offset? _dragCurrent;
  Offset? _dragStart;
  bool _didDrag = false;

  LabelOcrRecognitionResult? _recognition;
  ui.Size _imageSize = ui.Size.zero;
  bool _ocrLoading = false;
  String? _ocrError;

  List<LabelOcrTextElement> get _elements => _recognition?.elements ?? const [];

  String get _selectedText {
    final selected = _elements
        .where((e) => _selectedIds.contains(e.id))
        .toList()
      ..sort((a, b) => a.readingOrder.compareTo(b.readingOrder));
    return selected.map((e) => e.text).join(' ').trim();
  }

  @override
  void initState() {
    super.initState();
    _recognition = widget.recognition;
    if (_recognition != null) {
      _imageSize = _recognition!.imageSize;
    } else {
      _ocrLoading = true;
      _loadImageSize();
      _runOcr();
    }
    _textFocus.addListener(_onTextFocusChanged);
  }

  @override
  void dispose() {
    _textFocus.removeListener(_onTextFocusChanged);
    _textFocus.dispose();
    _textController.dispose();
    super.dispose();
  }

  void _onTextFocusChanged() {
    if (!_textFocus.hasFocus) {
      _syncTextFromSelection();
    }
  }

  void _syncTextFromSelection() {
    if (_textFocus.hasFocus) return;
    final text = _selectedText;
    if (_textController.text != text) {
      _textController.text = text;
      _textController.selection = TextSelection.collapsed(
        offset: _textController.text.length,
      );
    }
  }

  Future<void> _loadImageSize() async {
    try {
      final codec = await ui.instantiateImageCodec(widget.imageBytes);
      final frame = await codec.getNextFrame();
      final image = frame.image;
      final size = ui.Size(image.width.toDouble(), image.height.toDouble());
      image.dispose();
      if (!mounted) return;
      setState(() => _imageSize = size);
    } catch (_) {}
  }

  Future<void> _runOcr() async {
    final future = widget.recognitionFuture;
    if (future == null) return;

    try {
      final result = await future;
      if (!mounted) return;
      setState(() {
        _recognition = result;
        _imageSize = result.imageSize;
        _ocrLoading = false;
        if (!result.hasElements && result.fullText.trim().isEmpty) {
          _ocrError = 'No text found on this photo.';
        }
      });
    } catch (e, s) {
      if (kDebugMode) debugPrint('label OCR in select page: $e\n$s');
      if (!mounted) return;
      setState(() {
        _ocrLoading = false;
        _ocrError = 'Could not read text from the photo.';
      });
    }
  }

  void _toggleElement(LabelOcrTextElement element) {
    setState(() {
      if (_selectedIds.contains(element.id)) {
        _selectedIds.remove(element.id);
      } else {
        _selectedIds.add(element.id);
      }
      _syncTextFromSelection();
    });
  }

  void _selectRange(int fromOrder, int toOrder) {
    final a = min(fromOrder, toOrder);
    final b = max(fromOrder, toOrder);
    setState(() {
      for (final element in _elements) {
        if (element.readingOrder >= a && element.readingOrder <= b) {
          _selectedIds.add(element.id);
        }
      }
      _syncTextFromSelection();
    });
  }

  LabelOcrTextElement? _hitTest(
    Offset displayPoint,
    LabelOcrCoordinateMapper mapper,
  ) {
    if (_ocrLoading || _ocrError != null) return null;
    if (!mapper.containsDisplayPoint(displayPoint)) return null;

    LabelOcrTextElement? best;
    var bestArea = double.infinity;

    for (final element in _elements) {
      final rect = mapper.elementToDisplay(element.bounds);
      if (!rect.contains(displayPoint)) continue;
      final area = rect.width * rect.height;
      if (area < bestArea) {
        bestArea = area;
        best = element;
      }
    }
    return best;
  }

  void _onPanStart(
    DragStartDetails details,
    LabelOcrCoordinateMapper mapper,
  ) {
    if (_ocrLoading || _ocrError != null) return;
    final hit = _hitTest(details.localPosition, mapper);
    setState(() {
      _dragStart = details.localPosition;
      _dragCurrent = details.localPosition;
      _didDrag = false;
      _dragAnchorElement = hit;
      _dragAnchorOrder = hit?.readingOrder;
    });
  }

  void _onPanUpdate(
    DragUpdateDetails details,
    LabelOcrCoordinateMapper mapper,
  ) {
    if (_ocrLoading || _ocrError != null) return;
    if (_dragStart != null &&
        (details.localPosition - _dragStart!).distance > 8) {
      _didDrag = true;
    }

    setState(() {
      _dragCurrent = details.localPosition;
      if (_didDrag && _dragAnchorOrder != null) {
        final hit = _hitTest(details.localPosition, mapper);
        if (hit != null) {
          _selectedIds.clear();
          _selectRange(_dragAnchorOrder!, hit.readingOrder);
        }
      }
    });
  }

  void _onPanEnd(LabelOcrCoordinateMapper mapper) {
    if (_ocrLoading || _ocrError != null) return;
    if (!_didDrag && _dragAnchorElement != null) {
      _toggleElement(_dragAnchorElement!);
    }
    setState(() {
      _dragStart = null;
      _dragCurrent = null;
      _dragAnchorOrder = null;
      _dragAnchorElement = null;
      _didDrag = false;
    });
  }

  void _clearSelection() {
    setState(() {
      _selectedIds.clear();
      _syncTextFromSelection();
    });
  }

  void _onDone() {
    if (_ocrLoading) return;

    if (_ocrError != null) {
      Navigator.of(context).pop();
      return;
    }

    var text = _textController.text.trim();
    if (text.isEmpty) {
      text = _selectedText;
    }
    if (text.isEmpty && (_recognition?.fullText.trim().isNotEmpty ?? false)) {
      text = _recognition!.fullText.trim();
    }

    if (text.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Drag or tap words on the label to select text.'),
          duration: Duration(seconds: 2),
        ),
      );
      return;
    }
    Navigator.of(context).pop(text);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        elevation: 0,
        title: const Text(
          'Select label text',
          style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
        ),
        actions: [
          if (_selectedIds.isNotEmpty && !_ocrLoading)
            TextButton(
              onPressed: _clearSelection,
              child: const Text('Clear'),
            ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) {
                final viewSize = Size(constraints.maxWidth, constraints.maxHeight);
                final imageSize = _imageSize.width > 0 && _imageSize.height > 0
                    ? _imageSize
                    : viewSize;
                final mapper = LabelOcrCoordinateMapper(
                  imageSize: imageSize,
                  viewSize: viewSize,
                );

                return GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onPanStart: (d) => _onPanStart(d, mapper),
                  onPanUpdate: (d) => _onPanUpdate(d, mapper),
                  onPanEnd: (_) => _onPanEnd(mapper),
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      Center(
                        child: SizedBox(
                          width: mapper.imageDisplayRect.width,
                          height: mapper.imageDisplayRect.height,
                          child: Image.memory(
                            widget.imageBytes,
                            fit: BoxFit.fill,
                            gaplessPlayback: true,
                          ),
                        ),
                      ),
                      if (!_ocrLoading && _ocrError == null)
                        ..._buildOverlays(mapper),
                      if (_dragStart != null && _dragCurrent != null)
                        Positioned.fromRect(
                          rect: Rect.fromPoints(_dragStart!, _dragCurrent!),
                          child: IgnorePointer(
                            child: DecoratedBox(
                              decoration: BoxDecoration(
                                border: Border.all(
                                  color: const Color(0xFFE07A2F),
                                  width: 1.5,
                                ),
                                color: const Color(0xFFE07A2F)
                                    .withValues(alpha: 0.12),
                              ),
                            ),
                          ),
                        ),
                      if (_ocrLoading) _buildOcrLoading(),
                      if (_ocrError != null) _buildOcrError(),
                    ],
                  ),
                );
              },
            ),
          ),
          _buildBottomBar(),
        ],
      ),
    );
  }

  Widget _buildOcrLoading() {
    return Container(
      color: Colors.black.withValues(alpha: 0.35),
      child: const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(color: Color(0xFFE07A2F)),
            SizedBox(height: 12),
            Text(
              'Reading label text…',
              style: TextStyle(
                color: Colors.white,
                fontSize: 16,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildOcrError() {
    return Container(
      color: Colors.black.withValues(alpha: 0.5),
      padding: const EdgeInsets.all(24),
      child: Center(
        child: Text(
          _ocrError!,
          textAlign: TextAlign.center,
          style: const TextStyle(color: Colors.white, fontSize: 17),
        ),
      ),
    );
  }

  List<Widget> _buildOverlays(LabelOcrCoordinateMapper mapper) {
    return [
      for (final element in _elements)
        Positioned.fromRect(
          rect: mapper.elementToDisplay(element.bounds).inflate(2),
          child: IgnorePointer(
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: _selectedIds.contains(element.id)
                    ? const Color(0xFFE07A2F).withValues(alpha: 0.55)
                    : Colors.white.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(3),
                border: Border.all(
                  color: _selectedIds.contains(element.id)
                      ? const Color(0xFFE07A2F)
                      : Colors.white.withValues(alpha: 0.25),
                  width: _selectedIds.contains(element.id) ? 1.5 : 0.5,
                ),
              ),
            ),
          ),
        ),
    ];
  }

  Widget _buildBottomBar() {
    final selectedText = _selectedText;
    final hasText = _textController.text.trim().isNotEmpty || selectedText.isNotEmpty;
    final hint = _ocrLoading
        ? 'Reading text from photo…'
        : (_ocrError != null
            ? _ocrError!
            : 'Drag across words on the photo, or tap to select');

    return Container(
      width: double.infinity,
      padding: EdgeInsets.fromLTRB(
        16,
        12,
        16,
        12 + MediaQuery.paddingOf(context).bottom,
      ),
      decoration: BoxDecoration(
        color: sectionBg,
        border: Border(
          top: BorderSide(color: sectionCard),
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.4),
            blurRadius: 12,
            offset: const Offset(0, -4),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text(
            'Selected text',
            style: TextStyle(
              color: sectionTextMuted,
              fontSize: 14,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 8),
          Container(
            constraints: const BoxConstraints(minHeight: 44, maxHeight: 88),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: sectionCard,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(
                color: hasText
                    ? const Color(0xFFE07A2F).withValues(alpha: 0.7)
                    : sectionCardBorder,
              ),
            ),
            child: TextField(
              controller: _textController,
              focusNode: _textFocus,
              enabled: !_ocrLoading && _ocrError == null,
              maxLines: 3,
              minLines: 1,
              style: const TextStyle(
                color: sectionText,
                fontSize: 17,
                fontWeight: FontWeight.w700,
                height: 1.3,
              ),
              decoration: InputDecoration(
                hintText: hint,
                hintStyle: const TextStyle(
                  color: sectionTextMuted,
                  fontSize: 17,
                  fontWeight: FontWeight.w500,
                ),
                border: InputBorder.none,
                isDense: true,
                contentPadding: EdgeInsets.zero,
              ),
              cursorColor: const Color(0xFFE07A2F),
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: () => Navigator.of(context).pop(),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: sectionText,
                    side: const BorderSide(color: sectionCardBorder),
                    backgroundColor: sectionCard,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                  ),
                  child: const Text(
                    'Cancel',
                    style: TextStyle(fontWeight: FontWeight.w700),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                flex: 2,
                child: FilledButton(
                  onPressed: _ocrLoading ? null : _onDone,
                  style: FilledButton.styleFrom(
                    backgroundColor: const Color(0xFFE07A2F),
                    foregroundColor: Colors.white,
                    disabledBackgroundColor:
                        const Color(0xFFE07A2F).withValues(alpha: 0.45),
                    disabledForegroundColor: Colors.white70,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                  ),
                  child: _ocrLoading
                      ? const SizedBox(
                          height: 20,
                          width: 20,
                          child: CircularProgressIndicator(
                            color: Colors.white,
                            strokeWidth: 2.5,
                          ),
                        )
                      : Text(
                          _ocrError != null ? 'Close' : 'Done',
                          style: const TextStyle(fontWeight: FontWeight.w700),
                        ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
