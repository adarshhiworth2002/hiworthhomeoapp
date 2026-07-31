import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:path_provider/path_provider.dart';

/// Runs ML Kit text recognition on a camera frame (JPEG or PNG).
class LabelOcrService {
  LabelOcrService._();

  static final TextRecognizer _recognizer = TextRecognizer();

  static Future<String> recognizeImageBytes(Uint8List bytes) async {
    if (bytes.isEmpty) return '';

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
      if (kDebugMode) {
        debugPrint('label OCR recognized (${text.length} chars): $text');
      }
      return text;
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
