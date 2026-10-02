import test from 'node:test';
import assert from 'node:assert/strict';
import { createHandler as feedCollection } from '../api/v1/feed/index.js';
import { createHandler as feedItem } from '../api/v1/feed/[postId]/index.js';
import { createHandler as feedMedia } from '../api/v1/feed/[postId]/media/index.js';
import { createHandler as completeMedia } from '../api/v1/feed/[postId]/media/[mediaId]/complete-upload.js';
import { createHandler as feedLike } from '../api/v1/feed/[postId]/like.js';
import { createHandler as likedPosts } from '../api/v1/me/likes.js';
import { createHandler as myPosts } from '../api/v1/me/posts.js';

const requestId = '11111111-1111-4111-8111-111111111111';
const userId = '22222222-2222-4222-8222-222222222222';
const authorId = '33333333-3333-4333-8333-333333333333';
const postId = '44444444-4444-4444-8444-444444444444';
const mediaId = '55555555-5555-4555-8555-555555555555';
const storageId = '88888888-8888-4888-8888-888888888888';
const aestheticId = '66666666-6666-4666-8666-666666666666';
const objectKey = `${userId}/${postId}/${mediaId}.png`;
const env = { SUPABASE_URL: 'https://abcdefghijklmnopqrst.supabase.co', SUPABASE_PUBLISHABLE_KEY: 'publishable-test',
  SUPABASE_SECRET_KEY: 'service-role-secret-key-for-tests' };
const rawPost = { id: postId, author: { id: authorId, display_name: 'A' }, caption: 'look', aesthetic_id: aestheticId,
  weather_code: 'unknown', temperature_c: null, visibility: 'public', liked_by_me: false, like_count: 2,
  created_at: '2026-10-01T03:00:00.000Z', media: [{ bucket_id: 'feed-private', object_key: objectKey, position: 0 }] };
const privatePost = { ...rawPost, author: { id: userId, display_name: null }, visibility: 'private', media: [] };

function response(status, body, headers = {}, bytes) {
  return { status, headers: { get: name => headers[name.toLowerCase()] ?? null }, async json() { return body; },
    async arrayBuffer() { return (bytes ?? new Uint8Array()).buffer; } };
}
function invoke(create, request, { method = 'GET', query = {}, body, headers = {} } = {}) {
  const out = { headers: {} }; const reqHeaders = { authorization: 'Bearer header.payload.signature', ...headers };
  if (body !== undefined) reqHeaders['content-type'] = 'application/json';
  const req = { method, query, body, headers: reqHeaders }; const res = { setHeader(k, v) { out.headers[k] = v; }, status(v) { out.statusCode = v; return this; },
    json(v) { out.body = v; return out; }, end() { out.ended = true; return out; } };
  return create({ env, request, now: () => new Date('2026-10-01T03:05:00.000Z'), createRequestId: () => requestId })(req, res);
}
function auth(url) { return String(url).includes('/auth/v1/user') ? response(200, { id: userId }) : null; }
function projection(url, post = rawPost) {
  return String(url).includes('/rpc/project_feed_posts') ? response(200, [post]) : null;
}
function sign(url) {
  return String(url).includes('/storage/v1/object/sign/feed-private') ? response(200, [{ path: objectKey,
    signedURL: `/storage/v1/object/sign/feed-private/${objectKey}?token=read-token` }]) : null;
}

test('public feed uses bound keyset pagination and never exposes raw feed paths', async () => {
  const second = '77777777-7777-4777-8777-777777777777';
  const request = async url => auth(url) ?? projection(url) ?? sign(url) ??
    (String(url).includes('/rest/v1/feed_posts') ? response(200, [{ id: postId, created_at: rawPost.created_at },
      { id: second, created_at: '2026-10-01T02:00:00.000Z' }]) : assert.fail(`unexpected ${url}`));
  const page = await invoke(feedCollection, request, { query: { limit: '1', weather_code: 'unknown' } });
  assert.equal(page.statusCode, 200); assert.equal(page.body.items.length, 1); assert.equal(typeof page.body.next_cursor, 'string');
  assert.equal(JSON.stringify(page.body).includes('object_key'), false); assert.match(page.body.items[0].media[0].url, /token=read-token/);
  const rebound = await invoke(feedCollection, async () => assert.fail('network'), { query: { limit: '1', weather_code: 'rain', cursor: page.body.next_cursor } });
  assert.equal(rebound.statusCode, 400);
});

test('private post create, detail, update and delete use narrow RPCs and safe projection', async () => {
  const calls = [];
  const request = async (url, options = {}) => { const value = String(url); const a = auth(url); if (a) return a;
    if (value.includes('/rpc/project_feed_posts')) return response(200, [privatePost]);
    if (value.includes('/rest/v1/feed_posts')) return response(200, [{ id: postId }]);
    if (value.includes('/rpc/create_my_feed_post')) { calls.push(JSON.parse(options.body)); return response(200, { post_id: postId }); }
    if (value.includes('/rpc/update_my_feed_post')) { calls.push(JSON.parse(options.body)); return response(200, { post_id: postId }); }
    if (value.includes('/rpc/delete_my_feed_post')) return response(200, { id: postId, status: 'deletion_pending' });
    assert.fail(`unexpected ${value}`); };
  const created = await invoke(feedCollection, request, { method: 'POST', headers: { 'idempotency-key': 'feed-post-one' },
    body: { caption: 'look', aesthetic_id: aestheticId, visibility: 'private' } });
  assert.equal(created.statusCode, 201); assert.equal(calls[0].p_weather_code, null); assert.equal(created.body.author.id, userId);
  const detail = await invoke(feedItem, request, { query: { postId } }); assert.equal(detail.statusCode, 200);
  const updated = await invoke(feedItem, request, { method: 'PATCH', query: { postId }, body: { caption: 'new' } });
  assert.equal(updated.statusCode, 200); assert.equal(calls[1].p_has_caption, true); assert.equal(calls[1].p_has_visibility, false);
  const deleted = await invoke(feedItem, request, { method: 'DELETE', query: { postId } });
  assert.deepEqual(deleted.body, { id: postId, status: 'deletion_pending' });
});

