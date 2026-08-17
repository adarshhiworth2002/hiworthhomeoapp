import 'package:flutter/material.dart';

/// App palette — orange and white (client-facing, high visibility).
const Color appBlack = Color(0xFF1A1A1A);
const Color appBlackSoft = Color(0xFF2A2A2A);
const Color appInk = Color(0xFF1C1A17);
const Color appWhite = Color(0xFFFFFFFF);
const Color appCream = Color(0xFFFFF7F1);
const Color appOrange = Color(0xFFE07A2F);
const Color appOrangeDeep = Color(0xFFC45F1A);
const Color appMuted = Color(0xFF6B6258);
const Color appOrangeSoft = Color(0xFFFFF1E6);

/// Legacy aliases used by older screens / dialogs.
Color bg1 = appCream;
Color bg2 = appWhite;
Color bg3 = appOrange;

/// Scaffold + app bar for list/detail sections (light orange / white).
const Color sectionBg = appCream;
const Color sectionAppBar = appWhite;
const Color sectionAccent = appOrange;
const Color sectionOnAccent = appWhite;
const Color sectionCard = appWhite;
const Color sectionText = appInk;
const Color sectionTextMuted = Color(0xFF7A7168);
const Color sectionFooter = appOrangeSoft;
const Color sectionCardBorder = Color(0x40E07A2F);

BoxDecoration sectionCardDecoration({double radius = 12}) {
  return BoxDecoration(
    color: sectionCard,
    borderRadius: BorderRadius.circular(radius),
    border: Border.all(color: sectionCardBorder),
    boxShadow: [
      BoxShadow(
        color: appOrange.withValues(alpha: 0.08),
        blurRadius: 10,
        offset: const Offset(0, 3),
      ),
    ],
  );
}

/// Stock section only — original black + orange.
const Color stockBg = Color(0xFF1A1A1A);
const Color stockCard = Color(0xFF2A2A2A);
const Color stockText = Color(0xFFFFFFFF);
const Color stockTextMuted = Color(0xFFB8B0A8);
const Color stockAccent = Color(0xFFE07A2F);
const Color stockCardBorder = Color(0x33FFFFFF);

ThemeData stockTheme() {
  return ThemeData(
    brightness: Brightness.dark,
    scaffoldBackgroundColor: stockBg,
    colorScheme: const ColorScheme.dark(
      primary: stockAccent,
      secondary: stockAccent,
      surface: stockCard,
      onPrimary: Colors.white,
      onSurface: stockText,
    ),
    appBarTheme: const AppBarTheme(
      backgroundColor: stockBg,
      foregroundColor: stockText,
      elevation: 0,
      iconTheme: IconThemeData(color: stockText),
      titleTextStyle: TextStyle(
        color: stockText,
        fontWeight: FontWeight.w600,
        fontSize: 15,
      ),
    ),
    progressIndicatorTheme: const ProgressIndicatorThemeData(
      color: stockAccent,
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: stockAccent,
        foregroundColor: Colors.white,
      ),
    ),
  );
}
