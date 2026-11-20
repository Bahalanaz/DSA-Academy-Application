import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app_colors.dart';

/// The app's one theme: the same dark background, card and green accent as
/// always (AppColors), applied to every Material component in one place.
///
/// Screens still style their own content. This sets what they DON'T set,
/// so the pieces they share look and move alike everywhere: snackbars,
/// dialogs, sheets, buttons, pickers, menus, tick boxes, the text cursor,
/// loading spinners. Before it, the app ran on Flutter's default LIGHT
/// theme, so anything a screen forgot to colour came out light and
/// off-brand (a white menu, a purple button outline).
///
/// The shared shape scale, so nothing invents its own:
///   controls (buttons, fields) 10 · cards and tiles 14 · dialogs 16 ·
///   bottom sheets 20.
abstract final class AppTheme {
  static const controlRadius = 10.0;
  static const cardRadius = 14.0;
  static const dialogRadius = 16.0;
  static const sheetRadius = 20.0;

  /// A raised surface one step above a card: snackbars and tooltips, so
  /// they stand out from whatever is under them.
  static const _raised = Color(0xFF2C2C2E);

  static const _buttonText = TextStyle(
    fontSize: 14,
    fontWeight: FontWeight.bold,
    letterSpacing: 0.5,
  );

  static final _controlShape = RoundedRectangleBorder(
    borderRadius: BorderRadius.circular(controlRadius),
  );

  /// Every platform gets the same transition. The default Android one fades
  /// through a white scrim mid-animation; this never flashes white.
  static const _transitions = PageTransitionsTheme(
    builders: {
      TargetPlatform.android: FadeForwardsPageTransitionsBuilder(
        backgroundColor: AppColors.background,
      ),
      TargetPlatform.iOS: FadeForwardsPageTransitionsBuilder(
        backgroundColor: AppColors.background,
      ),
      TargetPlatform.macOS: FadeForwardsPageTransitionsBuilder(
        backgroundColor: AppColors.background,
      ),
      TargetPlatform.windows: FadeForwardsPageTransitionsBuilder(
        backgroundColor: AppColors.background,
      ),
      TargetPlatform.linux: FadeForwardsPageTransitionsBuilder(
        backgroundColor: AppColors.background,
      ),
    },
  );

  static ThemeData get dark {
    const scheme = ColorScheme.dark(
      primary: AppColors.accent,
      onPrimary: Colors.white,
      secondary: AppColors.accent,
      onSecondary: Colors.white,
      error: Colors.redAccent,
      onError: Colors.white,
      surface: AppColors.card,
      onSurface: Colors.white,
      onSurfaceVariant: Colors.white70,
      // Material 3 paints dialogs, menus and sheets with these. All the
      // app's card colour, so nothing comes out a slightly different grey.
      surfaceContainerLowest: AppColors.background,
      surfaceContainerLow: AppColors.card,
      surfaceContainer: AppColors.card,
      surfaceContainerHigh: AppColors.card,
      surfaceContainerHighest: AppColors.card,
      // No coloured tint washed over raised surfaces.
      surfaceTint: Colors.transparent,
      outline: Colors.white24,
      outlineVariant: Colors.white10,
    );

    final base = ThemeData(
      brightness: Brightness.dark,
      colorScheme: scheme,
      useMaterial3: true,
    );

    return base.copyWith(
      scaffoldBackgroundColor: AppColors.background,
      canvasColor: AppColors.background,
      pageTransitionsTheme: _transitions,
      textTheme: base.textTheme.apply(
        bodyColor: Colors.white,
        displayColor: Colors.white,
      ),
      iconTheme: const IconThemeData(color: Colors.white),
      dividerTheme: const DividerThemeData(
        color: Colors.white10,
        thickness: 1,
        space: 1,
      ),
      appBarTheme: const AppBarTheme(
        backgroundColor: AppColors.background,
        foregroundColor: Colors.white,
        elevation: 0,
        // No grey band appearing under the bar when a list scrolls.
        scrolledUnderElevation: 0,
        surfaceTintColor: Colors.transparent,
        centerTitle: true,
        iconTheme: IconThemeData(color: Colors.white),
        actionsIconTheme: IconThemeData(color: Colors.white),
        titleTextStyle: TextStyle(
          color: Colors.white,
          fontSize: 15,
          fontWeight: FontWeight.bold,
          letterSpacing: 0.5,
        ),
        // White status-bar icons over the dark app.
        systemOverlayStyle: SystemUiOverlayStyle.light,
      ),

      // Buttons: one shape, one label style, flat, with a soft press
      // highlight. A screen's own colours still win.
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: AppColors.accent,
          foregroundColor: Colors.white,
          disabledBackgroundColor: Colors.white12,
          disabledForegroundColor: Colors.white38,
          overlayColor: Colors.white,
          elevation: 0,
          shadowColor: Colors.transparent,
          shape: _controlShape,
          textStyle: _buttonText,
          animationDuration: const Duration(milliseconds: 150),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: AppColors.accent,
          foregroundColor: Colors.white,
          disabledBackgroundColor: Colors.white12,
          disabledForegroundColor: Colors.white38,
          overlayColor: Colors.white,
          shape: _controlShape,
          textStyle: _buttonText,
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: Colors.white,
          overlayColor: Colors.white,
          side: const BorderSide(color: Colors.white24),
          shape: _controlShape,
          textStyle: _buttonText,
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: AppColors.accent,
          overlayColor: Colors.white,
          shape: _controlShape,
          textStyle: _buttonText,
        ),
      ),
      iconButtonTheme: IconButtonThemeData(
        style: IconButton.styleFrom(overlayColor: Colors.white),
      ),
      floatingActionButtonTheme: const FloatingActionButtonThemeData(
        backgroundColor: AppColors.accent,
        foregroundColor: Colors.white,
        elevation: 2,
        highlightElevation: 4,
        shape: CircleBorder(),
      ),

