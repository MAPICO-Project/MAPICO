import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../providers/providers.dart';
import '../../widgets/common.dart';

/// 로그인/회원가입. 제품은 카카오 소셜 로그인이지만 카카오 앱·Supabase provider 설정 전이라
/// 데모는 Supabase 이메일 테스트 계정으로 로그인한다.
class LoginScreen extends ConsumerStatefulWidget {
  const LoginScreen({super.key});

  @override
  ConsumerState<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends ConsumerState<LoginScreen> {
  final _email = TextEditingController();
  final _password = TextEditingController();
  bool _busy = false;

  Future<void> _login() async {
    setState(() => _busy = true);
    try {
      await Supabase.instance.client.auth.signInWithPassword(email: _email.text.trim(), password: _password.text);
      ref.invalidate(profileProvider);
      ref.invalidate(garmentsProvider);
    } on AuthException catch (e) {
      if (mounted) showSnack(context, '로그인 실패: ${e.message}');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        body: SafeArea(
          child: ListView(padding: const EdgeInsets.all(24), children: [
            const SizedBox(height: 48),
            const Text('MAFICO', textAlign: TextAlign.center, style: TextStyle(fontSize: 40, fontWeight: FontWeight.w800, letterSpacing: 4)),
            const Text('내 옷장으로 오늘의 코디를', textAlign: TextAlign.center),
            const SizedBox(height: 40),
            FilledButton.icon(
              style: FilledButton.styleFrom(backgroundColor: const Color(0xFFFEE500), foregroundColor: Colors.black87),
              onPressed: null,
              icon: const Icon(Icons.chat_bubble),
              label: const Text('카카오로 시작하기 (설정 필요)'),
            ),
            const Padding(
              padding: EdgeInsets.only(top: 6),
              child: Text('카카오 개발자 앱·Supabase Kakao provider 설정 후 활성화됩니다.', textAlign: TextAlign.center, style: TextStyle(fontSize: 12, color: Colors.grey)),
            ),
            const Divider(height: 48),
            const Text('데모 계정으로 로그인', style: TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            Wrap(spacing: 8, children: [
              for (final (label, email) in [('신규 회원', 'new@mafico.dev'), ('준비된 옷장', 'demo@mafico.dev'), ('피드 작성자', 'friend@mafico.dev')])
                ActionChip(label: Text(label), onPressed: () => setState(() => _email.text = email)),
            ]),
            TextField(controller: _email, decoration: const InputDecoration(labelText: '이메일'), keyboardType: TextInputType.emailAddress),
            TextField(controller: _password, decoration: const InputDecoration(labelText: '비밀번호'), obscureText: true, onSubmitted: (_) => _login()),
            const SizedBox(height: 16),
            FilledButton(onPressed: _busy ? null : _login, child: _busy ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)) : const Text('로그인')),
          ]),
        ),
      );
}
