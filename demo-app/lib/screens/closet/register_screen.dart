import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';

import '../../config/labels.dart';
import '../../providers/providers.dart';
import '../../services/api.dart';
import '../../widgets/common.dart';

enum _Step { guide, preview, analyzing, failed, review, done }

/// 옷 등록(USER_FLOWS §3): 촬영 가이드 → 원샷 촬영/앨범 → 이미지 확인 → 업로드·AI 분석 → 결과 검토·저장.
/// 업로드는 배치 생성 → signed URL PUT → complete-upload(서버가 magic bytes 검증) → 분석 job 생성 순서다.
class RegisterScreen extends ConsumerStatefulWidget {
  const RegisterScreen({super.key});

  @override
  ConsumerState<RegisterScreen> createState() => _RegisterScreenState();
}

class _RegisterScreenState extends ConsumerState<RegisterScreen> {
  _Step _step = _Step.guide;
  Uint8List? _bytes;
  String? _batchId;
  Json? _job;
  String _status = '';
  String? _fallbackNote;
  Object? _error;
  Timer? _poll;
  int _jobReadErrors = 0;
  bool _partial = false;
  bool _busy = false;

  // 검토 상태: draft id → 최신 draft / 저장 포함 여부
  List<Json> _drafts = [];
  final Map<String, bool> _include = {};

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  Future<void> _pick(ImageSource source) async {
    try {
      final file = await ImagePicker().pickImage(source: source, maxWidth: 2400, imageQuality: 90);
      if (file == null) return;
      final bytes = await file.readAsBytes();
      setState(() {
        _bytes = bytes;
        _step = _Step.preview;
        _batchId = null;
        _job = null;
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      if (source == ImageSource.camera) {
        await showDialog<void>(
          context: context,
          builder: (c) => AlertDialog(
            title: const Text('카메라 권한이 없어요'),
            content: const Text('설정에서 카메라 권한을 허용한 뒤 다시 시도해 주세요. 앨범에서 가져올 수도 있어요.'),
            actions: [
              TextButton(onPressed: () => Navigator.pop(c), child: const Text('닫기')),
              FilledButton(onPressed: () => Navigator.pop(c), child: const Text('설정으로 이동')),
            ],
          ),
        );
      } else {
        showError(context, e);
      }
    }
  }

  void _restart() {
    _poll?.cancel();
    setState(() {
      _step = _Step.guide;
      _bytes = null;
      _batchId = null;
      _job = null;
      _error = null;
      _fallbackNote = null;
      _drafts = [];
      _include.clear();
    });
  }

  /// 업로드 → 분석 요청. 이미 업로드한 배치가 있으면(고지 동의 후 재시도 등) 그 배치로 job만 만든다.
  Future<void> _startAnalysis() async {
    final bytes = _bytes!;
    setState(() {
      _busy = true;
      _status = '업로드 중…';
      _step = _Step.analyzing;
      _error = null;
    });
    try {
      if (_batchId == null) {
        final created = (await api.post('/garment-batches',
            idempotent: true, body: {'content_type': guessContentType(bytes), 'file_size': bytes.length})) as Json;
        final batchId = (created['batch'] as Json)['id'] as String;
        await api.uploadSigned(created['upload'] as Json, bytes);
        await api.post('/garment-batches/$batchId/complete-upload', idempotent: true);
        _batchId = batchId;
      }
      await _createJob(() => api.post('/garment-batches/$_batchId/analysis-jobs', idempotent: true));
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e;
          _step = _Step.failed;
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _createJob(Future<dynamic> Function() request) async {
    try {
      final job = (await request()) as Json;
      _beginPolling(job);
    } on ApiException catch (e) {
      if (!e.aiNoticeRequired || !mounted) rethrow;
      // 403 AI_NOTICE_REQUIRED → 가입 고지 화면. 동의하면 같은 배치로 다시 요청.
      final ok = await context.push<bool>('/notice?from=analysis');
      if (ok == true) {
        final job = (await request()) as Json;
        _beginPolling(job);
      } else if (mounted) {
        setState(() {
          _error = e;
          _step = _Step.failed;
        });
      }
    }
  }

  void _beginPolling(Json job) {
    _poll?.cancel();
    _jobReadErrors = 0;
    _fallbackNote = null;
    setState(() {
      _job = job;
      _step = _Step.analyzing;
      _status = _jobText(job);
    });
    _poll = Timer.periodic(const Duration(milliseconds: 1500), (_) => _tick());
  }

  String _jobText(Json job) {
    final stage = switch (job['stage']) {
      'detecting' => '다중 검출',
      'segmenting' => '개별 분리·배경 제거',
      'tagging' => '카테고리 분류',
      _ => null,
    };
    return switch (job['status']) {
      'queued' => 'AI 분석 대기 중… (시도 ${job['attempt']}/${job['max_attempts']})',
      'running' => 'AI 분석 중${stage != null ? ' · $stage' : ''} ${job['progress']}%',
      _ => '${job['status']}',
    };
  }

  Future<void> _tick() async {
    if (_job == null) return;
    if (_fallbackNote == null) {
      try {
        final job = (await api.get('/analysis-jobs/${_job!['id']}')) as Json;
        if (!mounted) return;
        setState(() {
          _job = job;
          _status = _jobText(job);
        });
        if (job['status'] == 'succeeded' || job['status'] == 'partial_failed') {
          _poll?.cancel();
          _partial = job['status'] == 'partial_failed';
          await _loadDrafts();
        } else if (job['status'] == 'failed' || job['status'] == 'cancelled') {
          _poll?.cancel();
          setState(() => _step = _Step.failed);
        }
      } on ApiException catch (e) {
        // hosted DB에서 GET /analysis-jobs가 503(계약 문제 #5)이면 배치 상태로 대신 본다.
        if (++_jobReadErrors >= 3 && e.status >= 500) {
          setState(() => _fallbackNote = '분석 상태 API 오류(계약 문제 #5) — 배치 상태로 대체 조회');
        }
      }
      return;
    }
    try {
      final batch = (await api.get('/garment-batches/$_batchId')) as Json;
      if (!mounted) return;
      setState(() => _status = '배치 상태: ${batch['status']}');
      if (batch['status'] == 'review') {
        _poll?.cancel();
        await _loadDrafts();
      } else if (batch['status'] == 'failed') {
        _poll?.cancel();
        setState(() => _step = _Step.failed);
      }
    } catch (_) {
      // 다음 주기에 다시 시도
    }
  }

  Future<void> _retry() async {
    setState(() => _busy = true);
    try {
      await _createJob(() => api.post('/analysis-jobs/${_job!['id']}/retry', idempotent: true));
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _loadDrafts() async {
    try {
      final body = (await api.get('/garment-batches/$_batchId/drafts')) as Json;
      final drafts = (body['items'] as List).cast<Json>();
      if (!mounted) return;
      setState(() {
        _drafts = drafts;
        for (final d in drafts) {
          _include[d['id'] as String] = d['status'] != 'rejected';
        }
        _step = _Step.review;
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e;
          _step = _Step.failed;
        });
      }
    }
  }

  Future<void> _patchDraft(Json draft, Json attributes) async {
    try {
      final updated = (await api.patch('/garment-drafts/${draft['id']}', {'expected_version': draft['version'], 'attributes': attributes})) as Json;
      setState(() => _drafts = [for (final d in _drafts) d['id'] == updated['id'] ? updated : d]);
    } on ApiException catch (e) {
      if (!mounted) return;
      showError(context, e);
      if (e.status == 409) await _loadDrafts();
    }
  }

  Future<void> _confirm() async {
    final included = _drafts.where((d) => _include[d['id']] == true).toList();
    setState(() => _busy = true);
    try {
      await api.post('/garment-batches/$_batchId/confirm', idempotent: true, body: {
        'draft_ids': [for (final d in included) d['id']],
        'draft_versions': {for (final d in included) d['id'] as String: d['version']},
      });
      ref.invalidate(garmentsProvider);
      if (mounted) setState(() => _step = _Step.done);
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('옷 등록'), actions: const [ApiLogButton()]),
        body: switch (_step) {
          _Step.guide => _guide(),
          _Step.preview => _preview(),
          _Step.analyzing => _analyzing(),
          _Step.failed => _failed(),
          _Step.review => _review(),
          _Step.done => _done(),
        },
      );

  Widget _guide() => ListView(padding: const EdgeInsets.all(20), children: [
        const Row(children: [
          Text('원샷 촬영 가이드', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
          SizedBox(width: 6),
          ProposalBadge(tooltip: '촬영 가이드 — 플로우에 화면 추가 요청'),
        ]),
        const SizedBox(height: 12),
        const Card(
          child: Padding(
            padding: EdgeInsets.all(16),
            child: Text('• 옷 2~6벌을 바닥에 펼쳐 한 장으로 찍어 주세요\n'
                '• 옷끼리 겹치지 않게 간격을 두세요\n'
                '• 밝은 곳에서, 무늬 없는 바닥이면 더 정확해요\n'
                '• AI가 한 벌씩 분리하고 배경을 지운 뒤 카테고리를 골라요'),
          ),
        ),
        const SizedBox(height: 20),
        FilledButton.icon(onPressed: () => _pick(ImageSource.camera), icon: const Icon(Icons.photo_camera), label: const Text('원샷 촬영')),
        const SizedBox(height: 8),
        OutlinedButton.icon(onPressed: () => _pick(ImageSource.gallery), icon: const Icon(Icons.photo_library), label: const Text('앨범에서 가져오기')),
        const SizedBox(height: 24),
        const _DemoWorkerPanel(),
      ]);

  Widget _preview() => ListView(padding: const EdgeInsets.all(20), children: [
        const Text('이미지 확인', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
        const SizedBox(height: 12),
        ClipRRect(borderRadius: BorderRadius.circular(12), child: Image.memory(_bytes!, fit: BoxFit.contain, height: 320)),
        const SizedBox(height: 16),
        Row(children: [
          Expanded(child: OutlinedButton(onPressed: _restart, child: const Text('다시 선택'))),
          const SizedBox(width: 8),
          Expanded(child: FilledButton(onPressed: _busy ? null : _startAnalysis, child: const Text('분석 시작'))),
        ]),
        const SizedBox(height: 24),
        const _DemoWorkerPanel(),
      ]);

  Widget _analyzing() => Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            if (_bytes != null)
              ClipRRect(borderRadius: BorderRadius.circular(12), child: Image.memory(_bytes!, height: 180, fit: BoxFit.contain)),
            const SizedBox(height: 24),
            const CircularProgressIndicator(),
            const SizedBox(height: 16),
            Text(_status, textAlign: TextAlign.center),
            const SizedBox(height: 4),
            const Text('다중 검출 · 개별 분리 · 배경 제거 · 카테고리 분류', style: TextStyle(fontSize: 12, color: Colors.grey)),
            if (_fallbackNote != null) ...[
              const SizedBox(height: 12),
              Text(_fallbackNote!, style: TextStyle(fontSize: 12, color: Colors.orange.shade800), textAlign: TextAlign.center),
            ],
          ]),
        ),
      );

  Widget _failed() {
    final job = _job;
    final retryable = job != null && job['retryable'] == true;
    final jobError = job?['error'] as Json?;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const Icon(Icons.error_outline, size: 48, color: Colors.redAccent),
          const SizedBox(height: 8),
          const Text('분석 실패', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          if (_error != null)
            Text(_error is ApiException ? '${(_error as ApiException).message}\n${(_error as ApiException).code} · HTTP ${(_error as ApiException).status}' : '$_error',
                textAlign: TextAlign.center)
          else
            Text(jobError?['message'] as String? ?? '옷을 분석하지 못했어요.', textAlign: TextAlign.center),
          if (job != null) Text('시도 ${job['attempt']}/${job['max_attempts']}', style: const TextStyle(fontSize: 12, color: Colors.grey)),
          const SizedBox(height: 20),
          if (retryable)
            FilledButton.icon(onPressed: _busy ? null : _retry, icon: const Icon(Icons.refresh), label: const Text('다시 시도')),
          if (!retryable && _job == null && _bytes != null && _batchId != null)
            FilledButton.icon(onPressed: _busy ? null : _startAnalysis, icon: const Icon(Icons.refresh), label: const Text('다시 요청')),
          const SizedBox(height: 8),
          OutlinedButton(onPressed: _restart, child: const Text('이미지 재선택')),
        ]),
      ),
    );
  }

