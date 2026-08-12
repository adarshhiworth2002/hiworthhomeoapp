import 'dart:ui';

/// One OCR word/element with bounds in original image pixel coordinates.
class LabelOcrTextElement {
  const LabelOcrTextElement({
    required this.id,
    required this.text,
    required this.bounds,
    required this.readingOrder,
  });

  final int id;
  final String text;
  final Rect bounds;
  final int readingOrder;
}

/// Full OCR output for interactive label selection.
class LabelOcrRecognitionResult {
  const LabelOcrRecognitionResult({
    required this.fullText,
    required this.imageSize,
    required this.elements,
  });

  final String fullText;
  final Size imageSize;
  final List<LabelOcrTextElement> elements;

  bool get hasElements => elements.isNotEmpty;
}

/// Maps between image pixel space and on-screen [BoxFit.contain] layout.
class LabelOcrCoordinateMapper {
  LabelOcrCoordinateMapper({
    required this.imageSize,
    required this.viewSize,
  }) : _fitted = _fitContain(imageSize, viewSize);

  final Size imageSize;
  final Size viewSize;
  final _FittedImage _fitted;

  Rect get imageDisplayRect => _fitted.rect;

  Rect elementToDisplay(Rect imageBounds) {
    return Rect.fromLTWH(
      _fitted.rect.left + imageBounds.left * _fitted.scale,
      _fitted.rect.top + imageBounds.top * _fitted.scale,
      imageBounds.width * _fitted.scale,
      imageBounds.height * _fitted.scale,
    );
  }

  Offset displayToImage(Offset displayPoint) {
    final local = Offset(
      displayPoint.dx - _fitted.rect.left,
      displayPoint.dy - _fitted.rect.top,
    );
    return Offset(
      local.dx / _fitted.scale,
      local.dy / _fitted.scale,
    );
  }

  bool containsDisplayPoint(Offset displayPoint) {
    return _fitted.rect.contains(displayPoint);
  }

  static _FittedImage _fitContain(Size imageSize, Size viewSize) {
    if (imageSize.width <= 0 || imageSize.height <= 0) {
      return _FittedImage(Rect.zero, 1);
    }
    final scaleW = viewSize.width / imageSize.width;
    final scaleH = viewSize.height / imageSize.height;
    final scale = scaleW < scaleH ? scaleW : scaleH;
    final fittedW = imageSize.width * scale;
    final fittedH = imageSize.height * scale;
    final left = (viewSize.width - fittedW) / 2;
    final top = (viewSize.height - fittedH) / 2;
    return _FittedImage(Rect.fromLTWH(left, top, fittedW, fittedH), scale);
  }
}

class _FittedImage {
  const _FittedImage(this.rect, this.scale);
  final Rect rect;
  final double scale;
}
