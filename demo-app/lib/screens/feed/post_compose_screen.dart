import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';

import '../../config/labels.dart';
import '../../providers/providers.dart';
import '../../services/api.dart';
import '../../widgets/common.dart';

enum _Source { ootd, gallery }

/// 포스트 작성: 업로드 출처(캘린더 OOTD / 갤러리 사진) → 착용 아이템 연결(최소 1개) → 작성 → 업로드.
/// 업로드는 비공개 생성 → 공유 사진 업로드·검증 → 공개 전환 순서다(검증된 사진이 있어야 공개 가능).
class PostComposeScreen extends ConsumerStatefulWidget {
  const PostComposeScreen({super.key, this.sourceOotd});
  final Map<String, dynamic>? sourceOotd;

  @override
  ConsumerState<PostComposeScreen> createState() => _PostComposeScreenState();
}

class _PostComposeScreenState extends ConsumerState<PostComposeScreen> {
  _Source? _source;
  Json? _ootd;
  Uint8List? _photo; // 갤러리에서 고른 사진(OOTD에 사진이 없을 때도 사용)
  final Set<String> _garmentIds = {};
  bool _writing = false; // false: 출처·아이템 단계, true: 작성 단계
  Future<dynamic>? _ootdList; // 다시 그릴 때마다 재조회하지 않도록 보관

  String? _aestheticId;
  String _weatherCode = 'clear';
  final _temperature = TextEditingController();
  final _caption = TextEditingController();

  // 업로드 진행 상태. 실패 후 다시 시도하면 만들어 둔 postId·mediaId부터 이어 간다.
  static const _steps = ['게시물 생성', '사진 업로드', '사진 검증', '공개'];
  int _done = 0;
  String? _postId;
  Json? _media;
  bool _uploading = false;
  Object? _uploadError;
  final _createKey = api.newIdempotencyKey();
  final _mediaKey = api.newIdempotencyKey();
  final _completeKey = api.newIdempotencyKey();

  @override
  void initState() {
    super.initState();
    if (widget.sourceOotd != null) {
      _source = _Source.ootd;
      _useOotd(widget.sourceOotd!);
    }
  }

  void _useOotd(Json ootd) {
    setState(() {
      _ootd = ootd;
      _garmentIds
        ..clear()
        ..addAll((ootd['garment_ids'] as List).cast<String>());
    });
  }

  Future<void> _pickPhoto() async {
    final file = await ImagePicker().pickImage(source: ImageSource.gallery, maxWidth: 1600, imageQuality: 85);
    if (file == null) return;
    final bytes = await file.readAsBytes();
    setState(() => _photo = bytes);
  }

  bool get _hasPhoto => _photo != null || (_source == _Source.ootd && _ootd?['photo'] != null);
  // 디지털 옷장 아이템 최소 1개 연결 필수 + 공개하려면 사진 1장 필요.
  bool get _canNext => _garmentIds.isNotEmpty && _hasPhoto;

  Future<void> _upload() async {
    setState(() {
      _uploading = true;
      _uploadError = null;
    });
    try {
      if (_postId == null) {
        final temp = double.tryParse(_temperature.text.trim());
        final post = (await api.post('/feed', idempotencyKey: _createKey, body: {
          'caption': _caption.text,
          'aesthetic_id': _aestheticId,
          'weather_code': _weatherCode,
          'temperature_c': temp,
          'visibility': 'private',
          if (_source == _Source.ootd) 'source_ootd_id': _ootd!['id'],
          'garment_ids': _garmentIds.toList(),
        })) as Json;
        setState(() {
          _postId = post['id'] as String;
          _done = 1;
        });
      }
      if (_done < 3) {
        final bytes = _photo ?? await api.download((_ootd!['photo'] as Map)['url'] as String);
        if (_media == null) {
          final media = (await api.post('/feed/$_postId/media', idempotencyKey: _mediaKey,
              body: {'content_type': guessContentType(bytes), 'file_size': bytes.length})) as Json;
          setState(() => _media = media);
        }
        if (_done < 2) {
          await api.uploadSigned(_media!['upload'] as Json, bytes);
          setState(() => _done = 2);
        }
        await api.post('/feed/$_postId/media/${_media!['media_id']}/complete-upload', idempotencyKey: _completeKey);
        setState(() => _done = 3);
      }
      await api.patch('/feed/$_postId', {'visibility': 'public'});
      setState(() => _done = 4);
      if (mounted) {
        showSnack(context, '피드에 올렸어요');
        context.pushReplacement('/feed/post/$_postId');
      }
    } catch (e) {
      if (mounted) setState(() => _uploadError = e);
    } finally {
      if (mounted) setState(() => _uploading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final profile = ref.watch(profileProvider).value;
    if (_aestheticId == null && profile != null) {
      final mine = myAestheticIds(profile);
      if (mine.isNotEmpty) _aestheticId = mine.first;
    }
    return Scaffold(
      appBar: AppBar(
        title: Text(_writing ? '포스트 작성' : '업로드 출처'),
        leading: _writing && _postId == null ? BackButton(onPressed: () => setState(() => _writing = false)) : null,
        actions: const [ApiLogButton()],
      ),
      body: _writing ? _writeStep() : _sourceStep(),
    );
  }

  // ---- 1단계: 출처와 연결 아이템 ----
  Widget _sourceStep() => Column(children: [
        Expanded(
          child: ListView(padding: const EdgeInsets.all(16), children: [
            SegmentedButton<_Source>(
              segments: const [
                ButtonSegment(value: _Source.ootd, icon: Icon(Icons.calendar_month), label: Text('캘린더 OOTD')),
                ButtonSegment(value: _Source.gallery, icon: Icon(Icons.photo_library), label: Text('갤러리 사진')),
              ],
              emptySelectionAllowed: true,
              selected: {?_source},
              onSelectionChanged: (s) => setState(() {
                _source = s.isEmpty ? null : s.first;
                _ootd = null;
                _photo = null;
                _garmentIds.clear();
              }),
            ),
            const SizedBox(height: 16),
            if (_source == _Source.ootd) ..._ootdSource(),
            if (_source == _Source.gallery) ..._gallerySource(),
            if (_source == null) const Text('어디에서 가져올지 골라 주세요.'),
          ]),
        ),
        SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(children: [
              if (_source != null && _garmentIds.isEmpty)
                const Text('디지털 옷장 아이템을 최소 1개 연결해야 해요', style: TextStyle(color: Colors.redAccent, fontSize: 12)),
              if (_source != null && _garmentIds.isNotEmpty && !_hasPhoto)
                const Text('공개하려면 대표 사진이 1장 필요해요', style: TextStyle(color: Colors.redAccent, fontSize: 12)),
              SizedBox(
                width: double.infinity,
                child: FilledButton(onPressed: _canNext ? () => setState(() => _writing = true) : null, child: const Text('다음')),
              ),
            ]),
          ),
        ),
      ]);

