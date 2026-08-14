import 'package:flutter/material.dart';
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
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => SupplierMedViewModel()),
        ChangeNotifierProvider(create: (_) => LoginViewmodel()),
        ChangeNotifierProvider(create: (_) => CustomerMedViewmodel()),
      ],
      child: MaterialApp(
        theme: ThemeData(
          brightness: Brightness.light,
          scaffoldBackgroundColor: appCream,
          colorScheme: ColorScheme.fromSeed(
            seedColor: appOrange,
            brightness: Brightness.light,
            primary: appOrange,
            secondary: appOrange,
            surface: appWhite,
            onPrimary: appWhite,
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
              fontSize: 15,
            ),
          ),
          progressIndicatorTheme: const ProgressIndicatorThemeData(
            color: appOrange,
          ),
          floatingActionButtonTheme: const FloatingActionButtonThemeData(
            backgroundColor: appOrange,
            foregroundColor: appWhite,
          ),
          filledButtonTheme: FilledButtonThemeData(
            style: FilledButton.styleFrom(
              backgroundColor: appOrange,
              foregroundColor: appWhite,
            ),
          ),
          tabBarTheme: const TabBarThemeData(
            labelColor: appOrange,
            unselectedLabelColor: appMuted,
            indicatorColor: appOrange,
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
