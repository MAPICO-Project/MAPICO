import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../config/labels.dart';
import '../../providers/providers.dart';
import '../../services/api.dart';
import '../../widgets/common.dart';

/// 포스트 상세: 사용자·일시·추구미/날씨·대표 이미지·연결 아이템·좋아요·따라입기. GET /feed/{id}.
class PostDetailScreen extends ConsumerStatefulWidget {
  const PostDetailScreen({super.key, required this.postId});
  final String postId;

  @override
  ConsumerState<PostDetailScreen> createState() => _PostDetailScreenState();
}

class _PostDetailScreenState extends ConsumerState<PostDetailScreen> {
  Json? _post;
  Object? _error;
  bool _mimicBusy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _error = null);
    try {
      final post = (await api.get('/feed/${widget.postId}')) as Json;
      if (mounted) setState(() => _post = post);
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  bool get _mine => _post?['author']?['id'] == Supabase.instance.client.auth.currentUser?.id;

  // 낙관적 갱신: 먼저 화면을 바꾸고 실패하면 되돌린다. PUT/DELETE 모두 멱등(204).
  Future<void> _toggleLike() async {
    final post = _post!;
    final liked = post['liked_by_me'] == true;
    final count = (post['like_count'] as num?)?.toInt() ?? 0;
    setState(() => _post = {...post, 'liked_by_me': !liked, 'like_count': count + (liked ? -1 : 1)});
    try {
      if (liked) {
        await api.delete('/feed/${widget.postId}/like');
      } else {
        await api.put('/feed/${widget.postId}/like');
        if (mounted) showSnack(context, '좋아요한 코디는 마이페이지 아카이브에 저장돼요');
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _post = post);
      showError(context, e);
    }
  }

  Future<void> _mimic() async {
    setState(() => _mimicBusy = true);
    try {
      final job = (await api.post('/mimic-jobs', body: {'post_id': widget.postId}, idempotent: true)) as Json;
      if (mounted) context.push('/feed/mimic/${job['id']}');
    } on ApiException catch (e) {
      if (!mounted) return;
      if (e.code == 'MIMIC_CONFLICT') {
        showSnack(context, '연결된 옷이 없는 예전 포스트라 따라입기를 할 수 없어요 (MIMIC_CONFLICT)');
      } else {
        showError(context, e);
      }
    } finally {
      if (mounted) setState(() => _mimicBusy = false);
    }
  }

  Future<void> _editCaption() async {
    final controller = TextEditingController(text: _post!['caption'] as String? ?? '');
    final caption = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('캡션 수정'),
        content: TextField(controller: controller, maxLines: 4, maxLength: 2000),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('취소')),
          FilledButton(onPressed: () => Navigator.pop(context, controller.text), child: const Text('저장')),
        ],
      ),
    );
    if (caption == null) return;
    await _patch({'caption': caption});
  }

  Future<void> _patch(Json body) async {
    try {
      final post = (await api.patch('/feed/${widget.postId}', body)) as Json;
      if (mounted) setState(() => _post = post);
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Future<void> _delete() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('포스트 삭제'),
        content: const Text('피드에서 내립니다. OOTD 기록은 그대로 남아요.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('취소')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('삭제')),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await api.delete('/feed/${widget.postId}');
      if (mounted) context.pop();
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final post = _post;
    return Scaffold(
      appBar: AppBar(title: const Text('포스트'), actions: [
        if (post != null && _mine)
          PopupMenuButton<String>(
            onSelected: (v) => switch (v) {
              'edit' => _editCaption(),
              'visibility' => _patch({'visibility': post['visibility'] == 'public' ? 'private' : 'public'}),
              _ => _delete(),
            },
            itemBuilder: (_) => [
              const PopupMenuItem(value: 'edit', child: Text('수정')),
              PopupMenuItem(value: 'visibility', child: Text(post['visibility'] == 'public' ? '비공개로 전환' : '공개로 전환')),
              const PopupMenuItem(value: 'delete', child: Text('삭제')),
            ],
          ),
        const ApiLogButton(),
      ]),
      body: _error != null
          ? ErrorPanel(_error!, onRetry: _load)
          : post == null
              ? const Center(child: CircularProgressIndicator())
              : _body(post),
    );
  }

  Widget _body(Json post) {
    final aesthetics = ref.watch(aestheticsProvider).value;
    final media = (post['media'] as List?) ?? const [];
    final linked = ((post['linked_items'] as List?) ?? const []).cast<Json>()
      ..sort((a, b) => (a['position'] as num).compareTo(b['position'] as num));
    final created = DateTime.tryParse(post['created_at'] as String? ?? '')?.toLocal();
    final temp = post['temperature_c'];
    return ListView(children: [
      ListTile(
        leading: const CircleAvatar(child: Icon(Icons.person)),
        title: Text('${post['author']?['display_name'] ?? '이름 없음'}'),
        subtitle: Text(created == null ? '' : '${ymd(created)} ${created.hour.toString().padLeft(2, '0')}:${created.minute.toString().padLeft(2, '0')}'),
        trailing: post['visibility'] == 'private' ? const Chip(label: Text('비공개')) : null,
      ),
      AspectRatio(
        aspectRatio: 3 / 4,
        child: media.isEmpty
            ? const NetImage(null, placeholderIcon: Icons.image_outlined)
            : PageView(children: [for (final m in media) NetImage(m, fit: BoxFit.contain)]),
      ),
      if (media.length > 1) Center(child: Text('사진 ${media.length}장 · 옆으로 넘기기', style: const TextStyle(fontSize: 12))),
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
        child: Wrap(spacing: 8, runSpacing: 4, children: [
          Chip(avatar: const Icon(Icons.style, size: 16), label: Text(aestheticName(aesthetics, post['aesthetic_id'] as String?))),
          Chip(
            avatar: Icon(weatherIcon(post['weather_code'] as String?), size: 16),
            label: Text('${weatherLabel(post['weather_code'] as String?)}${temp is num ? ' · ${temp.toStringAsFixed(0)}°C' : ''}'),
          ),
        ]),
      ),
      if ((post['caption'] as String? ?? '').isNotEmpty)
        Padding(padding: const EdgeInsets.fromLTRB(16, 8, 16, 0), child: Text(post['caption'] as String)),
      const SectionTitle('연결 아이템', trailing: ProposalBadge(tooltip: '연결 아이템 사진 공개 방식 — PM 협의')),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Wrap(spacing: 8, children: [
          if (linked.isEmpty) const Text('연결된 아이템 없음'),
          for (final item in linked) Chip(label: Text(categoryLabel(item['category'] as String?))),
        ]),
      ),
      const Padding(
        padding: EdgeInsets.fromLTRB(16, 4, 16, 0),
        child: Text('연결 아이템은 카테고리만 공개돼요(옷장 사진은 비공개).', style: TextStyle(fontSize: 12, color: Colors.grey)),
      ),
      Padding(
        padding: const EdgeInsets.all(16),
        child: Row(children: [
          OutlinedButton.icon(
            onPressed: _toggleLike,
            icon: Icon(post['liked_by_me'] == true ? Icons.favorite : Icons.favorite_border, color: Colors.pink),
            label: Text('${post['like_count'] ?? 0}'),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: FilledButton.icon(
              onPressed: _mimicBusy || _mine ? null : _mimic,
              icon: _mimicBusy ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.auto_awesome),
              label: Text(_mine ? '내 포스트' : '내 옷장으로 따라입기'),
            ),
          ),
        ]),
      ),
    ]);
  }
}
