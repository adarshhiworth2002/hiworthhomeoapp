import 'package:flutter/material.dart';

/// App palette — Athurasramam logo blue + green (exact).
/// Logo blue: #00BCF8 · Logo green: #40B448
const Color appBlack = Color(0xFF1A1A1A);
const Color appBlackSoft = Color(0xFF2A2A2A);
const Color appInk = Color(0xFF14252B);
const Color appWhite = Color(0xFFFFFFFF);

/// Soft page wash derived from logo blue.
const Color appCream = Color(0xFFF0FAFD);

/// Primary brand = exact logo blue.
const Color appBlue = Color(0xFF00BCF8);
const Color appBlueDeep = Color(0xFF0096C7);
const Color appBlueSoft = Color(0xFFE3F7FE);

/// Secondary brand = exact logo green.
const Color appGreen = Color(0xFF40B448);
const Color appGreenDeep = Color(0xFF2F9A37);
const Color appGreenSoft = Color(0xFFE8F7E9);

const Color appMuted = Color(0xFF5A6B72);

/// Legacy name kept so existing screens pick up the new primary automatically.
const Color appOrange = appBlue;
const Color appOrangeDeep = appBlueDeep;
const Color appOrangeSoft = appBlueSoft;

/// Legacy aliases used by older screens / dialogs.
Color bg1 = appCream;
Color bg2 = appWhite;
Color bg3 = appBlue;

/// Scaffold + app bar for list/detail sections.
const Color sectionBg = appCream;
const Color sectionAppBar = appWhite;
const Color sectionAccent = appBlue;
const Color sectionOnAccent = appWhite;
const Color sectionCard = appWhite;
const Color sectionText = appInk;
const Color sectionTextMuted = Color(0xFF5F727A);
const Color sectionFooter = appBlueSoft;
const Color sectionCardBorder = Color(0x4000BCF8);
const Color cashYouGot = Color(0xFF2E7D32);
const Color cashYouGave = Color(0xFFC62828);
const Color cashYouGotSoft = Color(0xFFE8F5E9);
const Color cashYouGaveSoft = Color(0xFFFFEBEE);

BoxDecoration sectionCardDecoration({double radius = 12}) {
  return BoxDecoration(
    color: sectionCard,
    borderRadius: BorderRadius.circular(radius),
    border: Border.all(color: sectionCardBorder),
    boxShadow: [
      BoxShadow(
        color: appBlue.withValues(alpha: 0.10),
        blurRadius: 10,
        offset: const Offset(0, 3),
      ),
    ],
  );
}

/// Stock section only — original black + orange (unchanged).
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
        fontSize: 17,
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
