import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../config/labels.dart';
import '../../providers/providers.dart';
import '../../services/api.dart';
import '../../widgets/common.dart';

/// 소셜 피드: 추구미·날씨 필터 + Masonry(2열) 그리드. GET /feed (cursor 페이지).
class FeedScreen extends ConsumerStatefulWidget {
  const FeedScreen({super.key});

  @override
  ConsumerState<FeedScreen> createState() => _FeedScreenState();
}

class _FeedScreenState extends ConsumerState<FeedScreen> {
  String? _aestheticId;
  String? _weatherCode;
  final List<Json> _items = [];
  String? _cursor;
  bool _loading = false;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _load(reset: true);
  }

  Future<void> _load({bool reset = false}) async {
    if (_loading) return;
    setState(() {
      _loading = true;
      _error = null;
      if (reset) {
        _items.clear();
        _cursor = null;
      }
    });
    try {
      final page = (await api.get('/feed', query: {
        'limit': '20',
        'cursor': reset ? null : _cursor,
        'aesthetic_id': _aestheticId,
        'weather_code': _weatherCode,
      })) as Json;
      setState(() {
        _items.addAll((page['items'] as List).cast<Json>());
        _cursor = page['next_cursor'] as String?;
      });
    } catch (e) {
      setState(() => _error = e);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _openPost(String id) async {
    await context.push('/feed/post/$id');
    if (mounted) _load(reset: true); // 좋아요·삭제 반영
  }

  @override
  Widget build(BuildContext context) {
    final aesthetics = ref.watch(aestheticsProvider).value ?? const <Json>[];
    return Scaffold(
      appBar: AppBar(title: const Text('소셜 피드'), actions: [
        IconButton(tooltip: '새로고침', onPressed: () => _load(reset: true), icon: const Icon(Icons.refresh)),
        const ApiLogButton(),
      ]),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () async {
          await context.push('/feed/new');
          if (mounted) _load(reset: true);
        },
        icon: const Icon(Icons.add),
        label: const Text('포스트 작성'),
      ),
      body: RefreshIndicator(
        onRefresh: () => _load(reset: true),
        child: ListView(padding: const EdgeInsets.only(bottom: 96), children: [
          _chipRow([
            ChoiceChip(label: const Text('전체'), selected: _aestheticId == null, onSelected: (_) => _setAesthetic(null)),
            for (final a in aesthetics)
              ChoiceChip(label: Text(a['display_name'] as String), selected: _aestheticId == a['id'], onSelected: (_) => _setAesthetic(a['id'] as String)),
          ]),
          _chipRow([
            ChoiceChip(label: const Text('날씨 전체'), selected: _weatherCode == null, onSelected: (_) => _setWeather(null)),
            for (final e in weatherCodes.entries)
              ChoiceChip(
                avatar: Icon(weatherIcon(e.key), size: 16),
                label: Text(e.value),
                selected: _weatherCode == e.key,
                onSelected: (_) => _setWeather(e.key),
              ),
          ]),
          if (_error != null && _items.isEmpty) ...[
            ErrorPanel(_error!, onRetry: () => _load(reset: true)),
            if (_error is ApiException && (_error as ApiException).code == 'DATABASE_SCHEMA_NOT_READY')
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 24),
                child: Text('백엔드 수정 대기(계약 문제 #5): 원격 DB에서 feed_posts.deleted_at 조회 권한이 빠져 있어 피드 목록을 읽지 못합니다.',
                    textAlign: TextAlign.center, style: TextStyle(color: Colors.grey)),
              ),
          ] else if (_items.isEmpty && _loading)
            const Padding(padding: EdgeInsets.all(48), child: Center(child: CircularProgressIndicator()))
          else if (_items.isEmpty)
            const Padding(padding: EdgeInsets.all(48), child: Center(child: Text('조건에 맞는 공개 포스트가 없어요')))
          else ...[
            Padding(padding: const EdgeInsets.symmetric(horizontal: 8), child: _masonry()),
            if (_error != null) Padding(padding: const EdgeInsets.all(8), child: Text('더 불러오기 실패: $_error', textAlign: TextAlign.center)),
            if (_cursor != null)
              Center(
                child: TextButton(onPressed: _loading ? null : () => _load(), child: Text(_loading ? '불러오는 중…' : '더 보기')),
              ),
          ],
        ]),
      ),
    );
  }

  void _setAesthetic(String? id) {
    setState(() => _aestheticId = id);
    _load(reset: true);
  }

  void _setWeather(String? code) {
    setState(() => _weatherCode = code);
    _load(reset: true);
  }

  Widget _chipRow(List<Widget> chips) => SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
        child: Row(children: [for (final c in chips) Padding(padding: const EdgeInsets.only(right: 6), child: c)]),
      );

  // Pinterest 스타일: 두 열에 번갈아 배치하고 높이를 조금씩 다르게 한다.
  Widget _masonry() {
    final left = <Widget>[], right = <Widget>[];
    for (var i = 0; i < _items.length; i++) {
      final card = _PostCard(post: _items[i], imageHeight: const [220.0, 170.0, 250.0, 190.0][i % 4], onTap: () => _openPost(_items[i]['id'] as String));
      (i.isEven ? left : right).add(card);
    }
    return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Expanded(child: Column(children: left)),
      Expanded(child: Column(children: right)),
    ]);
  }
}

class _PostCard extends StatelessWidget {
  const _PostCard({required this.post, required this.imageHeight, required this.onTap});
  final Json post;
  final double imageHeight;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final media = (post['media'] as List?) ?? const [];
    final author = post['author'] as Map?;
    return Card(
      clipBehavior: Clip.antiAlias,
      margin: const EdgeInsets.all(4),
      child: InkWell(
        onTap: onTap,
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          SizedBox(height: imageHeight, child: NetImage(media.isEmpty ? null : media.first, placeholderIcon: Icons.image_outlined)),
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 6, 8, 8),
            child: Row(children: [
              Expanded(child: Text('${author?['display_name'] ?? '이름 없음'}', overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12))),
              Icon(weatherIcon(post['weather_code'] as String?), size: 14, color: Colors.grey),
              const SizedBox(width: 6),
              Icon(post['liked_by_me'] == true ? Icons.favorite : Icons.favorite_border, size: 14, color: Colors.pink),
              Text(' ${post['like_count'] ?? 0}', style: const TextStyle(fontSize: 12)),
            ]),
          ),
        ]),
      ),
    );
  }
}
