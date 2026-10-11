import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../services/api.dart';
import '../../widgets/common.dart';

/// 회원 탈퇴: 삭제 범위 안내 → 확인 → DELETE /me(202 deletion_pending) → 로그아웃.
/// 삭제 범위는 API_DESIGN v0.4 §회원 탈퇴 기준이며 정책은 PM 협의 중(제안).
class WithdrawScreen extends StatefulWidget {
  const WithdrawScreen({super.key});

  @override
  State<WithdrawScreen> createState() => _WithdrawScreenState();
}

class _WithdrawScreenState extends State<WithdrawScreen> {
  static const _scope = [
    ('프로필·추구미 선호', ''),
    ('디지털 옷장', '사진·AI 분석 결과·의류'),
    ('추천 기록', ''),
    ('OOTD 캘린더·코디 보관함', ''),
    ('피드 게시물', '사진·연결 아이템, 다른 사람이 누른 좋아요 포함'),
    ('내가 누른 좋아요', ''),
    ('따라입기 기록', ''),
    ('업로드 기록', ''),
  ];

  bool _busy = false;
  Object? _error;

  Future<void> _withdraw() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('정말 탈퇴하시겠어요?'),
        content: const Text('계정과 모든 데이터가 삭제되며 되돌릴 수 없어요.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('취소')),
          FilledButton(style: FilledButton.styleFrom(backgroundColor: Colors.red), onPressed: () => Navigator.pop(c, true), child: const Text('탈퇴')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await api.delete('/me', idempotent: true);
      await Supabase.instance.client.auth.signOut();
      if (mounted) context.go('/login');
    } catch (e) {
      // 503 ACCOUNT_DELETION_INCOMPLETE(retryable): 데이터는 지워졌고 계정 삭제만 남음 → 다시 시도.
      if (mounted) setState(() => _error = e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final e = _error;
    return Scaffold(
      appBar: AppBar(title: const TitleWithProposal('회원 탈퇴', tooltip: '삭제 범위·재인증 정책은 PM 협의 중'), actions: const [ApiLogButton()]),
      body: ListView(padding: const EdgeInsets.all(20), children: [
        const Text('탈퇴하면 아래 데이터가 삭제돼요', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
        const SizedBox(height: 12),
        Table(
          border: TableBorder.all(color: Colors.grey.shade300),
          columnWidths: const {0: FlexColumnWidth(2), 1: FlexColumnWidth(3)},
          children: [
            for (final (what, note) in _scope)
              TableRow(children: [
                Padding(padding: const EdgeInsets.all(8), child: Text(what)),
                Padding(padding: const EdgeInsets.all(8), child: Text(note, style: const TextStyle(fontSize: 12, color: Colors.grey))),
              ]),
          ],
        ),
        const SizedBox(height: 8),
        const Text('※ 저장소의 이미지 파일 실제 삭제는 아직 구현되지 않았어요(정리 대기열에만 등록).', style: TextStyle(fontSize: 12, color: Colors.grey)),
        if (e != null) ...[
          const SizedBox(height: 16),
          Card(
            color: Colors.red.shade50,
            child: ListTile(
              leading: const Icon(Icons.error_outline, color: Colors.red),
              title: Text(e is ApiException ? e.message : '$e'),
              subtitle: Text(e is ApiException
                  ? '${e.code} · HTTP ${e.status}${e.code == 'ACCOUNT_DELETION_INCOMPLETE' ? ' · 데이터는 삭제됨, 계정 삭제만 다시 시도' : ''}'
                  : ''),
            ),
          ),
        ],
        const SizedBox(height: 24),
        FilledButton(
          style: FilledButton.styleFrom(backgroundColor: Colors.red),
          onPressed: _busy ? null : _withdraw,
          child: Text(e is ApiException && e.retryable ? '다시 시도' : '탈퇴하기'),
        ),
      ]),
    );
  }
}
