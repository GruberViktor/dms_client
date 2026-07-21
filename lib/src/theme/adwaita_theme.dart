import 'package:flutter/material.dart';

/// GNOME Adwaita dark theme, translated to a Material 3 [ThemeData].
///
/// Colors are taken from libadwaita's named colors (the `-dark` variants):
/// https://gnome.pages.gitlab.gnome.org/libadwaita/doc/main/named-colors.html
class AdwaitaColors {
  AdwaitaColors._();

  // Accent (blue).
  static const accentBg = Color(0xFF3584E4); // @accent_bg_color
  static const accentFg = Color(0xFFFFFFFF); // @accent_fg_color
  static const accent = Color(0xFF78AEED); // @accent_color (standalone, dark)
  static const accentContainer = Color(0xFF1A5FB4); // blue_5

  // Destructive / error (red).
  static const destructiveBg = Color(0xFFC01C28); // @destructive_bg_color
  static const destructiveFg = Color(0xFFFFFFFF);
  static const destructive = Color(0xFFFF7B63); // @destructive_color (dark)

  // Success (green).
  static const successBg = Color(0xFF26A269); // @success_bg_color
  static const success = Color(0xFF8FF0A4); // @success_color (dark)

  // Warning (yellow).
  static const warningBg = Color(0xFFCD9309); // @warning_bg_color
  static const warning = Color(0xFFFFBE6F); // @warning_color (dark)

  // Neutral surfaces.
  static const windowBg = Color(0xFF242424); // @window_bg_color
  static const windowFg = Color(0xFFFFFFFF); // @window_fg_color
  static const viewBg = Color(0xFF1E1E1E); // @view_bg_color
  static const viewFg = Color(0xFFFFFFFF); // @view_fg_color
  static const headerbarBg = Color(0xFF303030); // @headerbar_bg_color
  static const sidebarBg = Color(0xFF2E2E2E); // @sidebar_bg_color
  static const popoverBg = Color(0xFF383838); // @popover_bg_color
  static const dialogBg = Color(0xFF383838); // @dialog_bg_color
  static const cardBg = Color(0xFF2A2A2A); // @card_bg_color (opaque equiv.)

  // Dimmed foreground (~55% of white on window bg).
  static const dimFg = Color(0xFFB0B0B0);
  // Separators / borders.
  static const borders = Color(0xFF3D3D3D);
}

/// A Material 3 [ColorScheme] approximating Adwaita dark.
const adwaitaDarkColorScheme = ColorScheme(
  brightness: Brightness.dark,
  primary: AdwaitaColors.accentBg,
  onPrimary: AdwaitaColors.accentFg,
  primaryContainer: AdwaitaColors.accentContainer,
  onPrimaryContainer: Color(0xFFDCE9FB),
  secondary: AdwaitaColors.accent,
  onSecondary: AdwaitaColors.windowFg,
  secondaryContainer: AdwaitaColors.accentContainer,
  onSecondaryContainer: Color(0xFFDCE9FB),
  tertiary: AdwaitaColors.success,
  onTertiary: Color(0xFF00391C),
  tertiaryContainer: AdwaitaColors.successBg,
  onTertiaryContainer: Color(0xFFDEF7E6),
  error: AdwaitaColors.destructive,
  onError: Color(0xFF3F0709),
  errorContainer: AdwaitaColors.destructiveBg,
  onErrorContainer: Color(0xFFFCE1E1),
  surface: AdwaitaColors.windowBg,
  onSurface: AdwaitaColors.windowFg,
  onSurfaceVariant: AdwaitaColors.dimFg,
  surfaceContainerLowest: AdwaitaColors.viewBg,
  surfaceContainerLow: AdwaitaColors.sidebarBg,
  surfaceContainer: AdwaitaColors.headerbarBg,
  surfaceContainerHigh: AdwaitaColors.popoverBg,
  surfaceContainerHighest: Color(0xFF3C3C3C),
  surfaceDim: AdwaitaColors.windowBg,
  surfaceBright: Color(0xFF3A3A3A),
  outline: AdwaitaColors.borders,
  outlineVariant: Color(0xFF333333),
  inverseSurface: Color(0xFFE3E3E3),
  onInverseSurface: Color(0xFF2A2A2A),
  inversePrimary: AdwaitaColors.accentContainer,
  shadow: Color(0xFF000000),
  scrim: Color(0xFF000000),
);

