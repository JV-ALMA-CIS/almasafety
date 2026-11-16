import 'package:flutter/material.dart';

import '../utils/responsive.dart';

/// The top-bar title of a screen opened on top of the app (a form or detail
/// page), shown on phones only.
///
/// On tablet and desktop the screen's coloured [FeatureHeader] banner is
/// its title and the top bar stays title-less, so nothing is said twice. On
/// a phone the banner scrolls away quickly, so the top bar names the page
/// as well — a short, fixed name such as "Learning Details".
class MobileTitle extends StatelessWidget {
  const MobileTitle(this.title, {super.key});

  final String title;

  @override
  Widget build(BuildContext context) {
    if (!Responsive.isMobile(context)) return const SizedBox.shrink();
    return Semantics(
      header: true,
      child: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
    );
  }
}
