/// 빌드 시 `--dart-define`으로 받는 값. 앱에는 Supabase URL과 publishable key만 넣는다.
/// 서버 비밀값(secret key, HMAC, 날씨 키)은 절대 여기에 넣지 않는다.
class Env {
  Env._();

  static const supabaseUrl = String.fromEnvironment('SUPABASE_URL');
  static const supabasePublishableKey = String.fromEnvironment('SUPABASE_PUBLISHABLE_KEY');

  /// 로컬 dev 서버(backend/tools/dev-server.mjs) 기본값. 배포 백엔드가 준비되면 바꾼다.
  static const apiBaseUrl = String.fromEnvironment('API_BASE_URL', defaultValue: 'http://localhost:3000/api/v1');

  /// dev 서버의 데모 제어 경로(/__demo/*). 배포 백엔드에는 없다.
  static String get demoControlBase => apiBaseUrl.replaceFirst(RegExp(r'/api/v1/?$'), '');

  static bool get configured => supabaseUrl.isNotEmpty && supabasePublishableKey.isNotEmpty;
}
