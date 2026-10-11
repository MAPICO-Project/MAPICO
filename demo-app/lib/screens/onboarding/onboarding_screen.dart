import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../providers/providers.dart';
import '../../services/api.dart';
import '../../widgets/aesthetic_picker.dart';
import '../../widgets/common.dart';

/// 온보딩(USER_FLOWS §1): 추구미 인지 분기 → 직접 선택 / 무드보드 → 결과 → 고지 → 원샷 등록 안내 → 홈.
class OnboardingScreen extends ConsumerStatefulWidget {
  const OnboardingScreen({super.key});

  @override
  ConsumerState<OnboardingScreen> createState() => _OnboardingScreenState();
}

enum _Step { ask, pick, moodboard, analyzing, tiebreak, result, guide }

/// 무드보드 카드 한 장. 라벨(추구미)은 화면에 노출하지 않는다.
class _MoodCard {
  const _MoodCard(this.aestheticId, this.code, this.variant);
  final String aestheticId;
  final String code;
  final int variant;
}

class _OnboardingScreenState extends ConsumerState<OnboardingScreen> {
  _Step _step = _Step.ask;
  final List<_Step> _history = [];
  bool? _knows;
  String? _mainId;
  List<String> _subIds = [];
  List<_MoodCard>? _cards;
  final Set<int> _picked = {};
  List<String> _tied = [];
  bool _busy = false;

  void _go(_Step next) => setState(() {
        _history.add(_step);
        _step = next;
      });

  void _back() => setState(() => _step = _history.removeLast());

  /// 추구미별 3~4장, 총 15~20장(5종이면 18장). 고정 seed로 섞어 시연마다 같은 배치.
  List<_MoodCard> _buildCards(List<Json> aesthetics) {
    final cards = <_MoodCard>[];
    for (var i = 0; i < aesthetics.length; i++) {
      final count = i.isEven ? 4 : 3;
      for (var v = 0; v < count; v++) {
        cards.add(_MoodCard(aesthetics[i]['id'] as String, aesthetics[i]['code'] as String, v));
      }
    }
    return cards..shuffle(Random(20261011));
  }

  /// 카드 1장 = 해당 추구미 +1. 최고 점수 = 메인, 차순위(점수>0) 최대 2개 = 보조. 1위 동점이면 tie-break.
  Future<void> _analyze() async {
    _go(_Step.analyzing);
    final scores = <String, int>{};
    for (final i in _picked) {
      final id = _cards![i].aestheticId;
      scores[id] = (scores[id] ?? 0) + 1;
    }
    final ranked = scores.entries.toList()..sort((a, b) => b.value.compareTo(a.value));
    await Future<void>.delayed(const Duration(milliseconds: 1200));
    if (!mounted) return;
    final top = ranked.first.value;
    final tied = [for (final e in ranked) if (e.value == top) e.key];
    if (tied.length > 1) {
      setState(() {
        _tied = tied;
        _step = _Step.tiebreak;
      });
      return;
    }
    setState(() {
      _mainId = ranked.first.key;
      _subIds = [for (final e in ranked.skip(1).take(2)) e.key];
      _step = _Step.result;
    });
  }

  void _resolveTie(String chosen) {
    final scores = <String, int>{};
    for (final i in _picked) {
      final id = _cards![i].aestheticId;
      scores[id] = (scores[id] ?? 0) + 1;
    }
    final rest = scores.entries.where((e) => e.key != chosen).toList()..sort((a, b) => b.value.compareTo(a.value));
    setState(() {
      _mainId = chosen;
      _subIds = [for (final e in rest.take(2)) e.key];
      _step = _Step.result;
    });
  }