  List<Widget> _ootdSource() {
    if (_ootd != null) {
      return [
        Card(
          child: ListTile(
            leading: SizedBox(width: 56, height: 56, child: NetImage(_ootd!['photo'], placeholderIcon: Icons.image_outlined)),
            title: Text('${_ootd!['worn_on']} OOTD'),
            subtitle: Text('아이템 ${_garmentIds.length}개 자동 연결 · 날씨는 직접 선택'),
            trailing: widget.sourceOotd == null ? TextButton(onPressed: () => setState(() => _ootd = null), child: const Text('바꾸기')) : null,
          ),
        ),
        Wrap(spacing: 8, children: [for (final id in _garmentIds) GarmentThumb(id)]),
        if (_ootd!['photo'] == null) ...[
          const SizedBox(height: 12),
          const Text('이 OOTD에는 사진이 없어요. 갤러리에서 대표 사진을 골라 주세요.'),
          _photoPicker(),
        ],
      ];
    }
    return [
      const Text('공유할 OOTD를 고르세요', style: TextStyle(fontWeight: FontWeight.bold)),
      FutureBuilder<dynamic>(
        future: _ootdList ??= api.get('/ootd', query: {'limit': '20'}),
        builder: (context, snap) {
          if (snap.hasError) return ErrorPanel(snap.error!);
          if (!snap.hasData) return const Padding(padding: EdgeInsets.all(24), child: Center(child: CircularProgressIndicator()));
          final items = ((snap.data as Json)['items'] as List).cast<Json>();
          if (items.isEmpty) return const Padding(padding: EdgeInsets.all(16), child: Text('OOTD 기록이 없어요. 캘린더에서 먼저 기록해 주세요.'));
          return Column(children: [
            for (final o in items)
              ListTile(
                leading: SizedBox(width: 48, height: 48, child: NetImage(o['photo'], placeholderIcon: Icons.image_outlined)),
                title: Text('${o['worn_on']}'),
                subtitle: Text('아이템 ${(o['garment_ids'] as List).length}개${o['note'] != null ? ' · ${o['note']}' : ''}', overflow: TextOverflow.ellipsis),
                onTap: () => _useOotd(o),
              ),
          ]);
        },
      ),
    ];
  }

  List<Widget> _gallerySource() {
    final garments = ref.watch(garmentsProvider);
    return [
      _photoPicker(),
      const SizedBox(height: 16),
      Text('착용 아이템 선택 (${_garmentIds.length}개)', style: const TextStyle(fontWeight: FontWeight.bold)),
      const SizedBox(height: 8),
      AsyncBody<List<Json>>(
        value: garments,
        onRetry: () => ref.invalidate(garmentsProvider),
        builder: (list) => list.isEmpty
            ? const Text('옷장이 비어 있어요. 옷을 먼저 등록해 주세요.')
            : GridView.count(
                crossAxisCount: 4,
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                mainAxisSpacing: 6,
                crossAxisSpacing: 6,
                children: [
                  for (final g in list)
                    _SelectableTile(
                      selected: _garmentIds.contains(g['id']),
                      onTap: () => setState(() => _garmentIds.contains(g['id']) ? _garmentIds.remove(g['id']) : _garmentIds.add(g['id'] as String)),
                      child: NetImage(g['image']),
                    ),
                ],
              ),
      ),
    ];
  }