/// The full Adwaita-dark [ThemeData] used by the app.
ThemeData adwaitaDarkTheme() {
  const cs = adwaitaDarkColorScheme;
  final base = ThemeData(
    useMaterial3: true,
    brightness: Brightness.dark,
    colorScheme: cs,
    scaffoldBackgroundColor: AdwaitaColors.windowBg,
    dividerColor: AdwaitaColors.borders,
  );

  return base.copyWith(
    // Adwaita header bars: flat, slightly lighter than the window, hairline
    // bottom border via surfaceTint disabled.
    appBarTheme: const AppBarTheme(
      backgroundColor: AdwaitaColors.headerbarBg,
      foregroundColor: AdwaitaColors.windowFg,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
      titleTextStyle: TextStyle(
        color: AdwaitaColors.windowFg,
        fontSize: 16,
        fontWeight: FontWeight.w700,
      ),
    ),
    cardTheme: const CardThemeData(
      color: AdwaitaColors.cardBg,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(12)),
      ),
    ),
    dialogTheme: const DialogThemeData(
      backgroundColor: AdwaitaColors.dialogBg,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
    ),
    drawerTheme: const DrawerThemeData(
      backgroundColor: AdwaitaColors.sidebarBg,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
    ),
    navigationRailTheme: NavigationRailThemeData(
      backgroundColor: AdwaitaColors.sidebarBg,
      indicatorColor: AdwaitaColors.accentBg.withValues(alpha: 0.25),
      selectedIconTheme: const IconThemeData(color: AdwaitaColors.accent),
      unselectedIconTheme: const IconThemeData(color: AdwaitaColors.dimFg),
      selectedLabelTextStyle: const TextStyle(color: AdwaitaColors.windowFg),
      unselectedLabelTextStyle: const TextStyle(color: AdwaitaColors.dimFg),
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: AdwaitaColors.headerbarBg,
      surfaceTintColor: Colors.transparent,
      indicatorColor: AdwaitaColors.accentBg.withValues(alpha: 0.25),
      elevation: 0,
    ),
    popupMenuTheme: const PopupMenuThemeData(
      color: AdwaitaColors.popoverBg,
      surfaceTintColor: Colors.transparent,
      elevation: 1,
    ),
    menuTheme: const MenuThemeData(
      style: MenuStyle(
        backgroundColor: WidgetStatePropertyAll(AdwaitaColors.popoverBg),
        surfaceTintColor: WidgetStatePropertyAll(Colors.transparent),
      ),
    ),
    bottomSheetTheme: const BottomSheetThemeData(
      backgroundColor: AdwaitaColors.dialogBg,
      surfaceTintColor: Colors.transparent,
    ),
    listTileTheme: const ListTileThemeData(
      selectedColor: AdwaitaColors.windowFg,
      selectedTileColor: Color(0x333584E4),
      iconColor: AdwaitaColors.dimFg,
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: AdwaitaColors.viewBg,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: const BorderSide(color: AdwaitaColors.borders),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: const BorderSide(color: AdwaitaColors.borders),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: const BorderSide(color: AdwaitaColors.accentBg, width: 2),
      ),
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(
        backgroundColor: AdwaitaColors.accentBg,
        foregroundColor: AdwaitaColors.accentFg,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
        ),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: AdwaitaColors.accentBg,
        foregroundColor: AdwaitaColors.accentFg,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
        ),
      ),
    ),
    floatingActionButtonTheme: const FloatingActionButtonThemeData(
      backgroundColor: AdwaitaColors.accentBg,
      foregroundColor: AdwaitaColors.accentFg,
    ),
    chipTheme: const ChipThemeData(
      backgroundColor: AdwaitaColors.cardBg,
      side: BorderSide(color: AdwaitaColors.borders),
    ),
    snackBarTheme: const SnackBarThemeData(
      backgroundColor: AdwaitaColors.popoverBg,
      contentTextStyle: TextStyle(color: AdwaitaColors.windowFg),
      behavior: SnackBarBehavior.floating,
    ),
    tooltipTheme: const TooltipThemeData(
      decoration: BoxDecoration(
        color: AdwaitaColors.popoverBg,
        borderRadius: BorderRadius.all(Radius.circular(6)),
      ),
      textStyle: TextStyle(color: AdwaitaColors.windowFg, fontSize: 12),
    ),
    dividerTheme: const DividerThemeData(
      color: AdwaitaColors.borders,
      thickness: 1,
      space: 1,
    ),
    progressIndicatorTheme: const ProgressIndicatorThemeData(
      color: AdwaitaColors.accentBg,
    ),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.selected)
            ? AdwaitaColors.accentFg
            : AdwaitaColors.dimFg,
      ),
      trackColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.selected)
            ? AdwaitaColors.accentBg
            : AdwaitaColors.viewBg,
      ),
    ),
  );
}
