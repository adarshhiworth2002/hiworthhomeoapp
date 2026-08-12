import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:path_provider/path_provider.dart';

import 'label_ocr_recognition.dart';

/// Runs ML Kit text recognition on a camera frame (JPEG or PNG).
class LabelOcrService {
  LabelOcrService._();

  static final TextRecognizer _recognizer = TextRecognizer();

  static Future<LabelOcrRecognitionResult> recognizeImageBytesDetailed(
    Uint8List bytes,
  ) async {
    if (bytes.isEmpty) {
      return const LabelOcrRecognitionResult(
        fullText: '',
        imageSize: ui.Size.zero,
        elements: [],
      );
    }

    final imageSize = await _decodeImageSize(bytes);
    final ext = _looksLikeJpeg(bytes) ? 'jpg' : 'png';
    final tempDir = await getTemporaryDirectory();
    final file = File(
      '${tempDir.path}/label_ocr_${DateTime.now().millisecondsSinceEpoch}.$ext',
    );
    await file.writeAsBytes(bytes, flush: true);

    try {
      final inputImage = InputImage.fromFilePath(file.path);
      final recognized = await _recognizer.processImage(inputImage);
      final text = recognized.text.trim();
      final elements = _extractElements(recognized);
      if (kDebugMode) {
        debugPrint(
          'label OCR recognized (${text.length} chars, '
          '${elements.length} elements)',
        );
      }
      return LabelOcrRecognitionResult(
        fullText: text,
        imageSize: imageSize,
        elements: elements,
      );
    } catch (e, s) {
      if (kDebugMode) {
        debugPrint('label OCR processImage failed: $e\n$s');
      }
      rethrow;
    } finally {
      if (await file.exists()) {
        await file.delete();
      }
    }
  }

  static Future<String> recognizeImageBytes(Uint8List bytes) async {
    final result = await recognizeImageBytesDetailed(bytes);
    return result.fullText;
  }

  static List<LabelOcrTextElement> _extractElements(RecognizedText recognized) {
    final out = <LabelOcrTextElement>[];
    var id = 0;

    for (final block in recognized.blocks) {
      for (final line in block.lines) {
        for (final element in line.elements) {
          final word = element.text.trim();
          if (word.isEmpty) continue;
          final box = element.boundingBox;
          out.add(
            LabelOcrTextElement(
              id: id++,
              text: word,
              bounds: box,
              readingOrder: id,
            ),
          );
        }
      }
    }

    if (out.isEmpty) {
      for (final block in recognized.blocks) {
        for (final line in block.lines) {
          final lineText = line.text.trim();
          if (lineText.isEmpty) continue;
          final box = line.boundingBox;
          out.add(
            LabelOcrTextElement(
              id: id++,
              text: lineText,
              bounds: box,
              readingOrder: id,
            ),
          );
        }
      }
    }

    out.sort((a, b) {
      final dy = a.bounds.top.compareTo(b.bounds.top);
      if (dy != 0) return dy;
      return a.bounds.left.compareTo(b.bounds.left);
    });

    return [
      for (var i = 0; i < out.length; i++)
        LabelOcrTextElement(
          id: out[i].id,
          text: out[i].text,
          bounds: out[i].bounds,
          readingOrder: i,
        ),
    ];
  }

  static Future<ui.Size> _decodeImageSize(Uint8List bytes) async {
    final codec = await ui.instantiateImageCodec(bytes);
    final frame = await codec.getNextFrame();
    final image = frame.image;
    final size = ui.Size(image.width.toDouble(), image.height.toDouble());
    image.dispose();
    return size;
  }

  @Deprecated('Use recognizeImageBytes')
  static Future<String> recognizeJpeg(Uint8List jpegBytes) =>
      recognizeImageBytes(jpegBytes);

  static bool _looksLikeJpeg(Uint8List bytes) {
    return bytes.length >= 3 &&
        bytes[0] == 0xFF &&
        bytes[1] == 0xD8 &&
        bytes[2] == 0xFF;
  }

  static Future<void> dispose() async {
    await _recognizer.close();
  }
}
