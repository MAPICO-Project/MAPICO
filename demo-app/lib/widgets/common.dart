import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../config/labels.dart';
import '../providers/providers.dart';
import '../services/api.dart';

/// PM 협의 중인 항목 표시. 확정이 아님을 화면에서 구분한다.
class ProposalBadge extends StatelessWidget {
  const ProposalBadge({super.key, this.tooltip});
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final badge = Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(color: Colors.amber.shade100, borderRadius: BorderRadius.circular(6), border: Border.all(color: Colors.amber.shade700)),
      child: Text('제안', style: TextStyle(fontSize: 11, color: Colors.amber.shade900, fontWeight: FontWeight.w600)),
    );
    return tooltip == null ? badge : Tooltip(message: tooltip!, child: badge);
  }
}

/// 제목 옆에 "제안" 배지.
class TitleWithProposal extends StatelessWidget {
  const TitleWithProposal(this.title, {super.key, this.tooltip});
  final String title;
  final String? tooltip;

  @override
  Widget build(BuildContext context) => Row(mainAxisSize: MainAxisSize.min, children: [
        Flexible(child: Text(title, overflow: TextOverflow.ellipsis)),
        const SizedBox(width: 6),
        ProposalBadge(tooltip: tooltip),
      ]);
}

/// 오류 화면: 서버 오류 코드·request id를 함께 보여 준다(프론트 팀이 처리 분기를 참고하도록).
class ErrorPanel extends StatelessWidget {
  const ErrorPanel(this.error, {super.key, this.onRetry});
  final Object error;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final e = error;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const Icon(Icons.error_outline, size: 40, color: Colors.redAccent),
          const SizedBox(height: 8),
          Text(e is ApiException ? e.message : '$e', textAlign: TextAlign.center),
          if (e is ApiException) ...[
            const SizedBox(height: 4),
            Text('${e.code} · HTTP ${e.status}${e.retryable ? ' · 재시도 가능' : ''}',
                style: Theme.of(context).textTheme.bodySmall, textAlign: TextAlign.center),
          ],
          if (onRetry != null) ...[
            const SizedBox(height: 12),
            OutlinedButton.icon(onPressed: onRetry, icon: const Icon(Icons.refresh), label: const Text('다시 시도')),
          ],
        ]),
      ),
    );
  }
}

/// AsyncValue 공통 처리.
class AsyncBody<T> extends StatelessWidget {
  const AsyncBody({super.key, required this.value, required this.builder, this.onRetry});
  final AsyncValue<T> value;
  final Widget Function(T data) builder;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) => value.when(
        skipLoadingOnReload: true, // 주기적 재조회(서명 URL 갱신) 중에는 이전 화면을 유지
        data: builder,
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => ErrorPanel(e, onRetry: onRetry),
      );
}

void showSnack(BuildContext context, String message) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(message)));
}

void showError(BuildContext context, Object error) =>
    showSnack(context, error is ApiException ? '${error.message} (${error.code})' : '$error');

/// signed URL 이미지(5분 만료). 실패 시 회색 자리표시.
class NetImage extends StatelessWidget {
  const NetImage(this.asset, {super.key, this.fit = BoxFit.cover, this.placeholderIcon = Icons.checkroom});
  final dynamic asset; // AssetRead{url,expires_at} | null
  final BoxFit fit;
  final IconData placeholderIcon;

  @override
  Widget build(BuildContext context) {
    final url = asset is Map ? asset['url'] as String? : null;
    final placeholder = Container(color: Colors.grey.shade200, child: Center(child: Icon(placeholderIcon, color: Colors.grey)));
    if (url == null) return placeholder;
    return Image.network(url, fit: fit, errorBuilder: (_, _, _) => placeholder);
  }
}

/// 내 옷 썸네일(garment id → 옷장 캐시).
class GarmentThumb extends ConsumerWidget {
  const GarmentThumb(this.garmentId, {super.key, this.size = 64, this.showLabel = true});
  final String garmentId;
  final double size;
  final bool showLabel;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final g = ref.watch(garmentByIdProvider)[garmentId];
    final loading = ref.watch(garmentsProvider).isLoading; // 로딩 중을 "삭제됨"으로 오해하지 않게
    return SizedBox(
      width: size,
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: SizedBox(width: size, height: size, child: NetImage(g?['image'])),
        ),
        if (showLabel)
          Text(g == null ? (loading ? '불러오는 중' : '삭제됨') : categoryLabel((g['attributes'] as Map)['category'] as String?),
              style: const TextStyle(fontSize: 11), overflow: TextOverflow.ellipsis),
      ]),
    );
  }
}

/// 앱바에 붙이는 "API 로그" 버튼: 방금 어떤 API가 어떤 상태로 끝났는지 시연 중 보여 준다.
class ApiLogButton extends StatelessWidget {
  const ApiLogButton({super.key});

  @override
  Widget build(BuildContext context) => IconButton(
        tooltip: 'API 호출 기록',
        icon: const Icon(Icons.receipt_long_outlined),
        onPressed: () => showModalBottomSheet(
          context: context,
          builder: (_) => SafeArea(
            child: Column(children: [
              const ListTile(title: Text('최근 API 호출'), subtitle: Text('계약: backend/docs/openapi.yaml')),
              Expanded(
                child: ListView(children: [
                  for (final line in api.log)
                    Padding(padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2), child: Text(line, style: const TextStyle(fontFamily: 'monospace', fontSize: 12))),
                ]),
              ),
            ]),
          ),
        ),
      );
}

/// 섹션 제목.
class SectionTitle extends StatelessWidget {
  const SectionTitle(this.text, {super.key, this.trailing});
  final String text;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
        child: Row(children: [
          Expanded(child: Text(text, style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold))),
          ?trailing,
        ]),
      );
}
