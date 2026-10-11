import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../config/labels.dart';
import '../../providers/providers.dart';
import '../../services/api.dart';
import '../../widgets/common.dart';

/// 의류 상세: 누끼·원본·카테고리·비고. 수정(PATCH, expected_version)·삭제(DELETE, Idempotency-Key).
class GarmentDetailScreen extends ConsumerStatefulWidget {
  const GarmentDetailScreen({super.key, required this.garmentId});
  final String garmentId;

  @override
  ConsumerState<GarmentDetailScreen> createState() => _GarmentDetailScreenState();
}

class _GarmentDetailScreenState extends ConsumerState<GarmentDetailScreen> {
  Json? _garment;
  Object? _error;
  bool _editing = false;
  bool _busy = false;
  String? _category;
  final _sub = TextEditingController();
  final _note = TextEditingController();

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _error = null);
    try {
      final g = (await api.get('/garments/${widget.garmentId}')) as Json;
      final attrs = g['attributes'] as Map;
      setState(() {
        _garment = g;
        _category = attrs['category'] as String?;
        _sub.text = attrs['subcategory'] as String? ?? '';
        _note.text = attrs['note'] as String? ?? '';
      });
    } catch (e) {
      setState(() => _error = e);
    }
  }

  Future<void> _save() async {
    setState(() => _busy = true);
    try {
      final g = (await api.patch('/garments/${widget.garmentId}', {
        'expected_version': _garment!['version'],
        'attributes': {
          'category': _category,
          'subcategory': _sub.text.trim().isEmpty ? null : _sub.text.trim(),
          'note': _note.text.trim().isEmpty ? null : _note.text.trim(),
        },
      })) as Json;
      ref.invalidate(garmentsProvider);
      setState(() {
        _garment = g;
        _editing = false;
      });
      if (mounted) showSnack(context, '저장했어요');
    } on ApiException catch (e) {
      if (!mounted) return;
      if (e.status == 409) {
        showSnack(context, '다른 곳에서 먼저 수정됐어요. 최신 내용으로 다시 불러옵니다.');
        await _load();
      } else {
        showError(context, e);
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _delete() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('옷을 삭제할까요?'),
        content: const Text('옷장에서 사라지고 추천에 쓰이지 않아요. 지난 OOTD 기록은 "삭제된 옷"으로 남아요.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('취소')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('삭제')),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await api.delete('/garments/${widget.garmentId}', idempotent: true);
      ref.invalidate(garmentsProvider);
      if (mounted) {
        showSnack(context, '삭제했어요');
        context.pop();
      }
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final g = _garment;
    return Scaffold(
      appBar: AppBar(title: const Text('의류 상세'), actions: [
        if (g != null && !_editing) IconButton(tooltip: '수정', onPressed: () => setState(() => _editing = true), icon: const Icon(Icons.edit_outlined)),
        if (g != null) IconButton(tooltip: '삭제', onPressed: _delete, icon: const Icon(Icons.delete_outline)),
      ]),
      body: _error != null
          ? ErrorPanel(_error!, onRetry: _load)
          : g == null
              ? const Center(child: CircularProgressIndicator())
              : ListView(padding: const EdgeInsets.all(16), children: [
                  Row(children: [
                    Expanded(child: _imageBox('누끼', g['image'])),
                    const SizedBox(width: 8),
                    Expanded(child: _imageBox('원본', g['original_image'])),
                  ]),
                  const SizedBox(height: 16),
                  if (!_editing) ...[
                    _row('카테고리', categoryLabel((g['attributes'] as Map)['category'] as String?)),
                    _row('하위분류', (g['attributes'] as Map)['subcategory'] as String? ?? '-'),
                    _row('비고', (g['attributes'] as Map)['note'] as String? ?? '-'),
                  ] else ...[
                    DropdownButtonFormField<String>(
                      initialValue: _category,
                      decoration: const InputDecoration(labelText: '카테고리'),
                      items: [for (final e in garmentCategories.entries) DropdownMenuItem(value: e.key, child: Text(e.value))],
                      onChanged: (v) => setState(() => _category = v),
                    ),
                    TextField(controller: _sub, decoration: const InputDecoration(labelText: '하위분류 (예: 셔츠, 슬랙스)'), maxLength: 80),
                    TextField(controller: _note, decoration: const InputDecoration(labelText: '비고'), maxLength: 1000, maxLines: 3, minLines: 1),
                    Row(children: [
                      Expanded(child: OutlinedButton(onPressed: _busy ? null : () { setState(() => _editing = false); _load(); }, child: const Text('취소'))),
                      const SizedBox(width: 8),
                      Expanded(child: FilledButton(onPressed: _busy || _category == null ? null : _save, child: const Text('저장'))),
                    ]),
                  ],
                  const SizedBox(height: 16),
                  const Text('색상·추구미 자동 태그는 화면에 보여 주지 않아요(내부 분석에만 사용).', style: TextStyle(fontSize: 12, color: Colors.grey)),
                  Text('version ${g['version']}', style: const TextStyle(fontSize: 11, color: Colors.grey)),
                ]),
    );
  }

  Widget _imageBox(String label, dynamic asset) => Column(children: [
        AspectRatio(aspectRatio: 1, child: ClipRRect(borderRadius: BorderRadius.circular(8), child: NetImage(asset))),
        Text(label, style: const TextStyle(fontSize: 12)),
      ]);

  Widget _row(String label, String value) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          SizedBox(width: 80, child: Text(label, style: const TextStyle(color: Colors.grey))),
          Expanded(child: Text(value)),
        ]),
      );
}