  Widget _review() {
    final included = _drafts.where((d) => _include[d['id']] == true).toList();
    final missingCategory = included.any((d) => (d['current_attributes'] as Map)['category'] == null);
    return Column(children: [
      Expanded(
        child: ListView(padding: const EdgeInsets.all(16), children: [
          const Text('분석 결과 검토', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
          const Text('카테고리를 확인하고, 잘못 잡힌 옷은 "이 옷 저장"을 꺼서 빼 주세요.', style: TextStyle(fontSize: 12, color: Colors.grey)),
          if (_partial)
            Card(
              color: Colors.orange.shade50,
              child: const ListTile(leading: Icon(Icons.warning_amber), title: Text('일부 옷은 분리하지 못했어요'), subtitle: Text('분리된 옷만 저장할 수 있어요 (partial_failed)')),
            ),
          const SizedBox(height: 8),
          for (final d in _drafts) _DraftCard(
            key: ValueKey(d['id']),
            draft: d,
            included: _include[d['id']] == true,
            onInclude: (v) => setState(() => _include[d['id'] as String] = v),
            onPatch: (attrs) => _patchDraft(d, attrs),
          ),
        ]),
      ),
      SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            if (missingCategory) const Text('카테고리를 고르지 않은 옷이 있어요', style: TextStyle(color: Colors.redAccent, fontSize: 12)),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: _busy || included.isEmpty || missingCategory ? null : _confirm,
                child: Text('내 옷장에 저장 (${included.length}벌)'),
              ),
            ),
          ]),
        ),
      ),
    ]);
  }

  Widget _done() => Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const Icon(Icons.check_circle, size: 56, color: Colors.green),
          const SizedBox(height: 8),
          const Text('저장 완료', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
          const SizedBox(height: 16),
          FilledButton(onPressed: () => context.pop(), child: const Text('옷장으로')),
          TextButton(onPressed: _restart, child: const Text('더 등록하기')),
        ]),
      );
}

