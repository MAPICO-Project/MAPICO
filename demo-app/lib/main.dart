import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'app.dart';
import 'config/env.dart';

/// MAFICO 유저플로우 데모 앱(제품 코드 아님). 실행 방법은 demo-app/README.md.
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (!Env.configured) {
    runApp(const _MissingConfigApp());
    return;
  }
  await Supabase.initialize(url: Env.supabaseUrl, publishableKey: Env.supabasePublishableKey);
  runApp(const ProviderScope(child: MaficoDemoApp()));
}

class MaficoDemoApp extends StatefulWidget {
  const MaficoDemoApp({super.key});

  @override
  State<MaficoDemoApp> createState() => _MaficoDemoAppState();
}

class _MaficoDemoAppState extends State<MaficoDemoApp> {
  final _router = createRouter();

  @override
  Widget build(BuildContext context) => MaterialApp.router(
        title: 'MAFICO 데모',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(colorSchemeSeed: const Color(0xFF6D5A8C), useMaterial3: true),
        routerConfig: _router,
        // 브라우저에서도 휴대폰 화면 폭(최대 430px)으로 보여 준다.
        builder: (context, child) => ColoredBox(
          color: const Color(0xFFE9E6EF),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 430),
              child: ClipRect(child: child),
            ),
          ),
        ),
      );
}

class _MissingConfigApp extends StatelessWidget {
  const _MissingConfigApp();

  @override
  Widget build(BuildContext context) => const MaterialApp(
        home: Scaffold(
          body: Center(
            child: Padding(
              padding: EdgeInsets.all(24),
              child: Text('SUPABASE_URL / SUPABASE_PUBLISHABLE_KEY가 없습니다.\ndemo-app/README.md의 실행 방법(run-demo 스크립트)을 따르세요.',
                  textAlign: TextAlign.center),
            ),
          ),
        ),
      );
}
