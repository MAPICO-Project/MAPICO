import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../config/labels.dart';
import '../../providers/providers.dart';
import '../../services/api.dart';
import '../../widgets/common.dart';
import 'compose_outfit_screen.dart';
import 'ootd_edit_screen.dart';

/// 스타일 믹스·캘린더 탭: 캘린더 | 코디 보관함 | 통계.
/// 코디 보관함 = 아직 입지 않아도 저장한 조합, OOTD 캘린더 = 특정 날짜에 실제로 입은 착장 기록.
class MixScreen extends StatelessWidget {
  const MixScreen({super.key});

  @override
  Widget build(BuildContext context) => DefaultTabController(
        length: 3,
        child: Scaffold(
          appBar: AppBar(
            title: const Text('스타일 믹스 · 캘린더'),
            actions: const [ApiLogButton()],
            bottom: const TabBar(tabs: [Tab(text: '캘린더'), Tab(text: '코디 보관함'), Tab(text: '통계')]),
          ),
          body: const TabBarView(children: [_CalendarTab(), _SavedTab(), _StatsTab()]),
          floatingActionButton: Builder(
            builder: (context) => FloatingActionButton.extended(
              onPressed: () => context.push('/mix/compose'),
              icon: const Icon(Icons.add),
              label: const Text('추가'),
            ),
          ),
        ),
      );
}

// ---------------- 캘린더 ----------------

class _CalendarTab extends StatefulWidget {
  const _CalendarTab();

  @override
  State<_CalendarTab> createState() => _CalendarTabState();
}

class _CalendarTabState extends State<_CalendarTab> with AutomaticKeepAliveClientMixin {
  late DateTime _month = DateTime(DateTime.now().year, DateTime.now().month);
  late Future<Map<String, Json>> _future = _load();

  @override
  bool get wantKeepAlive => true;

  DateTime get _lastDay => DateTime(_month.year, _month.month + 1, 0);

  /// GET /ootd/calendar?from&to (한 달 ≤ 62일) → 날짜별 대표 기록·건수.
  Future<Map<String, Json>> _load() async {
    final body = (await api.get('/ootd/calendar', query: {'from': ymd(_month), 'to': ymd(_lastDay)})) as Json;
    return {for (final d in (body['days'] as List).cast<Json>()) d['date'] as String: d};
  }

  void _reload() => setState(() => _future = _load());

  void _move(int delta) {
    _month = DateTime(_month.year, _month.month + delta);
    _reload();
  }

  bool _isFuture(DateTime d) {
    final now = DateTime.now();
    return d.isAfter(DateTime(now.year, now.month, now.day));
  }

  Future<void> _create(DateTime d) async {
    if (_isFuture(d)) {
      showSnack(context, '미래 날짜에는 착용 기록을 남길 수 없어요');
      return;
    }
    await context.push('/mix/ootd-edit', extra: OotdEditArgs(date: ymd(d)));
    _reload();
  }

