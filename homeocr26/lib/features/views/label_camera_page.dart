import 'dart:typed_data';

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

/// In-app camera for label photos (stays inside the app, no system camera).
class LabelCameraPage extends StatefulWidget {
  const LabelCameraPage({super.key});

  /// Opens the in-app camera and returns JPEG bytes, or null if cancelled.
  static Future<Uint8List?> capture(BuildContext context) {
    return Navigator.of(context).push<Uint8List>(
      MaterialPageRoute<Uint8List>(
        fullscreenDialog: true,
        builder: (_) => const LabelCameraPage(),
      ),
    );
  }

  @override
  State<LabelCameraPage> createState() => _LabelCameraPageState();
}

class _LabelCameraPageState extends State<LabelCameraPage> {
  CameraController? _controller;
  bool _initializing = true;
  bool _capturing = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _initCamera();
  }

  Future<void> _initCamera() async {
    try {
      final cameras = await availableCameras();
      if (cameras.isEmpty) {
        setState(() {
          _error = 'No camera found on this device.';
          _initializing = false;
        });
        return;
      }

      final back = cameras.firstWhere(
        (camera) => camera.lensDirection == CameraLensDirection.back,
        orElse: () => cameras.first,
      );

      final controller = CameraController(
        back,
        ResolutionPreset.medium,
        enableAudio: false,
        imageFormatGroup: ImageFormatGroup.jpeg,
      );

      await controller.initialize();
      if (!mounted) {
        await controller.dispose();
        return;
      }

      setState(() {
        _controller = controller;
        _initializing = false;
      });
    } catch (e, s) {
      if (kDebugMode) debugPrint('label camera init: $e\n$s');
      if (!mounted) return;
      setState(() {
        _error = 'Could not open camera.';
        _initializing = false;
      });
    }
  }

  Future<void> _capture() async {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized || _capturing) {
      return;
    }

    setState(() => _capturing = true);
    try {
      final file = await controller.takePicture();
      final bytes = await file.readAsBytes();
      if (!mounted) return;
      if (bytes.isEmpty) {
        setState(() => _capturing = false);
        return;
      }
      Navigator.of(context).pop(bytes);
    } catch (e, s) {
      if (kDebugMode) debugPrint('label camera capture: $e\n$s');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Could not take photo. Please try again.'),
            duration: Duration(seconds: 2),
          ),
        );
        setState(() => _capturing = false);
      }
    }
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
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
          'Photograph label',
          style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
        ),
      ),
      body: Column(
        children: [
          Expanded(child: _buildPreview()),
          _buildControls(),
        ],
      ),
    );
  }

  Widget _buildPreview() {
    if (_initializing) {
      return const Center(
        child: CircularProgressIndicator(color: Color(0xFFE07A2F)),
      );
    }

    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            _error!,
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.white70, fontSize: 15),
          ),
        ),
      );
    }

    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) {
      return const SizedBox.shrink();
    }

    return Stack(
      fit: StackFit.expand,
      children: [
        ClipRect(
          child: FittedBox(
            fit: BoxFit.cover,
            child: SizedBox(
              width: controller.value.previewSize?.height ?? 1,
              height: controller.value.previewSize?.width ?? 1,
              child: CameraPreview(controller),
            ),
          ),
        ),
        Center(
          child: Container(
            width: MediaQuery.sizeOf(context).width * 0.82,
            height: MediaQuery.sizeOf(context).height * 0.28,
            decoration: BoxDecoration(
              border: Border.all(
                color: const Color(0xFFE07A2F).withValues(alpha: 0.85),
                width: 2,
              ),
              borderRadius: BorderRadius.circular(12),
            ),
          ),
        ),
        Positioned(
          left: 16,
          right: 16,
          bottom: 16,
          child: Text(
            'Align the medicine label inside the frame',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.85),
              fontSize: 13,
              fontWeight: FontWeight.w500,
            ),
          ),
        ),
        if (_capturing)
          Container(
            color: Colors.black.withValues(alpha: 0.35),
            child: const Center(
              child: CircularProgressIndicator(color: Color(0xFFE07A2F)),
            ),
          ),
      ],
    );
  }

  Widget _buildControls() {
    return Container(
      width: double.infinity,
      padding: EdgeInsets.fromLTRB(
        24,
        16,
        24,
        16 + MediaQuery.paddingOf(context).bottom,
      ),
      color: const Color(0xFF1A1A1A),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          TextButton(
            onPressed: _capturing ? null : () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          GestureDetector(
            onTap: _capturing || _error != null ? null : _capture,
            child: Container(
              width: 72,
              height: 72,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(color: Colors.white, width: 4),
              ),
              alignment: Alignment.center,
              child: Container(
                width: 58,
                height: 58,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: _capturing
                      ? Colors.white38
                      : const Color(0xFFE07A2F),
                ),
              ),
            ),
          ),
          const SizedBox(width: 64),
        ],
      ),
    );
  }
}
