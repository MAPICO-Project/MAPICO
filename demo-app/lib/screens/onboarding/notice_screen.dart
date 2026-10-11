import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../providers/providers.dart';
import '../../services/api.dart';
import '../../widgets/common.dart';

/// 외부 AI 전송 고지(가입 시). 동의하면 PATCH /me {ai_notice_accepted:true[, training_consent]} 후 pop(true).
/// 미동의 사용자가 분석을 요청하면 서버가 403 AI_NOTICE_REQUIRED를 주고, 옷 등록 화면이 여기로 보낸다.
/// 동의는 철회할 수 없고 첫 동의 시각이 유지된다(API_DESIGN v0.4). 고지 문구는 PM·법무 확정 전 초안.
class NoticeScreen extends ConsumerStatefulWidget {
  const NoticeScreen({super.key, this.fromAnalysis = false});
  final bool fromAnalysis;

  @override
  ConsumerState<NoticeScreen> createState() => _NoticeScreenState();
}

class _NoticeScreenState extends ConsumerState<NoticeScreen> {
  bool _agree = false;
  bool _training = false;
  bool _busy = false;

  Future<void> _submit() async {
    setState(() => _busy = true);
    try {
      await api.patch('/me', {'ai_notice_accepted': true, 'training_consent': _training});
      ref.invalidate(profileProvider);
      if (mounted) context.pop(true);
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const TitleWithProposal('외부 AI 전송 고지', tooltip: '고지 문구·학습 동의 정책은 PM 협의 중')),
        body: ListView(padding: const EdgeInsets.all(20), children: [
          if (widget.fromAnalysis)
            Card(
              color: Colors.orange.shade50,
              child: const ListTile(
                leading: Icon(Icons.info_outline),
                title: Text('옷 분석 전에 고지 동의가 필요해요'),
                subtitle: Text('서버 응답: 403 AI_NOTICE_REQUIRED'),
              ),
            ),
          const Text('옷 사진 분석에 외부 AI를 사용합니다', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
          const SizedBox(height: 12),
          const Text('• 등록한 옷 사진은 의류 검출·배경 제거·카테고리 분류를 위해 외부 AI 서비스로 전송됩니다.\n'
              '• 전송된 사진은 분석 결과를 돌려받는 데에만 사용합니다.\n'
              '• 옷장 원본 사진은 공개 피드에 노출되지 않습니다.\n'
              '• 동의 후에는 철회할 수 없으며, 탈퇴 시 데이터가 삭제됩니다.'),
          const SizedBox(height: 20),
          CheckboxListTile(
            value: _agree,
            onChanged: (v) => setState(() => _agree = v ?? false),
            title: const Text('(필수) 외부 AI 전송 고지를 확인했습니다'),
            controlAffinity: ListTileControlAffinity.leading,
          ),
          CheckboxListTile(
            value: _training,
            onChanged: (v) => setState(() => _training = v ?? false),
            title: const Row(children: [Flexible(child: Text('(선택) 서비스 개선 학습에 사진 사용 동의')), SizedBox(width: 6), ProposalBadge()]),
            subtitle: const Text('현재는 저장만 하고 학습에 쓰지 않습니다. 기본값: 동의 안 함'),
            controlAffinity: ListTileControlAffinity.leading,
          ),
          const SizedBox(height: 20),
          FilledButton(onPressed: _agree && !_busy ? _submit : null, child: const Text('동의하고 계속')),
          TextButton(onPressed: () => context.pop(false), child: const Text('나중에')),
        ]),
      );
}