  Future<void> _open(DateTime d, Json? day) async {
    if (day == null) return _create(d);
    try {
      final page = (await api.get('/ootd', query: {'from': ymd(d), 'to': ymd(d)})) as Json;
      final items = (page['items'] as List).cast<Json>();
      if (!mounted) return;
      if (items.length == 1) {
        await context.push('/mix/ootd/${items.first['id']}');
      } else {
        // 하루 여러 건(PM 협의 중): 목록에서 고른다.
        final chosen = await showModalBottomSheet<String>(
          context: context,
          builder: (c) => SafeArea(
            child: ListView(shrinkWrap: true, children: [
              ListTile(title: Text('${ymd(d)} 기록 ${items.length}건'), trailing: const ProposalBadge(tooltip: '하루 여러 건 허용 — PM 협의 중')),
              for (final o in items)
                ListTile(
                  leading: SizedBox(width: 44, height: 44, child: ClipRRect(borderRadius: BorderRadius.circular(6), child: NetImage(o['photo'], placeholderIcon: Icons.checkroom))),
                  title: Text((o['note'] as String?) ?? '메모 없음', maxLines: 1, overflow: TextOverflow.ellipsis),
                  subtitle: Text('옷 ${(o['garment_ids'] as List).length}벌 · 별점 ${o['rating'] ?? '-'}'),
                  onTap: () => c.pop(o['id'] as String),
                ),
              ListTile(leading: const Icon(Icons.add), title: const Text('이 날 기록 추가'), onTap: () => c.pop('__new')),
            ]),
          ),
        );
        if (!mounted || chosen == null) return;
        if (chosen == '__new') return await _create(d);
        await context.push('/mix/ootd/$chosen');
      }
      _reload();
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final first = _month;
    final leading = first.weekday % 7; // 일요일 시작
    final days = _lastDay.day;
    final today = ymd(DateTime.now());
    return RefreshIndicator(
      onRefresh: () async => _reload(),
      child: ListView(padding: const EdgeInsets.only(bottom: 96), children: [
        Row(mainAxisAlignment: MainAxisAlignment.center, children: [
          IconButton(onPressed: () => _move(-1), icon: const Icon(Icons.chevron_left)),
          Text('${_month.year}년 ${_month.month}월', style: Theme.of(context).textTheme.titleMedium),
          IconButton(onPressed: () => _move(1), icon: const Icon(Icons.chevron_right)),
        ]),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Row(children: [
            for (final w in ['일', '월', '화', '수', '목', '금', '토']) Expanded(child: Center(child: Text(w, style: const TextStyle(fontSize: 12, color: Colors.grey)))),
          ]),
        ),
        FutureBuilder<Map<String, Json>>(
          future: _future,
          builder: (context, snap) {
            if (snap.hasError) return SizedBox(height: 300, child: ErrorPanel(snap.error!, onRetry: _reload));
            final data = snap.data ?? const <String, Json>{};
            return Stack(children: [
              GridView.count(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                padding: const EdgeInsets.all(8),
                crossAxisCount: 7,
                mainAxisSpacing: 4,
                crossAxisSpacing: 4,
                childAspectRatio: 0.72,
                children: [
                  for (var i = 0; i < leading; i++) const SizedBox(),
                  for (var dnum = 1; dnum <= days; dnum++)
                    _DayCell(
                      date: DateTime(_month.year, _month.month, dnum),
                      day: data[ymd(DateTime(_month.year, _month.month, dnum))],
                      isToday: ymd(DateTime(_month.year, _month.month, dnum)) == today,
                      onTap: (d, day) => _open(d, day),
                    ),
                ],
              ),
              if (snap.connectionState == ConnectionState.waiting) const Positioned.fill(child: Center(child: CircularProgressIndicator())),
            ]);
          },
        ),
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 16),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [Text('숫자 배지: 그날 기록 수 · 하루 여러 건 허용 ', style: TextStyle(fontSize: 12)), ProposalBadge()]),
            SizedBox(height: 4),
            Row(children: [
              Icon(Icons.cloud_queue, size: 14, color: Colors.blueGrey),
              Flexible(child: Text(' 저장 당시 날씨 아이콘: 스냅샷 조회 API 없음(계약 문제 #8)', style: TextStyle(fontSize: 12))),
            ]),
            SizedBox(height: 4),
            Text('날짜를 누르면 기록 상세, 기록이 없으면 새로 작성합니다.', style: TextStyle(fontSize: 12, color: Colors.grey)),
          ]),
        ),
      ]),
    );
  }
}

class _DayCell extends StatelessWidget {
  const _DayCell({required this.date, required this.day, required this.isToday, required this.onTap});
  final DateTime date;
  final Json? day;
  final bool isToday;
  final void Function(DateTime, Json?) onTap;

