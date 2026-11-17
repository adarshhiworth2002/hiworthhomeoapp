import 'package:flutter/material.dart';
import 'package:homeocr26/features/services/auth_session_store.dart';
import 'package:homeocr26/features/services/cheque_notification_service.dart';
import 'package:homeocr26/features/theme.dart';
import 'package:homeocr26/features/views/splash_screen.dart';
import 'package:homeocr26/features/widgets/system_safe.dart';
import 'package:homeocr26/viewModels/login_viewmodel.dart';
import 'package:homeocr26/viewModels/supplier_med_viewmodel.dart';
import 'package:homeocr26/viewModels/customer_med_viewModel.dart';
import 'package:provider/provider.dart';

Future<void> main() async {
  await SystemSafe.configure();
  await ChequeNotificationService.init();
  final savedAuth = await AuthSessionStore.load();
  runApp(MyApp(savedAuth: savedAuth));
}

class MyApp extends StatelessWidget {
  const MyApp({super.key, this.savedAuth});

  final SavedAuth? savedAuth;

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => SupplierMedViewModel()),
        ChangeNotifierProvider(
          create: (_) => LoginViewmodel(saved: savedAuth),
        ),
        ChangeNotifierProvider(create: (_) => CustomerMedViewmodel()),
      ],
      child: MaterialApp(
        theme: ThemeData(
          brightness: Brightness.light,
          scaffoldBackgroundColor: appCream,
          colorScheme: ColorScheme.fromSeed(
            seedColor: appBlue,
            brightness: Brightness.light,
            primary: appBlue,
            secondary: appGreen,
            surface: appWhite,
            onPrimary: appWhite,
            onSecondary: appWhite,
            onSurface: appInk,
          ),
          appBarTheme: const AppBarTheme(
            backgroundColor: appWhite,
            foregroundColor: appInk,
            elevation: 0,
            iconTheme: IconThemeData(color: appInk),
            titleTextStyle: TextStyle(
              color: appInk,
              fontWeight: FontWeight.w600,
              fontSize: 17,
            ),
          ),
          progressIndicatorTheme: const ProgressIndicatorThemeData(
            color: appBlue,
          ),
          floatingActionButtonTheme: const FloatingActionButtonThemeData(
            backgroundColor: appBlue,
            foregroundColor: appWhite,
          ),
          filledButtonTheme: FilledButtonThemeData(
            style: FilledButton.styleFrom(
              backgroundColor: appBlue,
              foregroundColor: appWhite,
            ),
          ),
          elevatedButtonTheme: ElevatedButtonThemeData(
            style: ElevatedButton.styleFrom(
              backgroundColor: appBlue,
              foregroundColor: appWhite,
            ),
          ),
          tabBarTheme: const TabBarThemeData(
            labelColor: appBlue,
            unselectedLabelColor: appMuted,
            indicatorColor: appGreen,
          ),
          checkboxTheme: CheckboxThemeData(
            fillColor: WidgetStateProperty.resolveWith((states) {
              if (states.contains(WidgetState.selected)) return appGreen;
              return null;
            }),
          ),
          switchTheme: SwitchThemeData(
            thumbColor: WidgetStateProperty.resolveWith((states) {
              if (states.contains(WidgetState.selected)) return appWhite;
              return null;
            }),
            trackColor: WidgetStateProperty.resolveWith((states) {
              if (states.contains(WidgetState.selected)) return appGreen;
              return null;
            }),
          ),
        ),
        debugShowCheckedModeBanner: false,
        title: 'Homeo App',
        builder: SystemSafe.wrapApp,
        home: const SplashScreen(),
      ),
    );
  }
}
