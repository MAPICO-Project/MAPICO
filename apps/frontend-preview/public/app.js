'use strict';
const $ = (selector) => document.querySelector(selector);
let activeMood = '캐주얼';
const saved = new Set();
const styles = {
  '캐주얼': ['편안함에 한 스푼의 귀여움', '크림 티셔츠와 데님에 핑크 포인트. 익숙한 옷도 함께 입으면 새로워져요.', '#e9ddc5', '#8894b2'],
  '페미닌': ['부드럽게, 나다운 하루', '로즈 톤과 크림 컬러를 함께 놓아본 샘플이에요.', '#d8a1ae', '#ded3bf'],
  'Y2K': ['작은 포인트, 확실한 존재감', '라일락과 데님을 함께 놓아본 샘플이에요.', '#b8a6d6', '#7b8daf'],
  '미니멀': ['덜어내도 충분히 멋있게', '차분한 뉴트럴 컬러로 구성한 샘플이에요.', '#ddd8cf', '#666c67'],
  '그런지': ['조금은 자유로운 리듬', '차콜과 워싱 데님을 함께 놓아본 샘플이에요.', '#565759', '#747f8b']
};
let toastTimer;
function notify(message) {
  $('#toast').textContent = message; $('#toast').hidden = false;
  clearTimeout(toastTimer); toastTimer = setTimeout(() => { $('#toast').hidden = true; }, 3200);
}
function showPage(page) {
  if (!['home', 'closet', 'studio', 'feed'].includes(page)) return;
  document.querySelectorAll('.page').forEach(el => { el.hidden = el.id !== page; });
  document.querySelectorAll('[data-page]').forEach(el => {
    if (el.dataset.page === page) el.setAttribute('aria-current', 'page'); else el.removeAttribute('aria-current');
  });
  history.replaceState(null, '', '#' + page); window.scrollTo(0, 0);
}
document.querySelectorAll('[data-page]').forEach(button => button.addEventListener('click', () => showPage(button.dataset.page)));
document.querySelectorAll('[data-mood]').forEach(button => button.addEventListener('click', () => {
  activeMood = button.dataset.mood;
  document.querySelectorAll('[data-mood]').forEach(el => el.setAttribute('aria-pressed', String(el === button)));
  const [title, desc, top, bottom] = styles[activeMood];
  $('#outfit-title').textContent = title; $('#outfit-desc').textContent = desc; $('#selected-mood').textContent = activeMood + ' 무드';
  $('#hero-art .shirt').style.backgroundColor = top; $('#hero-art .pants').style.backgroundColor = bottom;
}));
function row(mood, detail) {
  const div = document.createElement('div'); div.className = 'saved-row';
  const strong = document.createElement('strong'); strong.textContent = mood + ' 샘플 코디';
  const small = document.createElement('small'); small.textContent = detail;
  div.append(strong, small); return div;
}
$('#save-look').addEventListener('click', () => {
  if (saved.has(activeMood)) return notify('이미 이 샘플 코디를 보관했어요.');
  saved.add(activeMood); if (saved.size === 1) $('#saved-looks').replaceChildren();
  $('#saved-looks').append(row(activeMood, '날짜 없는 보관 · 이 탭에서만 유지'));
  notify('코디 보관함에 임시로 담았어요.');
});
$('#wear-look').addEventListener('click', () => {
  $('#worn-look').replaceChildren(row(activeMood, new Intl.DateTimeFormat('ko-KR').format(new Date()) + ' · 샘플 기록'));
  notify('오늘의 샘플 기록을 변경했어요. DB에는 저장되지 않아요.');
});
const clothes = [ ['크림 티셔츠','상의','shirt'], ['블루 데님','하의','pants'], ['핑크 미니백','가방','bag'] ];
function renderCloset(category) {
  $('#closet-items').replaceChildren();
  clothes.filter(item => category === '전체' || item[1] === category).forEach(([name, cat, shape]) => {
    const article = document.createElement('article'); article.className = 'item';
    const art = document.createElement('div'); art.className = 'item-art'; art.setAttribute('aria-hidden', 'true');
    const garment = document.createElement('div'); garment.className = 'garment ' + shape; art.append(garment);
    const title = document.createElement('h3'); title.textContent = name;
    const caption = document.createElement('p'); caption.textContent = cat + ' · 샘플 아이템';
    article.append(art, title, caption); $('#closet-items').append(article);
  });
}
document.querySelectorAll('[data-category]').forEach(button => button.addEventListener('click', () => {
  document.querySelectorAll('[data-category]').forEach(el => el.setAttribute('aria-pressed', String(el === button)));
  renderCloset(button.dataset.category);
}));
document.querySelectorAll('.like').forEach(button => button.addEventListener('click', () => {
  const liked = button.getAttribute('aria-pressed') !== 'true'; button.setAttribute('aria-pressed', String(liked)); button.textContent = liked ? '♥' : '♡';
}));
$('#upload-guide').addEventListener('click', () => $('#guide').showModal());
$('#close-guide').addEventListener('click', () => $('#guide').close());
$('#profile').addEventListener('click', () => notify('데모 프로필이에요. 로그인은 아직 연결되지 않았어요.'));
renderCloset('전체'); showPage(location.hash.slice(1) || 'home');