  @override
  Widget build(BuildContext context) {
    final d = day;
    final count = (d?['count'] as int?) ?? 0;
    return InkWell(
      onTap: () => onTap(date, d),
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: isToday ? Theme.of(context).colorScheme.primary : Colors.grey.shade300, width: isToday ? 2 : 1),
        ),
        child: Column(children: [
          Text('${date.day}', style: const TextStyle(fontSize: 11)),
          Expanded(
            child: d == null
                ? const SizedBox()
                : Stack(fit: StackFit.expand, children: [
                    Padding(
                      padding: const EdgeInsets.all(2),
                      child: d['photo'] != null
                          ? ClipRRect(borderRadius: BorderRadius.circular(4), child: NetImage(d['photo']))
                          : const Icon(Icons.check_circle, color: Colors.green, size: 20),
                    ),
                    if (count > 1)
                      Positioned(
                        right: 0,
                        top: 0,
                        child: CircleAvatar(radius: 8, backgroundColor: Colors.deepPurple, child: Text('$count', style: const TextStyle(fontSize: 9, color: Colors.white))),
                      ),
                    if (d['weather_snapshot_id'] != null)
                      const Positioned(left: 0, bottom: 0, child: Icon(Icons.cloud_queue, size: 12, color: Colors.blueGrey)),
                  ]),
          ),
        ]),
      ),
    );
  }
}

// ---------------- 코디 보관함 ----------------

class _SavedTab extends StatefulWidget {
  const _SavedTab();

  @override
  State<_SavedTab> createState() => _SavedTabState();
}

class _SavedTabState extends State<_SavedTab> {
  late Future<List<Json>> _future = _load();

  Future<List<Json>> _load() async {
    final page = (await api.get('/saved-outfits', query: {'limit': '50'})) as Json;
    return (page['items'] as List).cast<Json>();
  }

  void _reload() => setState(() => _future = _load());

  Future<void> _delete(Json s) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text('"${s['title']}"을(를) 삭제할까요?'),
        content: const Text('보관함에서만 지워지고, 지난 OOTD 기록은 바뀌지 않아요.'),
        actions: [
          TextButton(onPressed: () => c.pop(false), child: const Text('취소')),
          FilledButton(onPressed: () => c.pop(true), child: const Text('삭제')),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await api.delete('/saved-outfits/${s['id']}');
      _reload();
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) => RefreshIndicator(
        onRefresh: () async => _reload(),
        child: FutureBuilder<List<Json>>(
          future: _future,
          builder: (context, snap) {
            if (snap.hasError) return ErrorPanel(snap.error!, onRetry: _reload);
            if (!snap.hasData) return const Center(child: CircularProgressIndicator());
            final list = snap.data!;
            return ListView(padding: const EdgeInsets.only(bottom: 96), children: [
              const Padding(
                padding: EdgeInsets.all(16),
                child: Text('코디 보관함 = 아직 입지 않아도 저장한 조합 / OOTD 캘린더 = 실제로 입은 착장 기록', style: TextStyle(fontSize: 12, color: Colors.grey)),
              ),
              if (list.isEmpty) const Padding(padding: EdgeInsets.all(32), child: Center(child: Text('저장한 코디가 없어요. 홈 추천이나 + 추가로 만들어 보세요.'))),
              for (final s in list) _savedCard(s),
            ]);
          },
        ),
      );

  Widget _savedCard(Json s) {
    final ids = (s['garment_ids'] as List).cast<String>();
    final unavailable = (s['unavailable_garment_ids'] as List? ?? const []).cast<String>().toSet();
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(s['title'] as String, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
          if (s['note'] != null) Text(s['note'] as String, style: const TextStyle(color: Colors.grey)),
          const SizedBox(height: 8),
          SizedBox(
            height: 84,
            child: ListView(scrollDirection: Axis.horizontal, children: [
              for (final id in ids)
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: unavailable.contains(id)
                      ? const SizedBox(width: 64, child: Column(children: [Icon(Icons.hide_image_outlined, size: 48, color: Colors.grey), Text('삭제된 옷', style: TextStyle(fontSize: 11))]))
                      : GarmentThumb(id),
                ),
            ]),
          ),
          Row(mainAxisAlignment: MainAxisAlignment.end, children: [
            TextButton(
              onPressed: () async {
                await context.push('/mix/compose', extra: ComposeOutfitArgs(existing: s));
                _reload();
              },
              child: const Text('수정'),
            ),
            TextButton(onPressed: () => _delete(s), child: const Text('삭제')),
            FilledButton.tonal(
              onPressed: () => context.push('/mix/ootd-edit',
                  extra: OotdEditArgs(date: ymd(DateTime.now()), garmentIds: ids.where((id) => !unavailable.contains(id)).toList(), savedOutfitId: s['id'] as String)),
              child: const Text('오늘 입기'),
            ),
          ]),
        ]),
      ),
    );
  }
}