      dialogTheme: DialogThemeData(
        backgroundColor: AppColors.card,
        surfaceTintColor: Colors.transparent,
        barrierColor: Colors.black54,
        elevation: 8,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(dialogRadius),
        ),
        titleTextStyle: const TextStyle(
          color: Colors.white,
          fontSize: 16,
          fontWeight: FontWeight.bold,
        ),
        contentTextStyle: const TextStyle(
          color: Colors.white70,
          fontSize: 13,
          height: 1.4,
        ),
      ),
      bottomSheetTheme: const BottomSheetThemeData(
        backgroundColor: AppColors.card,
        modalBackgroundColor: AppColors.card,
        surfaceTintColor: Colors.transparent,
        modalBarrierColor: Colors.black54,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(
            top: Radius.circular(sheetRadius),
          ),
        ),
      ),
      // Messages float above the content as a rounded card, instead of a
      // flat bar stuck to the bottom edge.
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: _raised,
        elevation: 4,
        insetPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        contentTextStyle: const TextStyle(
          color: Colors.white,
          fontSize: 14,
          height: 1.35,
        ),
        actionTextColor: AppColors.accent,
      ),
      popupMenuTheme: PopupMenuThemeData(
        color: AppColors.card,
        surfaceTintColor: Colors.transparent,
        elevation: 6,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        textStyle: const TextStyle(color: Colors.white, fontSize: 14),
      ),
      tooltipTheme: TooltipThemeData(
        decoration: BoxDecoration(
          color: _raised,
          borderRadius: BorderRadius.circular(8),
        ),
        textStyle: const TextStyle(color: Colors.white, fontSize: 12),
        waitDuration: const Duration(milliseconds: 400),
      ),
      progressIndicatorTheme: const ProgressIndicatorThemeData(
        color: AppColors.accent,
        linearTrackColor: Colors.white10,
        circularTrackColor: Colors.transparent,
        refreshBackgroundColor: AppColors.card,
      ),
      textSelectionTheme: TextSelectionThemeData(
        cursorColor: AppColors.accent,
        selectionColor: AppColors.accent.withValues(alpha: 0.35),
        selectionHandleColor: AppColors.accent,
      ),
      checkboxTheme: CheckboxThemeData(
        fillColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? AppColors.accent
              : Colors.transparent,
        ),
        checkColor: const WidgetStatePropertyAll(Colors.white),
        side: const BorderSide(color: Colors.white38, width: 1.5),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? Colors.white
              : Colors.white70,
        ),
        trackColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? AppColors.accent
              : Colors.white24,
        ),
        trackOutlineColor: const WidgetStatePropertyAll(Colors.transparent),
      ),
      radioTheme: const RadioThemeData(
        fillColor: WidgetStatePropertyAll(AppColors.accent),
      ),
      listTileTheme: const ListTileThemeData(
        iconColor: Colors.white70,
        textColor: Colors.white,
      ),
      scrollbarTheme: ScrollbarThemeData(
        thumbColor: WidgetStatePropertyAll(
          Colors.white.withValues(alpha: 0.25),
        ),
        radius: const Radius.circular(8),
      ),
      badgeTheme: const BadgeThemeData(
        backgroundColor: Colors.redAccent,
        textColor: Colors.white,
      ),
    );
  }
}