  /// 이대로 시작하기: 추구미 저장 → (미동의면) 고지 → 원샷 등록 안내.
  Future<void> _saveAesthetics() async {
    setState(() => _busy = true);
    try {
      await api.put('/me/aesthetics', body: preferencesBody(_mainId!, _subIds));
      final profile = await ref.read(profileProvider.future);
      if (!mounted) return;
      if (profile['ai_notice_accepted_at'] == null) {
        // 거절해도 진행한다. 이후 분석 요청이 403 AI_NOTICE_REQUIRED로 다시 고지로 보낸다.
        await context.push<bool>('/notice');
      }
      if (mounted) _go(_Step.guide);
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _finish() async {
    setState(() => _busy = true);
    try {
      await api.put('/me/onboarding', body: {'knows_aesthetic': _knows, 'tutorial_seen': true, 'completed': true});
      ref.invalidate(profileProvider);
      if (mounted) context.go('/home');
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final aesthetics = ref.watch(aestheticsProvider);
    return Scaffold(
      appBar: AppBar(
        title: const Text('시작하기'),
        leading: _history.isNotEmpty && _step != _Step.analyzing ? BackButton(onPressed: _back) : null,
        automaticallyImplyLeading: false,
        actions: const [ApiLogButton()],
      ),
      body: AsyncBody(
        value: aesthetics,
        onRetry: () => ref.invalidate(aestheticsProvider),
        builder: (list) => switch (_step) {
          _Step.ask => _ask(),
          _Step.pick => _pick(list),
          _Step.moodboard => _moodboard(list),
          _Step.analyzing => const Center(
              child: Column(mainAxisSize: MainAxisSize.min, children: [CircularProgressIndicator(), SizedBox(height: 16), Text('추구미 분석 중…')])),
          _Step.tiebreak => _tiebreak(list),
          _Step.result => _result(list),
          _Step.guide => _guide(),
        },
      ),
    );
  }

  Widget _ask() => Padding(
        padding: const EdgeInsets.all(24),
        child: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          const Text('자신의 추구미를 알고 있나요?', textAlign: TextAlign.center, style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          const Text('추구미는 내가 추구하는 스타일 분위기예요.', textAlign: TextAlign.center),
          const SizedBox(height: 32),
          FilledButton(
              onPressed: () {
                _knows = true;
                _go(_Step.pick);
              },
              child: const Text('네, 직접 고를게요')),
          const SizedBox(height: 12),
          OutlinedButton(
              onPressed: () {
                _knows = false;
                _picked.clear();
                _go(_Step.moodboard);
              },
              child: const Text('아니요, 사진으로 찾아볼게요')),
        ]),
      );

  Widget _pick(List<Json> list) => ListView(padding: const EdgeInsets.all(20), children: [
        const Text('추구미를 골라 주세요', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
        const SizedBox(height: 16),
        AestheticPicker(
          aesthetics: list,
          mainId: _mainId,
          subIds: _subIds,
          onChanged: (m, s) => setState(() {
            _mainId = m;
            _subIds = s;
          }),
        ),
        const SizedBox(height: 24),
        FilledButton(onPressed: _mainId == null ? null : () => _go(_Step.result), child: const Text('다음')),
      ]);

  Widget _moodboard(List<Json> list) {
    final cards = _cards ??= _buildCards(list);
    final n = _picked.length;
    return Column(children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
        child: Row(children: [
          const Expanded(child: Text('끌리는 코디를 3~6장 골라 주세요', style: TextStyle(fontWeight: FontWeight.bold))),
          const ProposalBadge(tooltip: '사진 탐색 점수 산식은 미결(카드 1장 = +1 임시안)'),
        ]),
      ),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Text('$n / 6 선택 · 샘플 카드(실제 코디 사진 대체)', style: Theme.of(context).textTheme.bodySmall),
      ),
      Expanded(
        child: GridView.builder(
          padding: const EdgeInsets.all(12),
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: 3, mainAxisSpacing: 8, crossAxisSpacing: 8, childAspectRatio: 0.75),
          itemCount: cards.length,
          itemBuilder: (_, i) => _SampleCard(
            card: cards[i],
            selected: _picked.contains(i),
            onTap: () => setState(() {
              if (_picked.contains(i)) {
                _picked.remove(i);
              } else if (_picked.length < 6) {
                _picked.add(i);
              } else {
                showSnack(context, '최대 6장까지 고를 수 있어요');
              }
            }),
          ),
        ),
      ),
      Padding(
        padding: const EdgeInsets.all(16),
        child: SizedBox(
          width: double.infinity,
          child: FilledButton(onPressed: n >= 3 ? _analyze : null, child: Text(n >= 3 ? '추구미 분석하기' : '${3 - n}장 더 골라 주세요')),
        ),
      ),
    ]);
  }

  Widget _tiebreak(List<Json> list) => ListView(padding: const EdgeInsets.all(20), children: [
        const Text('둘 중 더 끌리는 쪽은?', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
        const SizedBox(height: 4),
        const Text('점수가 같은 추구미가 있어 한 번 더 골라 주세요.'),
        const SizedBox(height: 16),
        Wrap(spacing: 12, runSpacing: 12, children: [
          for (final id in _tied)
            SizedBox(
              width: 150,
              height: 200,
              child: _SampleCard(
                card: _cards!.firstWhere((c) => c.aestheticId == id),
                selected: false,
                onTap: () => _resolveTie(id),
              ),
            ),
        ]),
      ]);

  Widget _result(List<Json> list) => ListView(padding: const EdgeInsets.all(20), children: [
        const Text('나의 추구미', style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
        const SizedBox(height: 16),
        Card(
          child: ListTile(
            leading: const Icon(Icons.star),
            title: Text(aestheticName(list, _mainId), style: const TextStyle(fontWeight: FontWeight.bold)),
            subtitle: const Text('메인'),
          ),
        ),
        for (final s in _subIds) Card(child: ListTile(leading: const Icon(Icons.star_border), title: Text(aestheticName(list, s)), subtitle: const Text('보조'))),
        if (_subIds.isEmpty) const Padding(padding: EdgeInsets.all(8), child: Text('보조 추구미 없음 (0~2개 선택 가능)')),
        const SizedBox(height: 24),
        OutlinedButton(onPressed: () => _go(_Step.pick), child: const Text('직접 수정하기')),
        const SizedBox(height: 8),
        FilledButton(onPressed: _busy ? null : _saveAesthetics, child: const Text('이대로 시작하기')),
      ]);

  Widget _guide() => ListView(padding: const EdgeInsets.all(20), children: [
        const Text('원샷 옷장 등록', style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
        const SizedBox(height: 8),
        const Text('옷 여러 벌을 바닥에 펼쳐 한 장 찍으면 AI가 각각 분리해 등록해요.'),
        const SizedBox(height: 16),
        AspectRatio(
          aspectRatio: 4 / 3,
          child: Container(
            decoration: BoxDecoration(color: const Color(0xFFECE8E2), borderRadius: BorderRadius.circular(12)),
            child: const Stack(children: [
              Center(
                child: Wrap(spacing: 24, runSpacing: 16, alignment: WrapAlignment.center, children: [
                  Icon(Icons.checkroom, size: 56, color: Color(0xFF3B5B8C)),
                  Icon(Icons.dry_cleaning, size: 56, color: Color(0xFF8C6D3B)),
                  Icon(Icons.ice_skating, size: 56, color: Color(0xFF333333)),
                  Icon(Icons.shopping_bag_outlined, size: 56, color: Color(0xFF8C3B3B)),
                ]),
              ),
              Positioned(left: 8, top: 6, child: Text('예시 화면', style: TextStyle(fontSize: 11, color: Colors.grey))),
            ]),
          ),
        ),
        const SizedBox(height: 16),
        const ListTile(leading: Icon(Icons.filter_6), title: Text('한 번에 2~6벌')),
        const ListTile(leading: Icon(Icons.grid_view), title: Text('옷끼리 겹치지 않게 펼쳐 주세요')),
        const ListTile(leading: Icon(Icons.light_mode_outlined), title: Text('밝은 곳, 단색 바닥이면 더 정확해요')),
        const Text('지금은 안내만 보여 드려요. 실제 등록은 디지털 옷장 탭의 + 옷 등록에서 할 수 있어요.', style: TextStyle(color: Colors.grey)),
        const SizedBox(height: 24),
        FilledButton(onPressed: _busy ? null : _finish, child: const Text('홈으로')),
      ]);
}

/// 사진 대신 그린 샘플 카드. 추구미마다 색·아이콘 계열을 다르게 해 고르는 맛만 낸다.
class _SampleCard extends StatelessWidget {
  const _SampleCard({required this.card, required this.selected, required this.onTap});
  final _MoodCard card;
  final bool selected;
  final VoidCallback onTap;

  static const _palettes = <String, List<Color>>{
    'feminine': [Color(0xFFF8C8DC), Color(0xFFE59BB8), Color(0xFFFFF0F5)],
    'y2k': [Color(0xFF9B5CFF), Color(0xFF3DE0FF), Color(0xFFFF6AD5)],
    'minimal': [Color(0xFFF2F2F2), Color(0xFFBDBDBD), Color(0xFF424242)],
    'grunge': [Color(0xFF3E3A36), Color(0xFF6B4F3A), Color(0xFF1E1E1E)],
    'casual': [Color(0xFF6C8EBF), Color(0xFFDCE6F2), Color(0xFFF5E6C8)],
  };
  static const _icons = [Icons.checkroom, Icons.dry_cleaning, Icons.style, Icons.shopping_bag_outlined];

  @override
  Widget build(BuildContext context) {
    final colors = _palettes[card.code] ?? [Colors.teal.shade200, Colors.teal.shade400, Colors.teal.shade50];
    final a = colors[card.variant % colors.length];
    final b = colors[(card.variant + 1) % colors.length];
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(10),
          gradient: LinearGradient(colors: [a, b], begin: Alignment.topLeft, end: Alignment.bottomRight),
          border: Border.all(color: selected ? Theme.of(context).colorScheme.primary : Colors.transparent, width: 3),
        ),
        child: Stack(children: [
          Center(child: Icon(_icons[card.variant % _icons.length], size: 44, color: Colors.white.withValues(alpha: 0.85))),
          const Positioned(left: 6, top: 4, child: Text('샘플', style: TextStyle(fontSize: 10, color: Colors.white70))),
          if (selected) Positioned(right: 4, top: 4, child: Icon(Icons.check_circle, color: Theme.of(context).colorScheme.primary)),
        ]),
      ),
    );
  }
}
