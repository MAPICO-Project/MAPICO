import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../config/labels.dart';
import '../../providers/providers.dart';
import '../../services/api.dart';
import '../../widgets/common.dart';

/// GET /me/likes — 좋아요한 코디(마이페이지 아카이브).
final _likesProvider = FutureProvider.autoDispose<List<Json>>((ref) async => ((await api.get('/me/likes')) as Json)['items'].cast<Json>() as List<Json>);

/// GET /me/posts — 내가 올린 포스트. hosted DB에서는 계약 문제 #5로 503이 날 수 있다.
final _postsProvider = FutureProvider.autoDispose<List<Json>>((ref) async => ((await api.get('/me/posts')) as Json)['items'].cast<Json>() as List<Json>);

/// 마이페이지(홈 우측 상단 프로필 아이콘으로 진입, GNB 제외).
class MyPageScreen extends ConsumerStatefulWidget {
  const MyPageScreen({super.key});

  @override
  ConsumerState<MyPageScreen> createState() => _MyPageScreenState();
}

class _MyPageScreenState extends ConsumerState<MyPageScreen> {
  bool _busy = false;

  Future<void> _run(Future<void> Function() action, {String? done}) async {
    setState(() => _busy = true);
    try {
      await action();
      ref.invalidate(profileProvider);
      if (mounted && done != null) showSnack(context, done);
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _editName(String? current) async {
    final controller = TextEditingController(text: current ?? '');
    final name = await showDialog<String>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('닉네임 수정'),
        content: TextField(controller: controller, autofocus: true, maxLength: 40, decoration: const InputDecoration(labelText: '닉네임')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c), child: const Text('취소')),
          FilledButton(onPressed: () => Navigator.pop(c, controller.text.trim()), child: const Text('저장')),
        ],
      ),
    );
    if (name == null) return;
    await _run(() => api.patch('/me', {'display_name': name.isEmpty ? null : name}), done: '닉네임을 저장했어요');
  }

  /// 프로필 이미지: 업로드 생성 → signed PUT → 서버 검증 → PATCH /me {avatar_upload_id}.
  Future<void> _changeAvatar() async {
    final file = await ImagePicker().pickImage(source: ImageSource.gallery, maxWidth: 1024);
    if (file == null) return;
    await _run(() async {
      final bytes = await file.readAsBytes();
      final created = (await api.post('/media-uploads',
          body: {'purpose': 'avatar', 'content_type': guessContentType(bytes), 'file_size': bytes.length}, idempotent: true)) as Json;
      await api.uploadSigned(created['upload'] as Json, bytes);
      await api.post('/media-uploads/${created['id']}/complete-upload');
      await api.patch('/me', {'avatar_upload_id': created['id']});
    }, done: '프로필 이미지를 바꿨어요');
  }

  Future<void> _logout() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('로그아웃할까요?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('취소')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('로그아웃')),
        ],
      ),
    );
    if (ok != true) return;
    await Supabase.instance.client.auth.signOut();
    ref.invalidate(profileProvider);
    ref.invalidate(garmentsProvider);
    if (mounted) context.go('/login');
  }

  @override
  Widget build(BuildContext context) {
    final profile = ref.watch(profileProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('마이페이지'), actions: const [ApiLogButton()]),
      body: AsyncBody(
        value: profile,
        onRetry: () => ref.invalidate(profileProvider),
        builder: (p) => RefreshIndicator(
          onRefresh: () async {
            ref.invalidate(profileProvider);
            ref.invalidate(_likesProvider);
            ref.invalidate(_postsProvider);
          },
          child: ListView(children: [
            _profileCard(p),
            const Divider(),
            ListTile(
              leading: const Icon(Icons.auto_awesome_outlined),
              title: const Text('추구미 관리'),
              subtitle: Text(_aestheticSummary(p)),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => context.push('/mypage/aesthetics'),
            ),
            ListTile(
              leading: const Icon(Icons.verified_user_outlined),
              title: const Text('외부 AI 전송 고지'),
              subtitle: Text(p['ai_notice_accepted_at'] == null ? '미동의 — 옷 분석 시 고지 화면이 열려요' : '동의함 · ${(p['ai_notice_accepted_at'] as String).substring(0, 10)}'),
              trailing: p['ai_notice_accepted_at'] == null ? TextButton(onPressed: () => context.push('/notice'), child: const Text('보기')) : null,
            ),
            SwitchListTile(
              secondary: const Icon(Icons.school_outlined),
              title: const Row(children: [Flexible(child: Text('사진 학습 동의 (선택)')), SizedBox(width: 6), ProposalBadge()]),
              subtitle: const Text('저장만 하고 아직 학습에 쓰지 않아요'),
              value: p['training_consent'] == true,
              onChanged: _busy ? null : (v) => _run(() => api.patch('/me', {'training_consent': v})),
            ),
            SectionTitle('좋아요한 코디', trailing: IconButton(icon: const Icon(Icons.refresh), onPressed: () => ref.invalidate(_likesProvider))),
            _likesGrid(),
            SectionTitle('내가 올린 포스트', trailing: IconButton(icon: const Icon(Icons.refresh), onPressed: () => ref.invalidate(_postsProvider))),
            _postsList(),
            const SectionTitle('계정 설정'),
            ListTile(leading: const Icon(Icons.logout), title: const Text('로그아웃'), onTap: _logout),
            ListTile(
              leading: const Icon(Icons.person_remove_outlined, color: Colors.red),
              title: const Text('회원 탈퇴', style: TextStyle(color: Colors.red)),
              onTap: () => context.push('/mypage/withdraw'),
            ),
            const SizedBox(height: 32),
          ]),
        ),
      ),
    );
  }

  String _aestheticSummary(Json p) {
    final all = ref.watch(aestheticsProvider).value;
    final prefs = (p['preferences'] as List? ?? const []).cast<Json>();
    if (prefs.isEmpty) return '아직 없음';
    final main = prefs.where((x) => x['role'] == 'main').map((x) => aestheticName(all, x['aesthetic_id'] as String));
    final subs = prefs.where((x) => x['role'] == 'sub').map((x) => aestheticName(all, x['aesthetic_id'] as String));
    return '메인 ${main.join()}${subs.isEmpty ? '' : ' · 보조 ${subs.join(', ')}'}';
  }

  Widget _profileCard(Json p) => Padding(
        padding: const EdgeInsets.all(16),
        child: Row(children: [
          GestureDetector(
            onTap: _busy ? null : _changeAvatar,
            child: Stack(children: [
              ClipOval(child: SizedBox(width: 72, height: 72, child: NetImage(p['avatar'], placeholderIcon: Icons.person))),
              const Positioned(right: 0, bottom: 0, child: CircleAvatar(radius: 12, child: Icon(Icons.camera_alt, size: 14))),
            ]),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text((p['display_name'] as String?) ?? '닉네임 없음', style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
              Text(Supabase.instance.client.auth.currentUser?.email ?? '', style: const TextStyle(color: Colors.grey)),
            ]),
          ),
          IconButton(tooltip: '닉네임 수정', onPressed: _busy ? null : () => _editName(p['display_name'] as String?), icon: const Icon(Icons.edit_outlined)),
        ]),
      );

  Widget _likesGrid() {
    final likes = ref.watch(_likesProvider);
    return likes.when(
      loading: () => const Padding(padding: EdgeInsets.all(16), child: Center(child: CircularProgressIndicator())),
      error: (e, _) => ErrorPanel(e, onRetry: () => ref.invalidate(_likesProvider)),
      data: (items) => items.isEmpty
          ? const Padding(padding: EdgeInsets.symmetric(horizontal: 16), child: Text('좋아요한 코디가 없어요', style: TextStyle(color: Colors.grey)))
          : GridView.count(
              crossAxisCount: 3,
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              padding: const EdgeInsets.symmetric(horizontal: 16),
              mainAxisSpacing: 6,
              crossAxisSpacing: 6,
              children: [
                for (final post in items)
                  GestureDetector(
                    onTap: () => context.push('/feed/post/${post['id']}'),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: NetImage((post['media'] as List?)?.firstOrNull, placeholderIcon: Icons.image_outlined),
                    ),
                  ),
              ],
            ),
    );
  }

  Widget _postsList() {
    final posts = ref.watch(_postsProvider);
    return posts.when(
      loading: () => const Padding(padding: EdgeInsets.all(16), child: Center(child: CircularProgressIndicator())),
      // hosted DB 권한 문제(계약 문제 #5)로 실패할 수 있다 — 오류 코드를 보여 주고 화면은 유지.
      error: (e, _) => ErrorPanel(e, onRetry: () => ref.invalidate(_postsProvider)),
      data: (items) => items.isEmpty
          ? const Padding(padding: EdgeInsets.symmetric(horizontal: 16), child: Text('올린 포스트가 없어요', style: TextStyle(color: Colors.grey)))
          : Column(children: [
              for (final post in items)
                ListTile(
                  leading: ClipRRect(
                    borderRadius: BorderRadius.circular(6),
                    child: SizedBox(width: 48, height: 48, child: NetImage((post['media'] as List?)?.firstOrNull, placeholderIcon: Icons.image_outlined)),
                  ),
                  title: Text(post['caption'] as String? ?? '', maxLines: 1, overflow: TextOverflow.ellipsis),
                  subtitle: Text('${post['visibility'] == 'public' ? '공개' : '비공개'} · ${weatherLabel(post['weather_code'] as String?)} · ♥ ${post['like_count']}'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => context.push('/feed/post/${post['id']}'),
                ),
            ]),
    );
  }
}
