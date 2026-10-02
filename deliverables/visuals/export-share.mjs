import fs from 'node:fs/promises';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
import {launchBrowser} from './tools.mjs';

const here = path.dirname(fileURLToPath(import.meta.url));
const output = path.join(here, 'share');
const items = [
 ['journey-1', '01_전체_사용자_여정', '전체 사용자 여정', '4탭 이동과 보관·착용·공유의 관계 · 화면 구현 완료를 뜻하지 않습니다.'],
 ['journey-2', '02_로그인과_온보딩', '로그인과 온보딩', '첫 촬영은 나중에 가능 · 추구미 5종 명칭·이미지 제안 방식은 미결입니다.'],
 ['journey-3', '03_옷_등록과_AI_분석', '옷 등록과 AI 분석', '부분 성공 결과는 검토·확정 가능 · 실제 Storage·AI 워커 연동은 미검증입니다.'],
 ['journey-4', '04_날씨와_코디_추천', '날씨와 코디 추천', '현재는 결정론 추천·템플릿 설명 · LLM 설명과 위치 거절 UX는 별도입니다.'],
 ['journey-5', '05_보관함과_OOTD', '보관함과 OOTD', '보관·착용·공개 게시를 구분 · 하루 OOTD 수와 착용 상태 정책은 미결입니다.'],
 ['journey-6', '06_피드와_따라입기', '피드와 따라입기', '따라입기 결과는 별도 저장 · 실제 AI 매칭 품질과 hosted 연동은 미검증입니다.'],
 ['architecture-1', '07_시스템_구성과_신뢰_경계', '시스템 구성과 신뢰 경계', '파랑: 로컬 구현 · 주황: 목표 또는 연동 미검증 · 배포 완료 구조가 아닙니다.'],
 ['architecture-2', '08_AI_분석_처리_순서', 'AI 분석 처리 순서', 'DB 작업 대기열·서명 callback·사용자 확정 · 실제 워커 실행은 미검증입니다.'],
 ['architecture-3', '09_따라입기_처리_순서', '따라입기 처리 순서', '고정된 후보와 현재 공개 권한을 함께 확인 · 결과 조회와 보관은 별도입니다.'],
 ['architecture-4', '10_현재_추천과_AI_목표', '현재 추천과 AI 목표', '현재 BFF 결정론 엔진·템플릿 설명 · LLM은 별도 구현·평가 대상입니다.'],
 ['features-1', '11_전체_기능맵', '전체 기능맵', '백엔드 API 49/50 로컬 구현 · 화면·실제 AI·배포 완료율을 뜻하지 않습니다.'],
 ['database-1', '12_DB_전체_흐름', 'DB 전체 흐름', '24개 public 테이블의 업무 연결 · 이 요약도의 화살표는 FK가 아닙니다.'],
 ['database-2', '13_ERD_계정과_취향', 'ERD · 계정과 취향', '실제 PK·FK와 주요 필드 · 원: 0 허용 / 갈퀴: 여러 행 / nullable: NULL 허용'],
 ['database-3', '14_ERD_옷_등록과_분석', 'ERD · 옷 등록과 분석', '실제 FK만 표시 · 실선: 식별 관계 / 점선: 비식별 FK · Auth는 외부 영역'],
 ['database-4', '15_ERD_추천과_OOTD', 'ERD · 추천과 OOTD', 'OOTD는 JSON 스냅샷 보존 · 두 원본 FK는 선택적이며 동시에 지정할 수 없습니다.'],
 ['database-5', '16_ERD_피드와_따라입기', 'ERD · 피드와 따라입기', '따라입기 snapshot의 의류·이미지 ID는 FK 아님 · job_id만 실제 FK입니다.'],
];
const escape = text => text.replaceAll('&','&amp;').replaceAll('<','&lt;').replaceAll('>','&gt;');
await fs.mkdir(path.join(output, 'SVG'), {recursive:true});
await fs.mkdir(path.join(output, 'PNG'), {recursive:true});
const browser = await launchBrowser();
try {
 const page = await browser.newPage({deviceScaleFactor:2});
 const manifest = [];
 for (const [id, name, title, note] of items) {
  const source = await fs.readFile(path.join(here, 'assets', id+'.svg'), 'utf8');
  const match = source.match(/viewBox="([^"]+)"/);
  if (!match) throw new Error('Missing viewBox: '+id);
  const box = match[1].split(/[ ,]+/).map(Number);
  const width = Math.ceil(Math.max(box[2]+64, 960));
  const height = Math.ceil(box[3]+208);
  const x = (width-box[2])/2;
  const diagram = source.replace(/^<svg\b([^>]*)>/, (_whole, attrs) => `<svg${attrs.replace(/\s(?:width|height|style|x|y)="[^"]*"/g,'')} x="${x}" y="128" width="${box[2]}" height="${box[3]}">`);
  const svg = `<svg xmlns="http://www.w3.org/2000/svg" width="${width}" height="${height}" viewBox="0 0 ${width} ${height}"><rect width="100%" height="100%" fill="#ffffff"/><rect width="100%" height="108" fill="#182943"/><g font-family="Malgun Gothic, sans-serif"><text x="32" y="30" fill="#cbd9ee" font-size="13">MAFICO · MYFIT:CORE · 2026.10.02 · 팀 검토본</text><text x="32" y="66" fill="#ffffff" font-size="27" font-weight="700">${escape(title)}</text><text x="32" y="92" fill="#e3eaf5" font-size="15">${escape(note)}</text></g>${diagram}<line x1="32" y1="${height-54}" x2="${width-32}" y2="${height-54}" stroke="#d9e2ed"/><text x="32" y="${height-28}" fill="#52637a" font-family="Malgun Gothic, sans-serif" font-size="14">사용자 내용·표현 검토 전 · 로컬 구현과 실제 연동 검증을 구분합니다.</text></svg>`;
  const svgPath = path.join(output,'SVG',name+'.svg');
  await fs.writeFile(svgPath,svg);
  await page.setViewportSize({width,height});
  await page.setContent(`<html><head><meta charset="utf-8"></head><body style="margin:0;width:${width}px;height:${height}px;background:white">${svg}</body></html>`);
  if (await page.locator('parsererror').count()) throw new Error('Invalid XML: '+name);
  const fits=await page.locator('body > svg > svg').evaluate(el=>{const a=el.getBoundingClientRect(),b=el.parentElement.getBoundingClientRect();return a.right<=b.right && a.bottom<=b.bottom-54;});
  if(!fits)throw new Error('Clipped diagram: '+name);
  await page.screenshot({path:path.join(output,'PNG',name+'.png'),fullPage:true,timeout:60000});
  manifest.push({name,width:width*2,height:height*2});
 }
 console.log(JSON.stringify({output,images:manifest}));
} finally {await browser.close()}
