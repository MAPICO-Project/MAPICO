import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../config/labels.dart';
import '../../providers/providers.dart';
import '../../services/api.dart';
import '../../widgets/common.dart';

/// 디지털 옷장(USER_FLOWS §3): 카테고리 필터 + 그리드 + 옷 등록.
class ClosetScreen extends ConsumerStatefulWidget {
  const ClosetScreen({super.key});

  @override
  ConsumerState<ClosetScreen> createState() => _ClosetScreenState();
}

class _ClosetScreenState extends ConsumerState<ClosetScreen> {
  String? _category; // null = 전체

  Future<void> _register() async {
    await context.push('/closet/register');
    ref.invalidate(garmentsProvider);
  }

  @override
  Widget build(BuildContext context) {
    final garments = ref.watch(garmentsProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('디지털 옷장'), actions: const [ApiLogButton()]),
      floatingActionButton: FloatingActionButton.extended(onPressed: _register, icon: const Icon(Icons.add), label: const Text('옷 등록')),
      body: Column(children: [
        SizedBox(
          height: 52,
          child: ListView(scrollDirection: Axis.horizontal, padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8), children: [
            Padding(
              padding: const EdgeInsets.only(right: 6),
              child: ChoiceChip(label: const Text('전체'), selected: _category == null, onSelected: (_) => setState(() => _category = null)),
            ),
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
              final items = _category == null ? all : all.where((g) => (g['attributes'] as Map)['category'] == _category).toList();
              return RefreshIndicator(
                onRefresh: () => ref.refresh(garmentsProvider.future),
                child: items.isEmpty
                    ? ListView(children: [
                        const SizedBox(height: 80),
                        const Icon(Icons.checkroom, size: 56, color: Colors.grey),
                        const SizedBox(height: 8),
                        Text(all.isEmpty ? '옷장이 비어 있어요\n옷 여러 벌을 바닥에 펼쳐 한 장 찍으면 AI가 나눠 등록해요' : '이 카테고리에 옷이 없어요',
                            textAlign: TextAlign.center),
                      ])
                    : GridView.builder(
                        padding: const EdgeInsets.fromLTRB(12, 4, 12, 96),
                        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: 3, mainAxisSpacing: 8, crossAxisSpacing: 8, childAspectRatio: 0.8),
                        itemCount: items.length,
                        itemBuilder: (_, i) {
                          final g = items[i];
                          final attrs = g['attributes'] as Map;
                          return InkWell(
                            onTap: () async {
                              await context.push('/closet/garment/${g['id']}');
                              ref.invalidate(garmentsProvider);
                            },
                            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                              Expanded(child: ClipRRect(borderRadius: BorderRadius.circular(8), child: NetImage(g['image']))),
                              const SizedBox(height: 2),
                              Text(attrs['subcategory'] as String? ?? categoryLabel(attrs['category'] as String?),
                                  style: const TextStyle(fontSize: 12), overflow: TextOverflow.ellipsis),
                            ]),
                          );
                        },
                      ),
              );
            },
          ),
        ),
      ]),
    );
  }
}
