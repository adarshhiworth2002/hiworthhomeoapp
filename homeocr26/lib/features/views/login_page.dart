import 'package:flutter/material.dart';
import 'package:homeocr26/features/views/selction_screen.dart';
import 'package:homeocr26/features/widgets/app_backdrop.dart';
import 'package:homeocr26/viewModels/login_viewmodel.dart';
import 'package:provider/provider.dart';

class LoginPage extends StatefulWidget {
  const LoginPage({super.key});

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final TextEditingController emailController = TextEditingController();
  final TextEditingController passwordController = TextEditingController();
  bool hidePassword = true;
  final formKey = GlobalKey<FormState>();

  static const _ink = Color(0xFF1C1A17);
  static const _muted = Color(0xFF5C534A);
  static const _accent = Color(0xFFE07A2F);

  @override
  void dispose() {
    emailController.dispose();
    passwordController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: GestureDetector(
        onTap: () => FocusScope.of(context).unfocus(),
        child: AppBackdrop(
          alignment: const Alignment(0, -0.15),
          scrim: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              Colors.white.withValues(alpha: 0.62),
              Colors.white.withValues(alpha: 0.32),
              Colors.black.withValues(alpha: 0.18),
              Colors.black.withValues(alpha: 0.55),
            ],
            stops: const [0.0, 0.36, 0.7, 1.0],
          ),
          child: SafeArea(
            child: Center(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(24, 16, 24, 28),
                child: Column(
                  children: [
                    const Text(
                      'HOMEO\nATHURASRAMAM',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 34,
                        height: 1.05,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 0.6,
                        color: _ink,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Pharmacy billing & stock',
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w500,
                        color: _muted.withValues(alpha: 0.95),
                      ),
                    ),
                    const SizedBox(height: 28),
                    FrostedPanel(
                      child: Form(
                        key: formKey,
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            const Text(
                              'Sign in',
                              style: TextStyle(
                                fontSize: 22,
                                fontWeight: FontWeight.w700,
                                color: _ink,
                              ),
                            ),
                            const SizedBox(height: 6),
                            const Text(
                              'Use your Odoo account to continue',
                              style: TextStyle(
                                fontSize: 13,
                                color: _muted,
                              ),
                            ),
                            const SizedBox(height: 22),
                            _buildTextField(
                              hint: 'Email',
                              icon: Icons.email_outlined,
                              controller: emailController,
                              validator: (value) {
                                if (value == null || value.isEmpty) {
                                  return 'Email is required';
                                }
                                return null;
                              },
                            ),
                            const SizedBox(height: 14),
                            _buildTextField(
                              hint: 'Password',
                              icon: Icons.lock_outline,
                              controller: passwordController,
                              isPassword: true,
                              validator: (value) {
                                if (value == null || value.isEmpty) {
                                  return 'Password is required';
                                }
                                return null;
                              },
                            ),
                            const SizedBox(height: 8),
                            Align(
                              alignment: Alignment.centerRight,
                              child: TextButton(
                                onPressed: () {},
                                style: TextButton.styleFrom(
                                  foregroundColor: _accent,
                                  padding: EdgeInsets.zero,
                                  minimumSize: Size.zero,
                                  tapTargetSize:
                                      MaterialTapTargetSize.shrinkWrap,
                                ),
                                child: const Text(
                                  'Forgot Password?',
                                  style: TextStyle(fontWeight: FontWeight.w600),
                                ),
                              ),
                            ),
                            const SizedBox(height: 18),
                            Consumer<LoginViewmodel>(
                              builder: (context, viewModel, _) {
                                if (viewModel.userLoginLoading) {
                                  return const Center(
                                    child: Padding(
                                      padding: EdgeInsets.symmetric(vertical: 8),
                                      child: CircularProgressIndicator(
                                        color: _accent,
                                      ),
                                    ),
                                  );
                                }
                                return SizedBox(
                                  height: 52,
                                  child: ElevatedButton(
                                    style: ElevatedButton.styleFrom(
                                      backgroundColor: _accent,
                                      foregroundColor: Colors.white,
                                      elevation: 0,
                                      shape: RoundedRectangleBorder(
                                        borderRadius: BorderRadius.circular(14),
                                      ),
                                    ),
                                    onPressed: () async {
                                      final model = Provider.of<LoginViewmodel>(
                                        context,
                                        listen: false,
                                      );
                                      if (!formKey.currentState!.validate()) {
                                        return;
                                      }
                                      final result = await model.userLogin(
                                        email: emailController.text,
                                        password: passwordController.text,
                                      );
                                      if (!context.mounted) return;
                                      if (result == 'success') {
                                        Navigator.of(context).pushReplacement(
                                          PageRouteBuilder(
                                            pageBuilder: (
                                              context,
                                              animation,
                                              secondaryAnimation,
                                            ) =>
                                                const SelectionScreen(),
                                            transitionDuration: const Duration(
                                              milliseconds: 500,
                                            ),
                                            transitionsBuilder: (
                                              context,
                                              animation,
                                              secondaryAnimation,
                                              child,
                                            ) {
                                              return FadeTransition(
                                                opacity: animation,
                                                child: child,
                                              );
                                            },
                                          ),
                                        );
                                      } else {
                                        ScaffoldMessenger.of(context)
                                            .showSnackBar(
                                          SnackBar(content: Text(result)),
                                        );
                                      }
                                    },
                                    child: const Text(
                                      'LOGIN',
                                      style: TextStyle(
                                        fontWeight: FontWeight.w800,
                                        fontSize: 16,
                                        letterSpacing: 0.8,
                                      ),
                                    ),
                                  ),
                                );
                              },
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildTextField({
    required String hint,
    required IconData icon,
    required TextEditingController controller,
    bool isPassword = false,
    String? Function(String?)? validator,
  }) {
    return TextFormField(
      validator: validator,
      controller: controller,
      obscureText: isPassword ? hidePassword : false,
      style: const TextStyle(color: _ink, fontWeight: FontWeight.w500),
      decoration: InputDecoration(
        prefixIcon: Icon(icon, color: _muted),
        suffixIcon: isPassword
            ? IconButton(
                onPressed: () {
                  setState(() => hidePassword = !hidePassword);
                },
                icon: Icon(
                  hidePassword
                      ? Icons.visibility_outlined
                      : Icons.visibility_off_outlined,
                  color: _muted,
                ),
              )
            : null,
        hintText: hint,
        hintStyle: TextStyle(color: _muted.withValues(alpha: 0.75)),
        filled: true,
        fillColor: Colors.white.withValues(alpha: 0.85),
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 16),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(
            color: Colors.black.withValues(alpha: 0.06),
          ),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: const BorderSide(color: _accent, width: 1.4),
        ),
      ),
    );
  }
}
