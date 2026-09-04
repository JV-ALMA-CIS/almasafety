import 'package:flutter/material.dart';
import '../../../core/widgets/loading_indicator.dart';

/// Shown while Firebase auth state or the user's profile is still
/// resolving, so the router never renders a feature screen (or the login
/// screen) before session status is actually known.
class SessionLoadingScreen extends StatelessWidget {
  const SessionLoadingScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return const Scaffold(body: LoadingIndicator());
  }
}
