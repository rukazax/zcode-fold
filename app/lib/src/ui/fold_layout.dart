import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';

/// Foldable-screen geometry. Honor Magic V3 and other foldables expose the
/// crease as a `fold` display feature; some report a `hinge` (physical gap).
class FoldInfo {
  FoldInfo({
    required this.size,
    required this.verticalHinge,
    required this.horizontalHinge,
  });

  final Size size;
  final ui.DisplayFeature? verticalHinge;
  final ui.DisplayFeature? horizontalHinge;

  bool get hasVerticalHinge => verticalHinge != null;
  bool get isUnfolded => size.width >= 700 || hasVerticalHinge;
  double get hingeWidth => verticalHinge?.bounds.width ?? 0;

  /// Left pane width when a vertical hinge splits the screen.
  double get leftPaneWidth {
    final h = verticalHinge;
    if (h == null) return 0;
    return h.bounds.left.clamp(240.0, size.width - 240.0);
  }

  static FoldInfo of(BuildContext context) {
    final media = MediaQuery.of(context);
    ui.DisplayFeature? vertical;
    ui.DisplayFeature? horizontal;
    for (final feature in media.displayFeatures) {
      final isFold = feature.type == ui.DisplayFeatureType.fold ||
          feature.type == ui.DisplayFeatureType.hinge;
      if (!isFold) continue;
      final b = feature.bounds;
      if (b.width <= b.height) {
        vertical ??= feature;
      } else {
        horizontal ??= feature;
      }
    }
    return FoldInfo(
      size: media.size,
      verticalHinge: vertical,
      horizontalHinge: horizontal,
    );
  }
}
