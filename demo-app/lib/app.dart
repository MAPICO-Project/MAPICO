import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'screens/auth/login_screen.dart';
import 'screens/auth/splash_screen.dart';
import 'screens/closet/closet_screen.dart';
import 'screens/closet/garment_detail_screen.dart';
import 'screens/closet/register_screen.dart';
import 'screens/feed/feed_screen.dart';
import 'screens/feed/mimic_result_screen.dart';
import 'screens/feed/post_compose_screen.dart';
import 'screens/feed/post_detail_screen.dart';
import 'screens/home/home_screen.dart';
import 'screens/mix/compose_outfit_screen.dart';
import 'screens/mix/mix_screen.dart';
import 'screens/mix/ootd_detail_screen.dart';
import 'screens/mix/ootd_edit_screen.dart';
import 'screens/mypage/aesthetic_manage_screen.dart';
import 'screens/mypage/mypage_screen.dart';
import 'screens/mypage/withdraw_screen.dart';
import 'screens/onboarding/notice_screen.dart';
import 'screens/onboarding/onboarding_screen.dart';

/// 라우트 지도. GNB 4탭(홈 / 디지털 옷장 / 스타일 믹스·캘린더 / 소셜 피드)은 StatefulShellRoute,
/// 상세·작성 화면과 마이페이지는 탭 위로 덮는 최상위 경로다.
///
/// 가드: 세션이 없으면 /login. 온보딩 완료 여부는 스플래시(`/`)가 GET /me로 판단한다.
final _rootKey = GlobalKey<NavigatorState>();

class _AuthRefresh extends ChangeNotifier {
  _AuthRefresh() {
    Supabase.instance.client.auth.onAuthStateChange.listen((_) => notifyListeners());
  }
}

GoRouter createRouter() => GoRouter(
      navigatorKey: _rootKey,
      initialLocation: '/',
      refreshListenable: _AuthRefresh(),
      redirect: (context, state) {
        final loggedIn = Supabase.instance.client.auth.currentSession != null;
        final atLogin = state.matchedLocation == '/login';
        if (!loggedIn) return atLogin ? null : '/login';
        if (atLogin) return '/';
        return null;
      },
      routes: [
        GoRoute(path: '/', builder: (_, _) => const SplashScreen()),
        GoRoute(path: '/login', builder: (_, _) => const LoginScreen()),
        GoRoute(path: '/onboarding', builder: (_, _) => const OnboardingScreen()),
        // 외부 AI 전송 고지. 동의하면 pop(true). 옷 등록 중 403 AI_NOTICE_REQUIRED에서도 온다.
        GoRoute(path: '/notice', builder: (_, state) => NoticeScreen(fromAnalysis: state.uri.queryParameters['from'] == 'analysis')),
        StatefulShellRoute.indexedStack(
          builder: (context, state, shell) => _TabShell(shell: shell),
          branches: [
            StatefulShellBranch(routes: [GoRoute(path: '/home', builder: (_, _) => const HomeScreen())]),
            StatefulShellBranch(routes: [GoRoute(path: '/closet', builder: (_, _) => const ClosetScreen())]),
            StatefulShellBranch(routes: [GoRoute(path: '/mix', builder: (_, _) => const MixScreen())]),
            StatefulShellBranch(routes: [GoRoute(path: '/feed', builder: (_, _) => const FeedScreen())]),
          ],
        ),
        // 옷장
        GoRoute(path: '/closet/register', builder: (_, _) => const RegisterScreen()),
        GoRoute(path: '/closet/garment/:id', builder: (_, s) => GarmentDetailScreen(garmentId: s.pathParameters['id']!)),
        // 스타일 믹스·캘린더
        GoRoute(path: '/mix/compose', builder: (_, s) => ComposeOutfitScreen(args: s.extra as ComposeOutfitArgs?)),
        GoRoute(path: '/mix/ootd/:id', builder: (_, s) => OotdDetailScreen(ootdId: s.pathParameters['id']!)),
        GoRoute(path: '/mix/ootd-edit', builder: (_, s) => OotdEditScreen(args: s.extra as OotdEditArgs?)),
        // 피드
        GoRoute(path: '/feed/new', builder: (_, s) => PostComposeScreen(sourceOotd: s.extra as Map<String, dynamic>?)),
        GoRoute(path: '/feed/post/:id', builder: (_, s) => PostDetailScreen(postId: s.pathParameters['id']!)),
        GoRoute(path: '/feed/mimic/:jobId', builder: (_, s) => MimicResultScreen(jobId: s.pathParameters['jobId']!)),
        // 마이페이지(GNB 제외, 홈 우측 상단 프로필 아이콘)
        GoRoute(path: '/mypage', builder: (_, _) => const MyPageScreen()),
        GoRoute(path: '/mypage/aesthetics', builder: (_, _) => const AestheticManageScreen()),
        GoRoute(path: '/mypage/withdraw', builder: (_, _) => const WithdrawScreen()),
      ],
    );

class _TabShell extends StatelessWidget {
  const _TabShell({required this.shell});
  final StatefulNavigationShell shell;

  @override
  Widget build(BuildContext context) => Scaffold(
        body: shell,
        bottomNavigationBar: NavigationBar(
          selectedIndex: shell.currentIndex,
          onDestinationSelected: (i) => shell.goBranch(i, initialLocation: i == shell.currentIndex),
          destinations: const [
            NavigationDestination(icon: Icon(Icons.home_outlined), selectedIcon: Icon(Icons.home), label: '홈'),
            NavigationDestination(icon: Icon(Icons.checkroom_outlined), selectedIcon: Icon(Icons.checkroom), label: '디지털 옷장'),
            NavigationDestination(icon: Icon(Icons.calendar_month_outlined), selectedIcon: Icon(Icons.calendar_month), label: '믹스·캘린더'),
            NavigationDestination(icon: Icon(Icons.grid_view_outlined), selectedIcon: Icon(Icons.grid_view), label: '소셜 피드'),
          ],
        ),
      );
}
