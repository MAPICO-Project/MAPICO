import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/providers.dart';
import '../../services/api.dart';
import '../../widgets/aesthetic_picker.dart';
import '../../widgets/common.dart';

/// 추구미 관리: 메인 1 + 보조 0~2 재선택 → PUT /me/aesthetics(추천 가중치에 반영).
class AestheticManageScreen extends ConsumerStatefulWidget {
  const AestheticManageScreen({super.key});

  @override
  ConsumerState<AestheticManageScreen> createState() => _AestheticManageScreenState();
}

class _AestheticManageScreenState extends ConsumerState<AestheticManageScreen> {
  String? _mainId;
  List<String>? _subIds;
  bool _busy = false;

  void _loadFrom(Json profile) {
    if (_subIds != null) return;
    final prefs = (profile['preferences'] as List? ?? const []).cast<Json>();
    _mainId = prefs.where((p) => p['role'] == 'main').map((p) => p['aesthetic_id'] as String).firstOrNull;
    _subIds = [for (final p in prefs) if (p['role'] == 'sub') p['aesthetic_id'] as String];
  }

  Future<void> _save() async {
    setState(() => _busy = true);
    try {
      await api.put('/me/aesthetics', body: preferencesBody(_mainId!, _subIds!));
      ref.invalidate(profileProvider);
      if (mounted) {
        showSnack(context, '저장했어요. 추천 데이터에 반영됩니다.');
        Navigator.of(context).pop();
      }
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final profile = ref.watch(profileProvider);
    final aesthetics = ref.watch(aestheticsProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('추구미 관리'), actions: const [ApiLogButton()]),
      body: AsyncBody(
        value: profile,
        onRetry: () => ref.invalidate(profileProvider),
        builder: (p) {
          _loadFrom(p);
          return AsyncBody(
            value: aesthetics,
            onRetry: () => ref.invalidate(aestheticsProvider),
            builder: (list) => ListView(padding: const EdgeInsets.all(20), children: [
              AestheticPicker(
                aesthetics: list,
                mainId: _mainId,
                subIds: _subIds!,
                onChanged: (m, s) => setState(() {
                  _mainId = m;
                  _subIds = s;
                }),
              ),
              const SizedBox(height: 24),
              FilledButton(onPressed: _mainId == null || _busy ? null : _save, child: const Text('저장')),
            ]),
          );
        },
      ),
    );
  }
}