test('feed media reservation returns only a signed canonical upload and fences replay state', async () => {
  const fencePost = { id: postId, user_id: userId, visibility: 'private', deleted_at: null, updated_at: '2026-10-01T03:00:00.000Z' };
  const fenceMedia = { id: mediaId, user_id: userId, post_id: postId, bucket_id: 'feed-private', object_key: objectKey,
    content_type: 'image/png', byte_size: 128, verified_at: null, deleted_at: null, position: 0 };
  const fence = { post: fencePost, media: fenceMedia, storage: null };
  const request = async (url, options = {}) => { const value = String(url); const a = auth(url); if (a) return a;
    if (value.includes('/rpc/create_my_feed_media')) return response(200, { media_id: mediaId });
    if (value.includes('/rpc/get_feed_media_fence')) return response(200, fence);
    if (value.includes('/storage/v1/object/upload/sign/')) return response(200, { url: `/object/upload/sign/feed-private/${objectKey}?token=upload-token` });
    assert.fail(`unexpected ${value} ${options.method ?? ''}`); };
  const result = await invoke(feedMedia, request, { method: 'POST', query: { postId }, headers: { 'idempotency-key': 'feed-media-one' },
    body: { content_type: 'image/png', file_size: 128 } });
  assert.equal(result.statusCode, 201); assert.equal(result.body.media_id, mediaId); assert.equal(result.body.upload.method, 'PUT');
  assert.deepEqual(result.body.upload.headers, { 'Content-Type': 'image/png' }); assert.equal(JSON.stringify(result.body).includes(objectKey), true);
  assert.equal(Object.hasOwn(result.body, 'object_key'), false);
});

test('invalid uploaded bytes persist completion outcome and return 422 without publishing', async () => {
  const fencePost = { id: postId, user_id: userId, visibility: 'private', deleted_at: null, updated_at: '2026-10-01T03:00:00.000Z' };
  const fenceMedia = { id: mediaId, user_id: userId, post_id: postId, bucket_id: 'feed-private', object_key: objectKey,
    content_type: 'image/png', byte_size: 128, verified_at: null, deleted_at: null, position: 0 };
  const storage = { id: storageId, bucket_id: 'feed-private', name: objectKey, owner_id: userId,
    metadata: { mimetype: 'image/png', size: 128 }, updated_at: '2026-10-01T03:04:00.000Z' };
  let outcome; let completed = false;
  const request = async (url, options = {}) => { const value = String(url); const a = auth(url); if (a) return a;
    if (value.includes('/rpc/get_feed_media_fence')) return response(200,
      { post: fencePost, media: { ...fenceMedia, deleted_at: completed ? '2026-10-01T03:06:00.000Z' : null }, storage });
    if (value.includes('/storage/v1/object/authenticated/')) return response(206, null,
      { 'content-type': 'image/png', 'content-range': 'bytes 0-2/128' }, new Uint8Array([1, 2, 3]));
    if (value.includes('/rpc/complete_my_feed_media')) { outcome = JSON.parse(options.body).p_outcome; completed = true; return response(200, { invalid: true }); }
    assert.fail(`unexpected ${value}`); };
  const result = await invoke(completeMedia, request, { method: 'POST', query: { postId, mediaId },
    headers: { 'idempotency-key': 'feed-complete-one' } });
  assert.equal(result.statusCode, 422); assert.equal(outcome, 'invalid');
  const replay = await invoke(completeMedia, request, { method: 'POST', query: { postId, mediaId }, headers: { 'idempotency-key': 'feed-complete-one' } });
  assert.equal(replay.statusCode, 422);
});

test('like and unlike are bodyless 204 and archive/list projections stay visibility-gated', async () => {
  const request = async (url) => { const value = String(url); const a = auth(url); if (a) return a;
    if (value.includes('/rpc/like_my_feed_post') || value.includes('/rpc/unlike_my_feed_post')) return response(204, null);
    if (value.includes('/rpc/project_my_visible_likes')) return response(200, [{ post_id: postId, created_at: rawPost.created_at }]);
    if (value.includes('/rest/v1/feed_posts')) return response(200, [{ id: postId, created_at: rawPost.created_at }]);
    return projection(url) ?? sign(url) ?? assert.fail(`unexpected ${value}`); };
  for (const method of ['PUT', 'DELETE']) {
    const result = await invoke(feedLike, request, { method, query: { postId } });
    assert.equal(result.statusCode, 204); assert.equal(result.ended, true); assert.equal('body' in result, false);
  }
  const liked = await invoke(likedPosts, request); const mine = await invoke(myPosts, request);
  assert.equal(liked.statusCode, 200); assert.equal(mine.statusCode, 200); assert.equal(liked.body.items[0].id, postId);
});
