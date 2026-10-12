import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/api.dart';

/// GET /me — 프로필·추구미 선호·고지 동의 상태.
final profileProvider = FutureProvider<Json>((ref) async => (await api.get('/me')) as Json);

/// GET /aesthetics — 활성 추구미 5종(비로그인 조회 가능).
final aestheticsProvider = FutureProvider<List<Json>>((ref) async {
  final body = (await api.get('/aesthetics')) as Json;
  return (body['items'] as List).cast<Json>();
});

/// GET /garments — 활성 의류 전체(데모는 페이지를 끝까지 읽는다).
/// 이미지 signed URL이 5분 뒤 만료되므로 4분마다 다시 읽는다(만료된 URL로 그리면 빈 칸이 된다).
final garmentsProvider = FutureProvider<List<Json>>((ref) async {
  final timer = Timer(const Duration(minutes: 4), ref.invalidateSelf);
  ref.onDispose(timer.cancel);
  final items = <Json>[];
  String? cursor;
  do {
    final page = (await api.get('/garments', query: {'limit': '50', 'cursor': cursor})) as Json;
    items.addAll((page['items'] as List).cast<Json>());
    cursor = page['next_cursor'] as String?;
  } while (cursor != null);
  return items;
});

/// id → 의류(썸네일 조회용).
final garmentByIdProvider = Provider<Map<String, Json>>((ref) {
  final list = ref.watch(garmentsProvider).value ?? const <Json>[];
  return {for (final g in list) g['id'] as String: g};
});

String aestheticName(List<Json>? all, String? id) {
  if (all == null || id == null) return '-';
  for (final a in all) {
    if (a['id'] == id) return a['display_name'] as String;
  }
  return '-';
}

/// 내 추구미(메인 먼저) id 목록.
List<String> myAestheticIds(Json profile) {
  final prefs = (profile['preferences'] as List? ?? const []).cast<Json>();
  final sorted = [...prefs]..sort((a, b) => (a['role'] == 'main' ? 0 : 1).compareTo(b['role'] == 'main' ? 0 : 1));
  return [for (final p in sorted) p['aesthetic_id'] as String];
}
