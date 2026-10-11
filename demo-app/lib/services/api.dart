import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart';

import '../config/env.dart';

/// 백엔드 오류 봉투 `{error:{code,message,retryable,request_id}}`를 그대로 담는다.
class ApiException implements Exception {
  ApiException(this.status, this.code, this.message, {this.retryable = false, this.requestId});

  final int status;
  final String code;
  final String message;
  final bool retryable;
  final String? requestId;

  bool get aiNoticeRequired => status == 403 && code == 'AI_NOTICE_REQUIRED';

  @override
  String toString() => '$message ($code · $status)';
}

typedef Json = Map<String, dynamic>;

/// `backend/docs/openapi.yaml` 계약을 그대로 호출하는 얇은 클라이언트.
/// 생성 명령은 `Idempotency-Key`를 붙인다(같은 동작 재시도 시 같은 키를 넘기면 서버가 같은 결과를 돌려준다).
class Api {
  Api._();
  static final instance = Api._();

  final _random = Random.secure();

  /// 화면에 보여 줄 최근 호출 기록(데모용 "API 로그" 패널).
  final List<String> log = [];

  String newIdempotencyKey() =>
      'demo-${DateTime.now().millisecondsSinceEpoch}-${List.generate(8, (_) => _random.nextInt(36).toRadixString(36)).join()}';

  Map<String, String> _headers({bool json = false, String? idempotencyKey}) {
    final token = Supabase.instance.client.auth.currentSession?.accessToken;
    return {
      if (token != null) 'Authorization': 'Bearer $token',
      if (json) 'Content-Type': 'application/json',
      if (idempotencyKey != null) 'Idempotency-Key': idempotencyKey,
    };
  }

  Uri _uri(String path, [Map<String, String?>? query]) {
    final params = <String, String>{};
    query?.forEach((k, v) {
      if (v != null && v.isNotEmpty) params[k] = v;
    });
    return Uri.parse('${Env.apiBaseUrl}$path').replace(queryParameters: params.isEmpty ? null : params);
  }

  Future<dynamic> _send(String method, String path,
      {Object? body, Map<String, String?>? query, bool idempotent = false, String? idempotencyKey}) async {
    final key = idempotencyKey ?? (idempotent ? newIdempotencyKey() : null);
    final request = http.Request(method, _uri(path, query))
      ..headers.addAll(_headers(json: body != null, idempotencyKey: key));
    if (body != null) request.body = jsonEncode(body);
    http.Response response;
    try {
      response = await http.Response.fromStream(await request.send());
    } catch (e) {
      _record('$method $path → 연결 실패');
      throw ApiException(0, 'NETWORK_ERROR', '서버에 연결할 수 없습니다. 로컬 dev 서버가 켜져 있는지 확인하세요.', retryable: true);
    }
    _record('$method $path → ${response.statusCode}');
    if (response.statusCode == 204 || response.body.isEmpty) {
      if (response.statusCode >= 400) throw ApiException(response.statusCode, 'HTTP_${response.statusCode}', '요청이 실패했습니다.');
      return null;
    }
    dynamic decoded;
    try {
      decoded = jsonDecode(utf8.decode(response.bodyBytes));
    } catch (_) {
      decoded = null;
    }
    if (response.statusCode >= 400) {
      final error = decoded is Map ? decoded['error'] : null;
      if (error is Map) {
        throw ApiException(response.statusCode, '${error['code']}', '${error['message'] ?? '요청이 실패했습니다.'}',
            retryable: error['retryable'] == true, requestId: error['request_id'] as String?);
      }
      throw ApiException(response.statusCode, 'HTTP_${response.statusCode}', '요청이 실패했습니다.');
    }
    return decoded;
  }

  void _record(String line) {
    final t = DateTime.now();
    log.insert(0, '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}:${t.second.toString().padLeft(2, '0')}  $line');
    if (log.length > 80) log.removeLast();
  }

  Future<dynamic> get(String path, {Map<String, String?>? query}) => _send('GET', path, query: query);
  Future<dynamic> post(String path, {Object? body, bool idempotent = false, String? idempotencyKey}) =>
      _send('POST', path, body: body, idempotent: idempotent, idempotencyKey: idempotencyKey);
  Future<dynamic> patch(String path, Object body) => _send('PATCH', path, body: body);
  Future<dynamic> put(String path, {Object? body}) => _send('PUT', path, body: body);
  Future<dynamic> delete(String path, {bool idempotent = false, String? idempotencyKey}) =>
      _send('DELETE', path, idempotent: idempotent, idempotencyKey: idempotencyKey);

  /// 서버가 준 signed URL로 실제 파일을 올린다(`SignedUpload{url,method,headers}`).
  Future<void> uploadSigned(Json upload, Uint8List bytes) async {
    final headers = (upload['headers'] as Map? ?? {}).map((k, v) => MapEntry('$k', '$v'));
    final response = await http.put(Uri.parse(upload['url'] as String), headers: headers, body: bytes);
    _record('PUT (signed upload) → ${response.statusCode}');
    if (response.statusCode >= 300) {
      throw ApiException(response.statusCode, 'UPLOAD_FAILED', '이미지 업로드에 실패했습니다. 다시 시도해 주세요.', retryable: true);
    }
  }

  /// signed URL 이미지 바이트(피드 공유 시 OOTD 사진을 다시 올릴 때 사용).
  Future<Uint8List> download(String url) async {
    final response = await http.get(Uri.parse(url));
    if (response.statusCode != 200) throw ApiException(response.statusCode, 'DOWNLOAD_FAILED', '이미지를 가져오지 못했습니다.');
    return response.bodyBytes;
  }

  /// dev 서버 데모 제어(가짜 AI 모드·날씨 장애). 배포 백엔드에는 없다.
  Future<String?> demoControl(String path) async {
    try {
      final response = await http.get(Uri.parse('${Env.demoControlBase}$path'));
      return response.statusCode == 200 ? utf8.decode(response.bodyBytes) : null;
    } catch (_) {
      return null;
    }
  }
}

final api = Api.instance;

/// 이미지 바이트에서 MIME을 추정(서버도 magic bytes로 다시 검증한다).
String guessContentType(Uint8List bytes) {
  if (bytes.length >= 8 && bytes[0] == 0x89 && bytes[1] == 0x50) return 'image/png';
  if (bytes.length >= 12 && bytes[8] == 0x57 && bytes[9] == 0x45 && bytes[10] == 0x42 && bytes[11] == 0x50) return 'image/webp';
  return 'image/jpeg';
}
