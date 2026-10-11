import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';

import '../../config/labels.dart';
import '../../providers/providers.dart';
import '../../services/api.dart';
import '../../widgets/common.dart';

/// OOTD 작성/수정 인자. existing이 있으면 수정(PATCH), 없으면 새 기록(POST).
class OotdEditArgs {
  const OotdEditArgs({this.date, this.garmentIds = const [], this.savedOutfitId, this.existing});
  final String? date;
  final List<String> garmentIds;
  final String? savedOutfitId;
  final Map<String, dynamic>? existing;
}

/// OOTD 기록 작성: 아이템 확인 → 별점 → 메모 → (선택 사진) → 저장.
class OotdEditScreen extends ConsumerStatefulWidget {
  const OotdEditScreen({super.key, this.args});
  final OotdEditArgs? args;

  @override
  ConsumerState<OotdEditScreen> createState() => _OotdEditScreenState();
}

class _OotdEditScreenState extends ConsumerState<OotdEditScreen> {
  late DateTime _date;
  late final Set<String> _garments;
  int? _rating;
  late final TextEditingController _note;
  Uint8List? _photo;
  bool _busy = false;
  final String _idemKey = api.newIdempotencyKey();

  Json? get _existing => widget.args?.existing;

  @override
  void initState() {
    super.initState();
    final existing = _existing;
    final today = DateTime.now();
    _date = DateTime.tryParse((existing?['worn_on'] ?? widget.args?.date ?? '') as String) ?? DateTime(today.year, today.month, today.day);
    _garments = {...(existing != null ? (existing['garment_ids'] as List).cast<String>() : widget.args?.garmentIds ?? const <String>[])};
    _rating = existing?['rating'] as int?;
    _note = TextEditingController(text: existing?['note'] as String? ?? '');
  }

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  Future<void> _pickDate() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: _date,
      firstDate: DateTime(now.year - 2),
      lastDate: now, // 미래 날짜 착용 기록은 서버가 422로 거절한다.
    );
    if (picked != null) setState(() => _date = picked);
  }

  Future<void> _pickPhoto() async {
    final file = await ImagePicker().pickImage(source: ImageSource.gallery, maxWidth: 1600, imageQuality: 85);
    if (file == null) return;
    final bytes = await file.readAsBytes();
    setState(() => _photo = bytes);
  }

  /// 선택 사진: POST /media-uploads → signed PUT → complete-upload → photo_upload_id.
  Future<String> _uploadPhoto(Uint8List bytes) async {
    final created = (await api.post('/media-uploads', idempotent: true, body: {
      'purpose': 'ootd_photo',
      'content_type': guessContentType(bytes),
      'file_size': bytes.length,
    })) as Json;
    await api.uploadSigned(created['upload'] as Json, bytes);
    await api.post('/media-uploads/${created['id']}/complete-upload');
    return created['id'] as String;
  }

  Future<void> _save() async {
    setState(() => _busy = true);
    final note = _note.text.trim().isEmpty ? null : _note.text.trim();
    try {
      final photoId = _photo == null ? null : await _uploadPhoto(_photo!);
      final existing = _existing;
      if (existing == null) {
        final created = (await api.post('/ootd', idempotencyKey: _idemKey, body: {
          'worn_on': ymd(_date),
          'garment_ids': _garments.toList(),
          if (widget.args?.savedOutfitId != null) 'saved_outfit_id': widget.args!.savedOutfitId,
          'rating': _rating,
          'note': note,
          'photo_upload_id': ?photoId,
        })) as Json;
        if (!mounted) return;
        showSnack(context, 'OOTD를 기록했어요');
        context.pushReplacement('/mix/ootd/${created['id']}');
      } else {
        await api.patch('/ootd/${existing['id']}', {
          'expected_version': existing['version'],
          'worn_on': ymd(_date),
          'garment_ids': _garments.toList(),
          'rating': _rating,
          'note': note,
          'photo_upload_id': ?photoId,
        });
        if (!mounted) return;
        showSnack(context, 'OOTD를 수정했어요');
        context.pop(true);
      }
    } on ApiException catch (e) {
      if (!mounted) return;
      if (e.status == 422) {
        showSnack(context, '입력을 확인해 주세요: 미래 날짜·삭제된 옷·별점 범위(1~5)는 저장할 수 없어요 (${e.code})');
      } else if (e.status == 409) {
        showSnack(context, '다른 곳에서 먼저 바뀌었어요. 다시 열어 주세요 (${e.code})');
      } else {
        showError(context, e);
      }
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final garments = ref.watch(garmentsProvider);
    final existingPhoto = _existing?['photo'];
    return Scaffold(
      appBar: AppBar(title: Text(_existing == null ? 'OOTD 기록 작성' : 'OOTD 수정'), actions: const [ApiLogButton()]),
      body: ListView(padding: const EdgeInsets.only(bottom: 24), children: [
        ListTile(
          leading: const Icon(Icons.event),
          title: Text(ymd(_date)),
          subtitle: const Text('입은 날짜 (오늘까지)'),
          trailing: const Icon(Icons.edit_calendar),
          onTap: _pickDate,
        ),
        SectionTitle('아이템 확인 (${_garments.length}벌, 1벌 이상)'),
        AsyncBody<List<Json>>(
          value: garments,
          onRetry: () => ref.invalidate(garmentsProvider),
          builder: (all) => all.isEmpty
              ? const Padding(padding: EdgeInsets.all(16), child: Text('옷장이 비어 있어요. 먼저 옷을 등록해 주세요.'))
              : GridView.count(
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  crossAxisCount: 4,
                  mainAxisSpacing: 6,
                  crossAxisSpacing: 6,
                  children: [
                    for (final g in all)
                      InkWell(
                        onTap: () => setState(() => _garments.contains(g['id']) ? _garments.remove(g['id']) : _garments.add(g['id'] as String)),
                        child: Stack(fit: StackFit.expand, children: [
                          ClipRRect(borderRadius: BorderRadius.circular(6), child: NetImage(g['image'])),
                          if (_garments.contains(g['id']))
                            Container(
                              decoration: BoxDecoration(borderRadius: BorderRadius.circular(6), border: Border.all(color: Theme.of(context).colorScheme.primary, width: 3)),
                              alignment: Alignment.topRight,
                              child: Icon(Icons.check_circle, color: Theme.of(context).colorScheme.primary, size: 18),
                            ),
                        ]),
                      ),
                  ],
                ),
        ),
        const SectionTitle('별점 (선택)'),
        Row(mainAxisAlignment: MainAxisAlignment.center, children: [
          for (var i = 1; i <= 5; i++)
            IconButton(
              icon: Icon(_rating != null && i <= _rating! ? Icons.star : Icons.star_border, color: Colors.amber),
              onPressed: () => setState(() => _rating = _rating == i ? null : i),
            ),
        ]),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: TextField(controller: _note, maxLines: 3, maxLength: 1000, decoration: const InputDecoration(labelText: '메모', border: OutlineInputBorder())),
        ),
        const SectionTitle('선택 사진 (1장)'),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(children: [
            SizedBox(
              width: 96,
              height: 128,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: _photo != null ? Image.memory(_photo!, fit: BoxFit.cover) : NetImage(existingPhoto, placeholderIcon: Icons.photo_outlined),
              ),
            ),
            const SizedBox(width: 12),
            OutlinedButton.icon(onPressed: _pickPhoto, icon: const Icon(Icons.photo_library_outlined), label: Text(_photo == null ? '사진 고르기' : '다시 고르기')),
          ]),
        ),
      ]),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: FilledButton(
            onPressed: _garments.isNotEmpty && !_busy ? _save : null,
            child: Text(_busy ? '저장 중…' : '저장'),
          ),
        ),
      ),
    );
  }
}
