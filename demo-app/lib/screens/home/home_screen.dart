import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';
import 'package:go_router/go_router.dart';

import '../../config/labels.dart';
import '../../providers/providers.dart';
import '../../services/api.dart';
import '../../widgets/common.dart';
import '../mix/compose_outfit_screen.dart';

/// 홈(USER_FLOWS §2): 오늘의 날씨 → 추구미 Chip → AI 추천 코디 3개 → 보관함 저장 / 스타일 믹스 / 오늘 입기.
class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen> {
  // 위치: 좌표(lat/lon) 또는 지역 코드 중 정확히 하나(계약: 둘 다 보내면 422).
  double? _lat;
  double? _lon;
  bool _regionMode = false;
  String _region = 'seoul';
  String? _locationNote;
  bool _locating = true;

  Json? _weather;
  Object? _weatherError;
  bool _weatherLoading = false;

  String? _chipId; // null = 메인(서버 기본)
  Json? _set;
  Object? _recoError;
  bool _recoLoading = false;
  int _page = 0;
  final _pager = PageController();

  @override
  void initState() {
    super.initState();
    _locate();
  }

  @override
  void dispose() {
    _pager.dispose();
    super.dispose();
  }

  Json get _location => _regionMode || _lat == null ? {'region_code': _region} : {'lat': _lat, 'lon': _lon};

