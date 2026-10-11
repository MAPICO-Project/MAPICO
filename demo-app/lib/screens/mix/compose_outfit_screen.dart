import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../config/labels.dart';
import '../../providers/providers.dart';
import '../../services/api.dart';
import '../../widgets/common.dart';

/// 코디 조합 화면 인자. existing이 있으면 보관함 수정, 없으면 새로 저장.
class ComposeOutfitArgs {
  const ComposeOutfitArgs({this.initialGarmentIds = const [], this.sourceRecommendationId, this.title, this.existing});
  final List<String> initialGarmentIds;
  final String? sourceRecommendationId;
  final String? title;
  final Map<String, dynamic>? existing;
}

/// 코디 조합(옷장 아이템 다중 선택) → 코디 보관함 저장(POST /saved-outfits) 또는 수정(PATCH).
class ComposeOutfitScreen extends ConsumerStatefulWidget {
  const ComposeOutfitScreen({super.key, this.args});
  final ComposeOutfitArgs? args;

  @override
  ConsumerState<ComposeOutfitScreen> createState() => _ComposeOutfitScreenState();
}

class _ComposeOutfitScreenState extends ConsumerState<ComposeOutfitScreen> {
  late final Set<String> _selected;
  late final TextEditingController _title;
  late final TextEditingController _note;
  String? _category;
  bool _grid = true;
  bool _busy = false;
  // 같은 저장 재시도 시 같은 키를 보내 중복 저장을 막는다.
  final String _idemKey = api.newIdempotencyKey();

  Json? get _existing => widget.args?.existing;

  @override
  void initState() {
    super.initState();
    final existing = _existing;
    _selected = {...(existing != null ? (existing['garment_ids'] as List).cast<String>() : widget.args?.initialGarmentIds ?? const <String>[])};
    _title = TextEditingController(text: existing?['title'] as String? ?? widget.args?.title ?? '');
    _note = TextEditingController(text: existing?['note'] as String? ?? '');
  }

  @override
  void dispose() {
    _title.dispose();
    _note.dispose();
    super.dispose();
  }

  bool get _canSave => _selected.isNotEmpty && _title.text.trim().isNotEmpty && !_busy;

  Future<void> _save() async {
    setState(() => _busy = true);
    final note = _note.text.trim().isEmpty ? null : _note.text.trim();
    try {
      final existing = _existing;
      if (existing == null) {
        await api.post('/saved-outfits', idempotencyKey: _idemKey, body: {
          'title': _title.text.trim(),
          'note': note,
          'garment_ids': _selected.toList(),
          'source_recommendation_id': widget.args?.sourceRecommendationId,
        });
      } else {
        await api.patch('/saved-outfits/${existing['id']}', {
          'expected_version': existing['version'],
          'title': _title.text.trim(),
          'note': note,
          'garment_ids': _selected.toList(),
        });
      }
      if (!mounted) return;
      showSnack(context, '코디 보관함에 저장됐어요');
      context.pop(true);
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Widget _tile(Json g) {
    final id = g['id'] as String;
    final selected = _selected.contains(id);
    final attrs = g['attributes'] as Map;
    void toggle() => setState(() => selected ? _selected.remove(id) : _selected.add(id));
    if (!_grid) {
      return CheckboxListTile(
        value: selected,
        onChanged: (_) => toggle(),
        secondary: SizedBox(width: 48, height: 48, child: ClipRRect(borderRadius: BorderRadius.circular(6), child: NetImage(g['image']))),
        title: Text(categoryLabel(attrs['category'] as String?)),
        subtitle: Text((attrs['subcategory'] ?? attrs['note'] ?? '') as String, maxLines: 1, overflow: TextOverflow.ellipsis),
      );
    }
    return InkWell(
      onTap: toggle,
      child: Stack(fit: StackFit.expand, children: [
        ClipRRect(borderRadius: BorderRadius.circular(8), child: NetImage(g['image'])),
        if (selected) Container(decoration: BoxDecoration(borderRadius: BorderRadius.circular(8), border: Border.all(color: Theme.of(context).colorScheme.primary, width: 3))),
        Positioned(
          right: 4,
          top: 4,
          child: Icon(selected ? Icons.check_circle : Icons.radio_button_unchecked, color: selected ? Theme.of(context).colorScheme.primary : Colors.white),
        ),
        Positioned(
          left: 4,
          bottom: 4,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            color: Colors.black54,
            child: Text(categoryLabel(attrs['category'] as String?), style: const TextStyle(color: Colors.white, fontSize: 11)),
          ),
        ),
      ]),
    );
  }

  @override
  Widget build(BuildContext context) {
    final garments = ref.watch(garmentsProvider);
    return Scaffold(
      appBar: AppBar(
        title: Text(_existing == null ? '코디 조합' : '보관함 코디 수정'),
        actions: [
          IconButton(
            tooltip: _grid ? '리스트로 보기' : '그리드로 보기',
            icon: Icon(_grid ? Icons.view_list : Icons.grid_view),
            onPressed: () => setState(() => _grid = !_grid),
          ),
          const ApiLogButton(),
        ],
      ),
      body: Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
          child: Column(children: [
            TextField(controller: _title, decoration: const InputDecoration(labelText: '코디 이름 (필수)'), onChanged: (_) => setState(() {})),
            TextField(controller: _note, decoration: const InputDecoration(labelText: '메모')),
          ]),
        ),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(children: [
            Padding(padding: const EdgeInsets.only(right: 6), child: ChoiceChip(label: const Text('전체'), selected: _category == null, onSelected: (_) => setState(() => _category = null))),
            for (final e in garmentCategories.entries)
              Padding(
                padding: const EdgeInsets.only(right: 6),
                child: ChoiceChip(label: Text(e.value), selected: _category == e.key, onSelected: (_) => setState(() => _category = e.key)),
              ),
          ]),
        ),
        Expanded(
          child: AsyncBody<List<Json>>(
            value: garments,
            onRetry: () => ref.invalidate(garmentsProvider),
            builder: (all) {
              final list = _category == null ? all : all.where((g) => (g['attributes'] as Map)['category'] == _category).toList();
              if (all.isEmpty) return const Center(child: Text('옷장이 비어 있어요. 먼저 옷을 등록해 주세요.'));
              if (list.isEmpty) return const Center(child: Text('이 카테고리에 옷이 없어요.'));
              return _grid
                  ? GridView.count(
                      padding: const EdgeInsets.all(12),
                      crossAxisCount: 3,
                      mainAxisSpacing: 8,
                      crossAxisSpacing: 8,
                      children: [for (final g in list) _tile(g)],
                    )
                  : ListView(children: [for (final g in list) _tile(g)]);
            },
          ),
        ),
      ]),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: FilledButton(
            onPressed: _canSave ? _save : null,
            child: Text(_busy ? '저장 중…' : '조합 완료 (${_selected.length}벌 선택)'),
          ),
        ),
      ),
    );
  }
}
