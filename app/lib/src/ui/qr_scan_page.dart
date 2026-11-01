import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import 'theme.dart';

/// Scans the ZCode pairing QR code. Two ways in: live camera, or a QR image
/// from the gallery (useful when the phone shows the code on a second screen
/// or for automated tests).
class QrScanPage extends StatefulWidget {
  const QrScanPage({super.key});

  @override
  State<QrScanPage> createState() => _QrScanPageState();
}

class _QrScanPageState extends State<QrScanPage> {
  final _controller = MobileScannerController(
    detectionSpeed: DetectionSpeed.noDuplicates,
    formats: const [BarcodeFormat.qrCode],
  );
  final _picker = ImagePicker();
  bool _handled = false;
  bool _importing = false;
  String _hint = 'Наведи камеру на QR-код из ZCode → «Мобильный доступ». '
      'Ссылка никуда не отправляется: она сохранится только на этом телефоне.';
  Color _hintColor = Colors.white;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  bool _isPairingLink(String value) =>
      (value.contains('sid=') && value.contains('hash=')) ||
      (value.contains('sid=') && value.contains('remote/v4'));

  void _onDetect(BarcodeCapture capture) {
    if (_handled) return;
    for (final barcode in capture.barcodes) {
      final value = barcode.rawValue;
      if (value == null || value.isEmpty) continue;
      if (_isPairingLink(value)) {
        _handled = true;
        Navigator.of(context).pop(value);
        return;
      }
    }
  }

  Future<void> _fromGallery() async {
    if (_importing || _handled) return;
    setState(() {
      _importing = true;
      _hint = 'Читаю картинку…';
      _hintColor = Colors.white;
    });
    try {
      final file = await _picker.pickImage(source: ImageSource.gallery, imageQuality: 100);
      if (file == null) {
        setState(() {
          _importing = false;
          _hint = 'Картинка не выбрана — сфотографируй QR или выбери файл из галереи.';
        });
        return;
      }
      final capture = await _controller.analyzeImage(
        file.path,
        formats: const [BarcodeFormat.qrCode],
      );
      String? value;
      final codes = (capture?.barcodes ?? const [])
          .map((b) => b.rawValue)
          .whereType<String>()
          .where((v) => v.isNotEmpty);
      for (final v in codes) {
        final isBridge =
            v.startsWith('http://') &&
            v.isNotEmpty &&
            !v.startsWith('http://localhost/remote') &&
            Uri.tryParse(v)?.path != '/remote/v4';
        if (_isPairingLink(v) || isBridge) {
          _handled = true;
          if (mounted && context.mounted) Navigator.of(context).pop(v);
          return;
        }
        value ??= v;
      }
      if (!mounted) return;
      setState(() {
        _importing = false;
        _hint = codes.isEmpty
            ? 'QR-код на картинке не найден. Сними экран целиком, без обрезки и без бликов.'
            : 'QR найден, но это не ссылка ZCode Remote (нет sid/hash).';
        _hintColor = const Color(0xFFFFB4AD);
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _importing = false;
        _hint = 'Не удалось разобрать картинку: $e';
        _hintColor = const Color(0xFFFFB4AD);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: const Text('QR-код ZCode'),
        backgroundColor: Colors.black,
        actions: [
          IconButton(
            tooltip: 'Фонарик',
            onPressed: () => _controller.toggleTorch(),
            icon: const Icon(Icons.flash_on_rounded),
          ),
          IconButton(
            tooltip: 'Сменить камеру',
            onPressed: () => _controller.switchCamera(),
            icon: const Icon(Icons.cameraswitch_rounded),
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: Stack(
              fit: StackFit.expand,
              children: [
                MobileScanner(controller: _controller, onDetect: _onDetect),
                IgnorePointer(
                  child: Center(
                    child: Container(
                      width: 240,
                      height: 240,
                      decoration: BoxDecoration(
                        border: Border.all(color: kAccent, width: 3),
                        borderRadius: BorderRadius.circular(26),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 6),
            child: Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _importing || _handled ? null : _fromGallery,
                    icon: _importing
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Icons.image_outlined, size: 18),
                    label: const Text('QR из картинки'),
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 4, 24, 28),
            child: Text(
              _hint,
              textAlign: TextAlign.center,
              style: TextStyle(color: _hintColor, fontSize: 12.5, height: 1.45),
            ),
          ),
        ],
      ),
    );
  }
}
