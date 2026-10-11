import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../config/labels.dart';
import '../../services/api.dart';
import '../../widgets/common.dart';

/// 따라입기 결과. 서버가 동기 매칭(rule-v1)해 바로 succeeded/no_match가 되지만,
/// 계약상 202 + 폴링이므로 queued/running이면 1초 간격으로 다시 읽는다.
class MimicResultScreen extends StatefulWidget {
  const MimicResultScreen({super.key, required this.jobId});
  final String jobId;

  @override
  State<MimicResultScreen> createState() => _MimicResultScreenState();
}

class _MimicResultScreenState extends State<MimicResultScreen> {
  Json? _job;
  Object? _error;
  Timer? _timer;
  int _polls = 0;
  bool _saving = false;
  final _saveKey = api.newIdempotencyKey(); // 저장 버튼 연타해도 한 번만 저장

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() => _error = null);
    try {
      final job = (await api.get('/mimic-jobs/${widget.jobId}')) as Json;
      if (!mounted) return;
      setState(() => _job = job);
      final pending = job['status'] == 'queued' || job['status'] == 'running';
      if (pending && _polls++ < 15) _timer = Timer(const Duration(seconds: 1), _load);
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  List<String> get _matchedIds => [
        for (final m in ((_job?['matches'] as List?) ?? const []).cast<Json>())
          if (m['garment_id'] != null) m['garment_id'] as String,
      ];

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      await api.post('/saved-outfits', body: {'title': '따라입기 코디', 'garment_ids': _matchedIds}, idempotencyKey: _saveKey);
      if (mounted) showSnack(context, '코디 보관함에 저장했어요');
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('따라입기 결과'), actions: const [ApiLogButton()]),
        body: _error != null
            ? ErrorPanel(_error!, onRetry: _load)
            : _job == null
                ? const Center(child: CircularProgressIndicator())
                : _body(_job!),
      );

  Widget _body(Json job) {
    final status = job['status'] as String;
    if (status == 'queued' || status == 'running') {
      return Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const CircularProgressIndicator(),
          const SizedBox(height: 12),
          Text(_polls > 15 ? '시간이 오래 걸리고 있어요' : 'AI Matching 중…'),
          if (_polls > 15) TextButton(onPressed: () { _polls = 0; _load(); }, child: const Text('다시 확인')),
        ]),
      );
    }
    if (status == 'failed') {
      final e = job['error'] as Map?;
      return ErrorPanel(ApiException(0, '${e?['code'] ?? 'MIMIC_FAILED'}', '${e?['message'] ?? '따라입기에 실패했어요.'}'), onRetry: _load);
    }
    if (status == 'no_match') {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Icon(Icons.search_off, size: 48, color: Colors.grey),
            const SizedBox(height: 12),
            const Text('비슷한 옷이 없음,\n옷장을 조금 더 채워보세요', textAlign: TextAlign.center, style: TextStyle(fontSize: 16)),
            const SizedBox(height: 16),
            FilledButton.icon(onPressed: () => context.push('/closet/register'), icon: const Icon(Icons.add_a_photo), label: const Text('옷 등록하기')),
          ]),
        ),
      );
    }
    final matches = ((job['matches'] as List?) ?? const []).cast<Json>();
    final grade = job['grade'] as String?;
    final coverage = job['coverage'];
    return ListView(padding: const EdgeInsets.all(16), children: [
      Row(children: [
        const Text('전체 매칭', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
        const SizedBox(width: 12),
        Chip(
          label: Text(mimicGradeLabels[grade] ?? '-', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
          backgroundColor: switch (grade) { 'high' => Colors.green.shade100, 'medium' => Colors.amber.shade100, _ => Colors.grey.shade200 },
        ),
        const Spacer(),
        const ProposalBadge(tooltip: '% 대신 등급 표시 · 전체 등급 산식 — PM 협의'),
      ]),
      if (coverage is num) Text('연결 아이템 중 ${(coverage * 100).round()}%를 내 옷장에서 찾았어요', style: const TextStyle(color: Colors.grey)),
      const SizedBox(height: 12),
      for (final m in matches)
        Card(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Row(children: [
              Column(children: [
                Container(
                  width: 64, height: 64,
                  decoration: BoxDecoration(color: Colors.grey.shade200, borderRadius: BorderRadius.circular(8)),
                  child: const Icon(Icons.checkroom, color: Colors.grey),
                ),
                Text('원본 ${categoryLabel(m['category'] as String?)}', style: const TextStyle(fontSize: 11)),
              ]),
              const Padding(padding: EdgeInsets.symmetric(horizontal: 8), child: Icon(Icons.arrow_forward)),
              m['garment_id'] == null
                  ? const SizedBox(width: 64, child: Text('비슷한 옷 없음', style: TextStyle(fontSize: 12, color: Colors.grey)))
                  : GarmentThumb(m['garment_id'] as String),
              const SizedBox(width: 12),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('유사도 ${mimicGradeLabels[m['grade']] ?? '-'}', style: const TextStyle(fontWeight: FontWeight.bold)),
                  Text('${m['reason'] ?? ''}', style: const TextStyle(fontSize: 12)),
                ]),
              ),
            ]),
          ),
        ),
      const SizedBox(height: 12),
      FilledButton.icon(
        onPressed: _matchedIds.isEmpty || _saving ? null : _save,
        icon: const Icon(Icons.bookmark_add_outlined),
        label: const Text('코디 보관함에 저장'),
      ),
    ]);
  }
}