  Widget _photoPicker() => Row(children: [
        Container(
          width: 96,
          height: 128,
          decoration: BoxDecoration(color: Colors.grey.shade200, borderRadius: BorderRadius.circular(8)),
          clipBehavior: Clip.antiAlias,
          child: _photo == null ? const Icon(Icons.image_outlined, color: Colors.grey) : Image.memory(_photo!, fit: BoxFit.cover),
        ),
        const SizedBox(width: 12),
        OutlinedButton.icon(onPressed: _pickPhoto, icon: const Icon(Icons.photo_library), label: Text(_photo == null ? '사진 선택' : '다시 선택')),
      ]);

  // ---- 2단계: 작성과 업로드 ----
  Widget _writeStep() {
    final aesthetics = ref.watch(aestheticsProvider).value ?? const <Json>[];
    final locked = _postId != null; // 이미 생성된 뒤에는 본문 값을 바꾸지 않는다(재시도는 같은 게시물로)
    return ListView(padding: const EdgeInsets.all(16), children: [
      AspectRatio(
        aspectRatio: 3 / 4,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: _photo != null ? Image.memory(_photo!, fit: BoxFit.cover) : NetImage(_ootd?['photo'], placeholderIcon: Icons.image_outlined),
        ),
      ),
      const SizedBox(height: 12),
      const Text('연결 아이템', style: TextStyle(fontWeight: FontWeight.bold)),
      const SizedBox(height: 6),
      Wrap(spacing: 8, runSpacing: 8, children: [for (final id in _garmentIds) GarmentThumb(id)]),
      const SizedBox(height: 12),
      DropdownButtonFormField<String>(
        initialValue: _aestheticId,
        decoration: const InputDecoration(labelText: '추구미'),
        items: [for (final a in aesthetics) DropdownMenuItem(value: a['id'] as String, child: Text(a['display_name'] as String))],
        onChanged: locked ? null : (v) => setState(() => _aestheticId = v),
      ),
      Row(children: [
        Expanded(
          child: DropdownButtonFormField<String>(
            initialValue: _weatherCode,
            decoration: const InputDecoration(labelText: '날씨'),
            items: [for (final e in weatherCodes.entries) DropdownMenuItem(value: e.key, child: Text(e.value))],
            onChanged: locked ? null : (v) => setState(() => _weatherCode = v ?? 'clear'),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: TextField(
            controller: _temperature,
            enabled: !locked,
            decoration: const InputDecoration(labelText: '온도(°C, 선택)'),
            keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
          ),
        ),
      ]),
      TextField(controller: _caption, enabled: !locked, decoration: const InputDecoration(labelText: '캡션'), maxLines: 3, maxLength: 2000),
      const SizedBox(height: 8),
      if (_postId != null || _uploading || _uploadError != null)
        Card(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(children: [
              for (var i = 0; i < _steps.length; i++)
                Row(children: [
                  Icon(
                    i < _done ? Icons.check_circle : (i == _done && _uploadError != null ? Icons.error : Icons.radio_button_unchecked),
                    color: i < _done ? Colors.green : (i == _done && _uploadError != null ? Colors.redAccent : Colors.grey),
                    size: 20,
                  ),
                  const SizedBox(width: 8),
                  Text(_steps[i]),
                  if (i == _done && _uploading) ...[const SizedBox(width: 8), const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))],
                ]),
              if (_uploadError != null) ...[
                const SizedBox(height: 8),
                Text(
                  _uploadError is ApiException ? '${(_uploadError as ApiException).message} (${(_uploadError as ApiException).code})' : '$_uploadError',
                  style: const TextStyle(color: Colors.redAccent),
                ),
                const Text('입력은 그대로 남아 있어요. 실패한 단계부터 다시 시도합니다.', style: TextStyle(fontSize: 12)),
              ],
            ]),
          ),
        ),
      const SizedBox(height: 8),
      FilledButton.icon(
        onPressed: _uploading || _aestheticId == null ? null : _upload,
        icon: Icon(_uploadError != null ? Icons.refresh : Icons.upload),
        label: Text(_uploadError != null ? '다시 시도' : '업로드'),
      ),
    ]);
  }
}

class _SelectableTile extends StatelessWidget {
  const _SelectableTile({required this.selected, required this.onTap, required this.child});
  final bool selected;
  final VoidCallback onTap;
  final Widget child;

  @override
  Widget build(BuildContext context) => GestureDetector(
        onTap: onTap,
        child: Stack(fit: StackFit.expand, children: [
          ClipRRect(borderRadius: BorderRadius.circular(8), child: child),
          if (selected)
            Container(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Theme.of(context).colorScheme.primary, width: 3),
              ),
              alignment: Alignment.topRight,
              child: Icon(Icons.check_circle, color: Theme.of(context).colorScheme.primary),
            ),
        ]),
      );
}