// ---------------- 통계 ----------------

class _StatsTab extends ConsumerStatefulWidget {
  const _StatsTab();

  @override
  ConsumerState<_StatsTab> createState() => _StatsTabState();
}

class _StatsTabState extends ConsumerState<_StatsTab> {
  late Future<Json> _future = _load();

  Future<Json> _load() async => (await api.get('/closet/statistics')) as Json;

  void _reload() {
    ref.invalidate(garmentsProvider);
    setState(() => _future = _load());
  }

  @override
  Widget build(BuildContext context) {
    final total = ref.watch(garmentsProvider).value?.length ?? 0;
    return RefreshIndicator(
      onRefresh: () async => _reload(),
      child: FutureBuilder<Json>(
        future: _future,
        builder: (context, snap) {
          if (snap.hasError) return ErrorPanel(snap.error!, onRetry: _reload);
          if (!snap.hasData) return const Center(child: CircularProgressIndicator());
          final s = snap.data!;
          final wear = [...(s['wear_counts'] as List).cast<Json>()]..sort((a, b) => (b['count'] as int).compareTo(a['count'] as int));
          final worn = wear.where((w) => (w['count'] as int) > 0).length;
          final unworn = (s['unworn_30_days'] as List).cast<String>();
          final top = s['top_aesthetic'] as Json?;
          final totals = (s['aesthetic_totals'] as List).cast<Json>();
          final maxScore = totals.fold<double>(0, (m, t) => (t['score_total'] as num).toDouble() > m ? (t['score_total'] as num).toDouble() : m);
          final ratio = total == 0 ? 0.0 : worn / total;
          return ListView(padding: const EdgeInsets.only(bottom: 96), children: [
            const SectionTitle('옷장 활용도'),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                LinearProgressIndicator(value: ratio, minHeight: 10, borderRadius: BorderRadius.circular(5)),
                const SizedBox(height: 4),
                Text('전체 $total벌 중 $worn벌 착용 (${(ratio * 100).round()}%) · 기준일 ${s['as_of']}'),
              ]),
            ),
            const SectionTitle('많이 입은 아이템 Top 3'),
            if (wear.isEmpty) const Padding(padding: EdgeInsets.symmetric(horizontal: 16), child: Text('아직 착용 기록이 없어요.')),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(children: [
                for (final w in wear.take(3))
                  Padding(
                    padding: const EdgeInsets.only(right: 12),
                    child: Column(children: [GarmentThumb(w['garment_id'] as String, size: 72), Text('${w['count']}회', style: const TextStyle(fontWeight: FontWeight.bold))]),
                  ),
              ]),
            ),
            SectionTitle('최다 추구미', trailing: const ProposalBadge(tooltip: '착용한 옷 추구미 점수 합산 — PM 협의 중')),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(top == null ? '데이터 부족' : top['label'] as String, style: Theme.of(context).textTheme.headlineSmall),
                const Text('착용한 옷 추구미 점수 합산', style: TextStyle(fontSize: 12, color: Colors.grey)),
                const SizedBox(height: 8),
                for (final t in totals)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 2),
                    child: Row(children: [
                      SizedBox(width: 64, child: Text(t['label'] as String, style: const TextStyle(fontSize: 12))),
                      Expanded(child: LinearProgressIndicator(value: maxScore == 0 ? 0 : (t['score_total'] as num) / maxScore, minHeight: 8)),
                      SizedBox(width: 44, child: Text((t['score_total'] as num).toStringAsFixed(1), textAlign: TextAlign.right, style: const TextStyle(fontSize: 12))),
                    ]),
                  ),
              ]),
            ),
            SectionTitle('30일 이상 미착용 (${unworn.length})'),
            if (unworn.isEmpty) const Padding(padding: EdgeInsets.symmetric(horizontal: 16), child: Text('모든 옷을 최근 30일 안에 입었어요.')),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Wrap(spacing: 8, runSpacing: 8, children: [for (final id in unworn) GarmentThumb(id)]),
            ),
          ]);
        },
      ),
    );
  }
}