/// 분석 초안 한 벌: 누끼 + 카테고리(6종) + 하위분류·비고 + 저장 포함 스위치.
class _DraftCard extends StatefulWidget {
  const _DraftCard({super.key, required this.draft, required this.included, required this.onInclude, required this.onPatch});
  final Json draft;
  final bool included;
  final ValueChanged<bool> onInclude;
  final Future<void> Function(Json attributes) onPatch;

  @override
  State<_DraftCard> createState() => _DraftCardState();
}

class _DraftCardState extends State<_DraftCard> {
  late final _sub = TextEditingController(text: (widget.draft['current_attributes'] as Map)['subcategory'] as String? ?? '');
  late final _note = TextEditingController(text: (widget.draft['current_attributes'] as Map)['note'] as String? ?? '');

  @override
  Widget build(BuildContext context) {
    final current = widget.draft['current_attributes'] as Map;
    final category = current['category'] as String?;
    final confidence = widget.draft['prediction_confidence'] as num?;
    return Card(
      shape: category == null && widget.included
          ? RoundedRectangleBorder(side: const BorderSide(color: Colors.redAccent), borderRadius: BorderRadius.circular(12))
          : null,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Opacity(
          opacity: widget.included ? 1 : 0.45,
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              ClipRRect(borderRadius: BorderRadius.circular(8), child: SizedBox(width: 96, height: 96, child: NetImage(widget.draft['image']))),
              const SizedBox(width: 12),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('${widget.draft['client_item_key']}'
                      '${confidence != null ? ' · 신뢰도 ${(confidence * 100).round()}%' : ''}', style: const TextStyle(fontSize: 12, color: Colors.grey)),
                  if (category == null)
                    const Padding(
                      padding: EdgeInsets.only(top: 4),
                      child: Row(children: [
                        Flexible(child: Text('카테고리를 골라 주세요', style: TextStyle(color: Colors.redAccent, fontWeight: FontWeight.bold))),
                        SizedBox(width: 4),
                        ProposalBadge(tooltip: 'AI가 6종 밖(원피스 등)으로 판단하면 사용자가 6종 중 선택 — PM 협의 중'),
                      ]),
                    ),
                  DropdownButton<String>(
                    isExpanded: true,
                    value: category,
                    hint: const Text('카테고리'),
                    items: [for (final e in garmentCategories.entries) DropdownMenuItem(value: e.key, child: Text(e.value))],
                    onChanged: (v) => v == null ? null : widget.onPatch({'category': v}),
                  ),
                ]),
              ),
            ]),
            TextField(
              controller: _sub,
              decoration: const InputDecoration(labelText: '하위분류', isDense: true),
              onSubmitted: (v) => widget.onPatch({'subcategory': v.trim().isEmpty ? null : v.trim()}),
              onTapOutside: (_) {
                final v = _sub.text.trim();
                if (v != ((current['subcategory'] as String?) ?? '')) widget.onPatch({'subcategory': v.isEmpty ? null : v});
              },
            ),
            TextField(
              controller: _note,
              decoration: const InputDecoration(labelText: '비고', isDense: true),
              onSubmitted: (v) => widget.onPatch({'note': v.trim().isEmpty ? null : v.trim()}),
              onTapOutside: (_) {
                final v = _note.text.trim();
                if (v != ((current['note'] as String?) ?? '')) widget.onPatch({'note': v.isEmpty ? null : v});
              },
            ),
          ]),
        ),
      ),
    );
  }
}