  Future<void> _locate() async {
    setState(() => _locating = true);
    try {
      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) permission = await Geolocator.requestPermission();
      if (permission == LocationPermission.denied || permission == LocationPermission.deniedForever) {
        throw Exception('denied');
      }
      final pos = await Geolocator.getCurrentPosition().timeout(const Duration(seconds: 8));
      _lat = pos.latitude;
      _lon = pos.longitude;
      _regionMode = false;
      _locationNote = '현재 위치';
    } catch (_) {
      // 위치 권한 거절·실패 → 지역 직접 선택(기본 서울).
      _regionMode = true;
      _locationNote = '위치를 사용할 수 없어 지역을 직접 골라요';
    }
    if (!mounted) return;
    setState(() => _locating = false);
    await Future.wait([_loadWeather(), _loadRecommendations()]);
  }

  Future<void> _loadWeather() async {
    setState(() {
      _weatherLoading = true;
      _weatherError = null;
    });
    try {
      final loc = _location;
      final body = await api.get('/weather/current',
          query: loc.containsKey('region_code') ? {'region_code': _region} : {'lat': '$_lat', 'lon': '$_lon'});
      if (mounted) setState(() => _weather = body as Json);
    } catch (e) {
      if (mounted) setState(() => _weatherError = e);
    } finally {
      if (mounted) setState(() => _weatherLoading = false);
    }
  }

  Future<void> _loadRecommendations() async {
    setState(() {
      _recoLoading = true;
      _recoError = null;
    });
    try {
      final body = await api.post('/recommendations',
          idempotent: true,
          body: {'location': _location, 'requested_count': 3, 'aesthetic_id': _chipId});
      if (!mounted) return;
      setState(() {
        _set = body as Json;
        _page = 0;
      });
      if (_pager.hasClients) _pager.jumpToPage(0);
    } catch (e) {
      if (mounted) setState(() => _recoError = e);
    } finally {
      if (mounted) setState(() => _recoLoading = false);
    }
  }

  Future<void> _saveOutfit(Json outfit) async {
    final now = DateTime.now();
    try {
      await api.post('/saved-outfits', idempotent: true, body: {
        'title': '추천 코디 ${now.month.toString().padLeft(2, '0')}/${now.day.toString().padLeft(2, '0')}',
        'garment_ids': outfit['garment_ids'],
        'source_recommendation_id': _set!['id'],
      });
      if (mounted) showSnack(context, '코디 보관함에 저장했어요');
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Future<void> _wearToday(Json outfit) async {
    try {
      final ootd = (await api.post('/recommendations/${_set!['id']}/accept',
          idempotent: true, body: {'outfit_id': outfit['id'], 'worn_on': ymd(DateTime.now())})) as Json;
      if (!mounted) return;
      showSnack(context, '오늘의 OOTD로 기록했어요');
      context.push('/mix/ootd/${ootd['id']}');
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(garmentsProvider); // 추천 썸네일용 옷장 캐시
    final profile = ref.watch(profileProvider).value;
    final aesthetics = ref.watch(aestheticsProvider).value;
    return Scaffold(
      appBar: AppBar(
        title: const Text('MAFICO', style: TextStyle(fontWeight: FontWeight.w800, letterSpacing: 2)),
        actions: [
          const ApiLogButton(),
          IconButton(tooltip: '마이페이지', icon: const Icon(Icons.account_circle_outlined), onPressed: () => context.push('/mypage')),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () => Future.wait([_loadWeather(), _loadRecommendations()]),
        child: ListView(children: [
          _weatherCard(context),
          if (profile != null) _chipRow(profile, aesthetics),
          _recommendationSection(context, aesthetics),
          const SizedBox(height: 24),
        ]),
      ),
    );
  }

  Widget _weatherCard(BuildContext context) {
    final w = _weather;
    return Card(
      margin: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            const Text('오늘의 날씨', style: TextStyle(fontWeight: FontWeight.bold)),
            const Spacer(),
            if (w != null && w['is_stale'] == true)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(color: Colors.orange.shade100, borderRadius: BorderRadius.circular(6)),
                child: Text('오래된 날씨', style: TextStyle(fontSize: 11, color: Colors.orange.shade900)),
              ),
          ]),
          const SizedBox(height: 8),
          if (_locating)
            const Text('위치 확인 중…')
          else if (_weatherLoading)
            const LinearProgressIndicator()
          else if (_weatherError != null)
            Row(children: [
              const Icon(Icons.cloud_off, color: Colors.grey),
              const SizedBox(width: 8),
              Expanded(
                child: Text('날씨를 불러오지 못했어요'
                    '${_weatherError is ApiException ? ' (${(_weatherError as ApiException).code})' : ''}'),
              ),
              TextButton(onPressed: _loadWeather, child: const Text('재시도')),
            ])
          else if (w != null)
            Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
              Text('${(w['temperature_c'] as num).toStringAsFixed(1)}°',
                  style: const TextStyle(fontSize: 36, fontWeight: FontWeight.w300)),
              const SizedBox(width: 12),
              Expanded(
                child: Text('${precipitationLabels[w['precipitation_type']] ?? '-'}'
                    '${w['humidity'] != null ? ' · 습도 ${w['humidity']}%' : ''}'),
              ),
            ]),
          const SizedBox(height: 8),
          Row(children: [
            Icon(_regionMode ? Icons.location_city : Icons.my_location, size: 16, color: Colors.grey),
            const SizedBox(width: 4),
            Expanded(
              child: Text(_regionMode ? regions[_region]! : (_locationNote ?? ''),
                  style: const TextStyle(fontSize: 12, color: Colors.grey)),
            ),
            const Text('지역 직접 선택', style: TextStyle(fontSize: 12)),
            Switch(
              value: _regionMode,
              onChanged: (on) {
                if (!on && _lat == null) {
                  _locate();
                  return;
                }
                setState(() => _regionMode = on);
                _loadWeather();
                _loadRecommendations();
              },
            ),
          ]),
          if (_regionMode)
            Row(children: [
              Expanded(
                child: DropdownButton<String>(
                  isExpanded: true,
                  value: _region,
                  items: [for (final e in regions.entries) DropdownMenuItem(value: e.key, child: Text(e.value))],
                  onChanged: (v) {
                    if (v == null) return;
                    setState(() => _region = v);
                    _loadWeather();
                    _loadRecommendations();
                  },
                ),
              ),
              const SizedBox(width: 8),
              const ProposalBadge(tooltip: '위치 권한 거절 시 지역 직접 선택(시·도 17개) — PM 협의 중'),
            ]),
          if (_locationNote != null && _regionMode && _lat == null)
            Text(_locationNote!, style: const TextStyle(fontSize: 11, color: Colors.grey)),
        ]),
      ),
    );
  }

  Widget _chipRow(Json profile, List<Json>? aesthetics) {
    final prefs = (profile['preferences'] as List? ?? const []).cast<Json>();
    final ids = myAestheticIds(profile);
    final mainId = ids.isEmpty ? null : ids.first;
    final selected = _chipId ?? mainId;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Row(children: [
          Text('추구미', style: TextStyle(fontWeight: FontWeight.bold)),
          SizedBox(width: 6),
          ProposalBadge(tooltip: '선택 Chip 0.6 · 메인 0.25 · 보조 0.15 가중, 보조 0~2개 — PM 협의 중'),
        ]),
        const SizedBox(height: 6),
        Wrap(spacing: 8, children: [
          for (final id in ids)
            ChoiceChip(
              label: Text('${aestheticName(aesthetics, id)} · '
                  '${prefs.firstWhere((p) => p['aesthetic_id'] == id)['role'] == 'main' ? '메인' : '보조'}'),
              selected: selected == id,
              onSelected: (_) {
                setState(() => _chipId = id == mainId ? null : id);
                _loadRecommendations();
              },
            ),
        ]),
      ]),
    );
  }

  Widget _recommendationSection(BuildContext context, List<Json>? aesthetics) {
    final header = SectionTitle('AI 추천 코디',
        trailing: IconButton(
            tooltip: '추천 다시 받기', onPressed: _recoLoading ? null : _loadRecommendations, icon: const Icon(Icons.refresh)));
    if (_locating || (_recoLoading && _set == null)) {
      return Column(children: [header, const Padding(padding: EdgeInsets.all(32), child: CircularProgressIndicator())]);
    }
    if (_recoError != null) return Column(children: [header, ErrorPanel(_recoError!, onRetry: _loadRecommendations)]);
    final set = _set;
    if (set == null) return header;
    final outfits = (set['outfits'] as List? ?? const []).cast<Json>();
    final reasons = (set['shortfall_reasons'] as List? ?? const []).cast<String>();
    if (set['status'] == 'insufficient_wardrobe' || outfits.isEmpty) {
      return Column(children: [
        header,
        Padding(
          padding: const EdgeInsets.all(24),
          child: Column(children: [
            const Icon(Icons.checkroom, size: 48, color: Colors.grey),
            const SizedBox(height: 8),
            const Text('옷장을 채우면 추천을 받을 수 있어요', style: TextStyle(fontWeight: FontWeight.bold)),
            for (final r in reasons) Text(shortfallText(r), style: const TextStyle(fontSize: 12, color: Colors.grey)),
            const SizedBox(height: 12),
            FilledButton.icon(onPressed: () => context.go('/closet'), icon: const Icon(Icons.add), label: const Text('옷 등록하러 가기')),
          ]),
        ),
      ]);
    }
    final weather = set['weather'] as Json?;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      header,
      if (reasons.isNotEmpty)
        Card(
          margin: const EdgeInsets.symmetric(horizontal: 16),
          color: Colors.blueGrey.shade50,
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Row(children: [
                Text('추천이 부족한 이유', style: TextStyle(fontWeight: FontWeight.bold)),
                SizedBox(width: 6),
                ProposalBadge(tooltip: '추천 3개 미만이면 만든 만큼 보여 주고 사유 표시 — PM 협의 중'),
              ]),
              for (final r in reasons) Text('• ${shortfallText(r)}'),
            ]),
          ),
        ),
      SizedBox(
        height: 330,
        child: PageView.builder(
          controller: _pager,
          itemCount: outfits.length,
          onPageChanged: (i) => setState(() => _page = i),
          itemBuilder: (_, i) => _outfitCard(outfits[i], i, outfits.length, weather, aesthetics, set),
        ),
      ),
      Center(child: Text('[${_page + 1}/${outfits.length}]')),
    ]);
  }

  Widget _outfitCard(Json outfit, int index, int total, Json? weather, List<Json>? aesthetics, Json set) {
    final ids = (outfit['garment_ids'] as List).cast<String>();
    final facts = (outfit['reason_facts'] as List? ?? const []).cast<String>();
    final explanation = outfit['explanation'] as String?;
    return Card(
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Text('코디 ${index + 1}/$total', style: const TextStyle(fontWeight: FontWeight.bold)),
            const Spacer(),
            Text('${aestheticName(aesthetics, set['selected_aesthetic_id'] as String?)}'
                '${weather != null ? ' · ${(weather['temperature_c'] as num).toStringAsFixed(0)}°' : ''}',
                style: const TextStyle(fontSize: 12, color: Colors.grey)),
          ]),
          const SizedBox(height: 8),
          SizedBox(
            height: 92,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: ids.length,
              separatorBuilder: (_, _) => const SizedBox(width: 8),
              itemBuilder: (_, i) => GarmentThumb(ids[i], size: 72),
            ),
          ),
          const SizedBox(height: 8),
          Expanded(
            child: SingleChildScrollView(
              child: Text(
                explanation ?? (facts.isEmpty ? '추천 이유 정보가 없어요' : facts.map((f) => '• $f').join('\n')),
                style: const TextStyle(fontSize: 13),
              ),
            ),
          ),
          Text('AI 추천 이유 (${outfit['explanation_source'] == 'llm' ? 'LLM' : '규칙 템플릿'})',
              style: const TextStyle(fontSize: 11, color: Colors.grey)),
          const SizedBox(height: 6),
          Row(children: [
            Expanded(child: OutlinedButton(onPressed: () => _saveOutfit(outfit), child: const Text('보관함 저장'))),
            const SizedBox(width: 6),
            Expanded(
              child: OutlinedButton(
                onPressed: () => context.push('/mix/compose',
                    extra: ComposeOutfitArgs(initialGarmentIds: ids, sourceRecommendationId: set['id'] as String)),
                child: const Text('스타일 믹스'),
              ),
            ),
            const SizedBox(width: 6),
            Expanded(child: FilledButton(onPressed: () => _wearToday(outfit), child: const Text('오늘 입기'))),
          ]),
          const Align(
            alignment: Alignment.centerRight,
            child: Padding(
              padding: EdgeInsets.only(top: 4),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Text('하루 여러 건 기록 허용', style: TextStyle(fontSize: 11, color: Colors.grey)),
                SizedBox(width: 4),
                ProposalBadge(tooltip: '같은 날 다른 코디는 추가 기록, 같은 코디를 다시 누르면 기존 기록을 돌려줌 — PM 협의 중'),
              ]),
            ),
          ),
        ]),
      ),
    );
  }
}
