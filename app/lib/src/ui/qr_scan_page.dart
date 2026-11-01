import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import 'theme.dart';

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
  bool _handled = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _onDetect(BarcodeCapture capture) {
    if (_handled) return;
    for (final barcode in capture.barcodes) {
      final value = barcode.rawValue;
      if (value == null || value.isEmpty) continue;
      if (value.contains('sid=') && value.contains('hash=')) {
        _handled = true;
        Navigator.of(context).pop(value);
        return;
      }
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
      body: Stack(
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
          Positioned(
            left: 24,
            right: 24,
            bottom: 40,
            child: Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.65),
                borderRadius: BorderRadius.circular(14),
              ),
              child: const Text(
                'Наведи камеру на QR-код из ZCode → «Мобильный доступ». '
                'Ссылка никуда не отправляется: она сохранится только на этом телефоне.',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.white, fontSize: 12.5, height: 1.45),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
