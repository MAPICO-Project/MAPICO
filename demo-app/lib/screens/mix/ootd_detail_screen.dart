import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../services/api.dart';
import '../../widgets/common.dart';
import 'ootd_edit_screen.dart';

/// OOTD 상세(GET /ootd/{id}): 날짜·날씨·착용 의류·별점·메모·선택 사진 + 공유/수정/삭제.
class OotdDetailScreen extends ConsumerStatefulWidget {
  const OotdDetailScreen({super.key, required this.ootdId});
  final String ootdId;

  @override
  ConsumerState<OotdDetailScreen> createState() => _OotdDetailScreenState();
}

class _OotdDetailScreenState extends ConsumerState<OotdDetailScreen> {
  late Future<Json> _future = _load();

  Future<Json> _load() async => (await api.get('/ootd/${widget.ootdId}')) as Json;

  void _reload() => setState(() => _future = _load());

  Future<void> _delete() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('이 기록을 삭제할까요?'),
        content: const Text('이미 피드에 공유한 게시물은 자동으로 바뀌지 않아요.'),
        actions: [
          TextButton(onPressed: () => c.pop(false), child: const Text('취소')),
          FilledButton(onPressed: () => c.pop(true), child: const Text('삭제')),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await api.delete('/ootd/${widget.ootdId}', idempotent: true);
      if (!mounted) return;
      showSnack(context, '기록을 삭제했어요');
      context.pop(true);
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Future<void> _edit(Json ootd) async {
    final changed = await context.push<bool>('/mix/ootd-edit', extra: OotdEditArgs(existing: ootd));
    if (changed == true) _reload();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('OOTD 상세'), actions: const [ApiLogButton()]),
        body: FutureBuilder<Json>(
          future: _future,
          builder: (context, snap) {
            if (snap.hasError) return ErrorPanel(snap.error!, onRetry: _reload);
            if (!snap.hasData) return const Center(child: CircularProgressIndicator());
            final o = snap.data!;
            final items = (o['item_snapshot'] as List? ?? const []).cast<Json>();
            final rating = o['rating'] as int?;
            return ListView(padding: const EdgeInsets.only(bottom: 24), children: [
              if (o['photo'] != null)
                AspectRatio(aspectRatio: 3 / 4, child: NetImage(o['photo'], placeholderIcon: Icons.photo_outlined)),
              ListTile(leading: const Icon(Icons.event), title: Text(o['worn_on'] as String), subtitle: const Text('입은 날짜')),
              ListTile(
                leading: const Icon(Icons.cloud_outlined),
                title: Text(o['weather_snapshot_id'] != null ? '저장된 날씨 있음 (조회 API 없음)' : '날씨 기록 없음'),
              ),
              SectionTitle('착용 의류 (${items.length})'),
              SizedBox(
                height: 96,
                child: ListView(scrollDirection: Axis.horizontal, padding: const EdgeInsets.symmetric(horizontal: 12), children: [
                  for (final it in items)
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: it['unavailable'] == true
                          ? const SizedBox(width: 64, child: Column(children: [Icon(Icons.hide_image_outlined, size: 48, color: Colors.grey), Text('삭제된 옷', style: TextStyle(fontSize: 11))]))
                          : GarmentThumb(it['garment_id'] as String),
                    ),
                ]),
              ),
              const SectionTitle('별점'),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Row(children: [
                  for (var i = 1; i <= 5; i++) Icon(rating != null && i <= rating ? Icons.star : Icons.star_border, color: Colors.amber),
                  if (rating == null) const Text('  별점 없음'),
                ]),
              ),
              const SectionTitle('메모'),
              Padding(padding: const EdgeInsets.symmetric(horizontal: 16), child: Text((o['note'] as String?) ?? '메모 없음')),
              const SizedBox(height: 24),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  FilledButton.icon(onPressed: () => context.push('/feed/new', extra: o), icon: const Icon(Icons.share), label: const Text('피드에 공유')),
                  const SizedBox(height: 8),
                  Row(children: [
                    Expanded(child: OutlinedButton.icon(onPressed: () => _edit(o), icon: const Icon(Icons.edit), label: const Text('수정'))),
                    const SizedBox(width: 8),
                    Expanded(child: OutlinedButton.icon(onPressed: _delete, icon: const Icon(Icons.delete_outline), label: const Text('삭제'))),
                  ]),
                  const SizedBox(height: 8),
                  const Text('삭제·날짜 변경은 이미 공유한 피드를 바꾸지 않아요.', style: TextStyle(fontSize: 12, color: Colors.grey)),
                ]),
              ),
            ]);
          },
        ),
      );
}
