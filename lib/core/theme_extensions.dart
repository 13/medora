/// Medora - Semantic colors on top of the Material 3 ColorScheme.
library;

import 'package:flutter/material.dart';
import 'package:material_color_utilities/material_color_utilities.dart';

@immutable
class MedoraColors extends ThemeExtension<MedoraColors> {
  const MedoraColors({
    required this.success, required this.onSuccess, required this.successContainer, required this.onSuccessContainer,
    required this.warning, required this.onWarning, required this.warningContainer, required this.onWarningContainer,
    required this.danger, required this.onDanger, required this.dangerContainer, required this.onDangerContainer,
    required this.neutral, required this.onNeutral, required this.neutralContainer, required this.onNeutralContainer,
  });

  final Color success, onSuccess, successContainer, onSuccessContainer;
  final Color warning, onWarning, warningContainer, onWarningContainer;
  final Color danger, onDanger, dangerContainer, onDangerContainer;
  final Color neutral, onNeutral, neutralContainer, onNeutralContainer;

  Color get doseTaken => success;
  Color get doseSkipped => warning;
  Color get doseMissed => danger;
  Color get dosePending => neutral;
  Color get expiringSoon => warning;
  Color get expired => danger;
  Color get lowStock => warning;
  Color get inStock => success;

  static const _successSeed = Color(0xFF2E7D32);
  static const _warningSeed = Color(0xFFF57C00);
  static const _dangerSeed = Color(0xFFD32F2F);
  static const _neutralSeed = Color(0xFF607D8B);

  static Color _harmonize(Color seed, Color withColor) {
    return Color(Blend.harmonize(seed.toARGB32(), withColor.toARGB32()));
  }

  factory MedoraColors.forScheme(ColorScheme scheme) {
    ColorScheme role(Color seed) => ColorScheme.fromSeed(
          seedColor: _harmonize(seed, scheme.primary),
          brightness: scheme.brightness,
        );
    final s = role(_successSeed), w = role(_warningSeed), d = role(_dangerSeed), n = role(_neutralSeed);
    return MedoraColors(
      success: s.primary, onSuccess: s.onPrimary, successContainer: s.primaryContainer, onSuccessContainer: s.onPrimaryContainer,
      warning: w.primary, onWarning: w.onPrimary, warningContainer: w.primaryContainer, onWarningContainer: w.onPrimaryContainer,
      danger: d.primary, onDanger: d.onPrimary, dangerContainer: d.primaryContainer, onDangerContainer: d.onPrimaryContainer,
      neutral: n.primary, onNeutral: n.onPrimary, neutralContainer: n.primaryContainer, onNeutralContainer: n.onPrimaryContainer,
    );
  }

  @override
  MedoraColors copyWith({
    Color? success, Color? onSuccess, Color? successContainer, Color? onSuccessContainer,
    Color? warning, Color? onWarning, Color? warningContainer, Color? onWarningContainer,
    Color? danger, Color? onDanger, Color? dangerContainer, Color? onDangerContainer,
    Color? neutral, Color? onNeutral, Color? neutralContainer, Color? onNeutralContainer,
  }) {
    return MedoraColors(
      success: success ?? this.success, onSuccess: onSuccess ?? this.onSuccess,
      successContainer: successContainer ?? this.successContainer, onSuccessContainer: onSuccessContainer ?? this.onSuccessContainer,
      warning: warning ?? this.warning, onWarning: onWarning ?? this.onWarning,
      warningContainer: warningContainer ?? this.warningContainer, onWarningContainer: onWarningContainer ?? this.onWarningContainer,
      danger: danger ?? this.danger, onDanger: onDanger ?? this.onDanger,
      dangerContainer: dangerContainer ?? this.dangerContainer, onDangerContainer: onDangerContainer ?? this.onDangerContainer,
      neutral: neutral ?? this.neutral, onNeutral: onNeutral ?? this.onNeutral,
      neutralContainer: neutralContainer ?? this.neutralContainer, onNeutralContainer: onNeutralContainer ?? this.onNeutralContainer,
    );
  }

  @override
  MedoraColors lerp(ThemeExtension<MedoraColors>? other, double t) {
    if (other is! MedoraColors) return this;
    Color l(Color a, Color b) => Color.lerp(a, b, t)!;
    return MedoraColors(
      success: l(success, other.success), onSuccess: l(onSuccess, other.onSuccess),
      successContainer: l(successContainer, other.successContainer), onSuccessContainer: l(onSuccessContainer, other.onSuccessContainer),
      warning: l(warning, other.warning), onWarning: l(onWarning, other.onWarning),
      warningContainer: l(warningContainer, other.warningContainer), onWarningContainer: l(onWarningContainer, other.onWarningContainer),
      danger: l(danger, other.danger), onDanger: l(onDanger, other.onDanger),
      dangerContainer: l(dangerContainer, other.dangerContainer), onDangerContainer: l(onDangerContainer, other.onDangerContainer),
      neutral: l(neutral, other.neutral), onNeutral: l(onNeutral, other.onNeutral),
      neutralContainer: l(neutralContainer, other.neutralContainer), onNeutralContainer: l(onNeutralContainer, other.onNeutralContainer),
    );
  }
}

extension MedoraThemeContext on BuildContext {
  ColorScheme get colors => Theme.of(this).colorScheme;
  MedoraColors get medora => Theme.of(this).extension<MedoraColors>()!;
  TextTheme get text => Theme.of(this).textTheme;
}
