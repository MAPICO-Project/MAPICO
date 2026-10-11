import 'package:flutter/material.dart';

import '../services/api.dart';

/// 추구미 직접 선택: 메인 1개(필수) + 보조 0~2개. 온보딩과 마이페이지 추구미 관리가 함께 쓴다.
class AestheticPicker extends StatelessWidget {
  const AestheticPicker({super.key, required this.aesthetics, required this.mainId, required this.subIds, required this.onChanged});

  final List<Json> aesthetics;
  final String? mainId;
  final List<String> subIds;
  final void Function(String? mainId, List<String> subIds) onChanged;

  @override
  Widget build(BuildContext context) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('메인 추구미 (1개)', style: TextStyle(fontWeight: FontWeight.bold)),
        const SizedBox(height: 8),
        Wrap(spacing: 8, runSpacing: 8, children: [
          for (final a in aesthetics)
            ChoiceChip(
              label: Text(a['display_name'] as String),
              selected: mainId == a['id'],
              onSelected: (_) => onChanged(a['id'] as String, subIds.where((s) => s != a['id']).toList()),
            ),
        ]),
        const SizedBox(height: 20),
        Text('보조 추구미 (0~2개) · ${subIds.length}/2', style: const TextStyle(fontWeight: FontWeight.bold)),
        const SizedBox(height: 8),
        Wrap(spacing: 8, runSpacing: 8, children: [
          for (final a in aesthetics)
            FilterChip(
              label: Text(a['display_name'] as String),
              selected: subIds.contains(a['id']),
              onSelected: mainId == a['id']
                  ? null
                  : (on) {
                      final next = [...subIds];
                      if (on) {
                        if (next.length >= 2) return;
                        next.add(a['id'] as String);
                      } else {
                        next.remove(a['id']);
                      }
                      onChanged(mainId, next);
                    },
            ),
        ]),
      ]);
}

/// PUT /me/aesthetics 본문. weight는 생략(서버가 1/n, main ≥ sub로 정한다).
Json preferencesBody(String mainId, List<String> subIds) => {
      'preferences': [
        {'aesthetic_id': mainId, 'role': 'main'},
        for (final s in subIds) {'aesthetic_id': s, 'role': 'sub'},
      ],
    };
