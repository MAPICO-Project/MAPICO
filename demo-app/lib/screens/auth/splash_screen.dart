import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../providers/providers.dart';
import '../../widgets/common.dart';

/// 스플래시: 로그인 상태에서 GET /me로 신규 회원(온보딩 미완료) 여부를 판단한다.
class SplashScreen extends ConsumerWidget {
  const SplashScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.listen(profileProvider, (_, next) {
      final profile = next.value;
      if (profile == null) return;
      context.go(profile['onboarding_completed'] == true ? '/home' : '/onboarding');
    });
    final profile = ref.watch(profileProvider);
    return Scaffold(
      body: profile.hasError
          ? ErrorPanel(profile.error!, onRetry: () => ref.invalidate(profileProvider))
          : const Center(
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                Text('MAFICO', style: TextStyle(fontSize: 36, fontWeight: FontWeight.w800, letterSpacing: 4)),
                Text('MyFit:Core · 마피코'),
                SizedBox(height: 24),
                CircularProgressIndicator(),
              ]),
            ),
    );
  }
}