/// 데모 전용: 로컬 dev 서버를 통해 가짜 AI worker의 다음 결과를 고른다(실제 앱에는 없음).
class _DemoWorkerPanel extends StatefulWidget {
  const _DemoWorkerPanel();

  @override
  State<_DemoWorkerPanel> createState() => _DemoWorkerPanelState();
}

class _DemoWorkerPanelState extends State<_DemoWorkerPanel> {
  static const _rotation = ['top', 'bottom', 'shoes', 'outerwear', 'bag', 'accessory'];
  String _mode = 'success';
  int _count = 3;
  bool _dress = false;
  String? _current;

  Future<void> _apply() async {
    final labels = [for (var i = 0; i < _count; i++) _rotation[i % _rotation.length]];
    if (_dress) labels[labels.length - 1] = 'dress';
    final value = '$_mode $_count ${labels.join(',')}';
    final body = await api.demoControl('/__demo/worker-mode?mode=${Uri.encodeQueryComponent(value)}');
    if (mounted) setState(() => _current = body ?? 'dev 서버에 연결할 수 없어요');
  }

  @override
  Widget build(BuildContext context) => Card(
        color: Colors.grey.shade100,
        child: ExpansionTile(
          leading: const Icon(Icons.science_outlined),
          title: const Text('데모 제어 (가짜 AI)'),
          subtitle: const Text('데모 전용 — 실제 앱에는 없음', style: TextStyle(fontSize: 12)),
          childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          children: [
            SegmentedButton<String>(
              segments: const [
                ButtonSegment(value: 'success', label: Text('성공')),
                ButtonSegment(value: 'partial', label: Text('부분 성공')),
                ButtonSegment(value: 'fail', label: Text('실패')),
              ],
              selected: {_mode},
              onSelectionChanged: (s) => setState(() => _mode = s.first),
            ),
            Row(children: [
              const Text('검출 벌 수'),
              Expanded(
                child: Slider(value: _count.toDouble(), min: 2, max: 6, divisions: 4, label: '$_count', onChanged: (v) => setState(() => _count = v.round())),
              ),
              Text('$_count벌'),
            ]),
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              value: _dress,
              onChanged: (v) => setState(() => _dress = v ?? false),
              title: const Text('원피스(dress) 라벨 섞기 → 카테고리 미지정 초안'),
            ),
            FilledButton.tonal(onPressed: _apply, child: const Text('다음 분석에 적용')),
            if (_current != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text('현재: $_current', style: const TextStyle(fontSize: 12))),
          ],
        ),
      );
}
