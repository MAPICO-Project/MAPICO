// Render the authored Mermaid blocks to portable SVG and an offline review page.
import fs from 'node:fs/promises';
import path from 'node:path';
import {fileURLToPath, pathToFileURL} from 'node:url';
import {createServer} from 'node:http';
import {require, launchBrowser} from './tools.mjs';

const here = path.dirname(fileURLToPath(import.meta.url));
const {Marked} = await import(pathToFileURL(require.resolve('marked')).href);
const mermaidDist = path.join(path.dirname(require.resolve('mermaid/package.json')), 'dist');
const sources = [
  {file: 'USER_FLOWS.md', id: 'journey', label: '유저플로우'},
  {file: 'ARCHITECTURE.md', id: 'architecture', label: '아키텍처'},
  {file: 'FEATURE_MAP.md', id: 'features', label: '기능맵'},
  {file: 'ERD.md', id: 'database', label: 'DB·ERD'},
];
const escape = value => String(value).replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;').replaceAll('"', '&quot;');
const server = createServer(async (req, res) => {
  try {
    const url = new URL(req.url, 'http://localhost');
    if (url.pathname === '/') {res.setHeader('Content-Type', 'text/html'); res.end('<html><body></body></html>'); return;}
    const target = path.resolve(mermaidDist, '.' + decodeURIComponent(url.pathname));
    const relative = path.relative(mermaidDist, target);
    if (relative.startsWith('..') || path.isAbsolute(relative)) {res.writeHead(403).end(); return;}
    res.setHeader('Content-Type', 'text/javascript');
    res.end(await fs.readFile(target));
  } catch {res.writeHead(404).end();}
});
await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
let browser;
let diagramCount = 0;
try {
  browser = await launchBrowser();
  const page = await browser.newPage({viewport: {width: 1600, height: 1000}});
  await page.goto(`http://127.0.0.1:${server.address().port}`);
  await page.evaluate(async () => {
    window.mermaid = (await import('/mermaid.esm.min.mjs')).default;
    window.mermaid.initialize({startOnLoad: false, securityLevel: 'strict', theme: 'base',
      themeVariables: {fontFamily: 'Malgun Gothic, sans-serif', fontSize: '16px', primaryColor: '#edf3ff', primaryTextColor: '#182943', primaryBorderColor: '#7086ac', lineColor: '#587087', secondaryColor: '#fff4dc', tertiaryColor: '#eaf5ee'},
      flowchart: {htmlLabels: false, useMaxWidth: false, curve: 'basis'},
      sequence: {useMaxWidth: false, wrap: true}});
  });
  await fs.mkdir(path.join(here, 'assets'), {recursive: true});
  const sections = [];
  for (const source of sources) {
    const markdown = await fs.readFile(path.join(here, source.file), 'utf8');
    const diagrams = [];
    for (const match of markdown.matchAll(/```mermaid\s*\r?\n([\s\S]*?)```/g)) {
      const id = `${source.id}-${diagrams.length + 1}`;
      const svg = await page.evaluate(async ({id, code}) => {
        await window.mermaid.parse(code);
        return (await window.mermaid.render(id, code)).svg;
      }, {id, code: match[1]});
      await fs.writeFile(path.join(here, 'assets', `${id}.svg`), svg);
      diagrams.push({id, svg});
      diagramCount++;
    }
    let index = 0;
    const parser = new Marked({renderer: {
      code(token) {
        if (token.lang !== 'mermaid') return false;
        const diagram = diagrams[index++];
        return `<figure aria-label="${escape(source.label)} 다이어그램 ${index}"><div class="diagram-tools"><span>도식 ${index}</span><a href="assets/${diagram.id}.svg" target="_blank" rel="noopener">크게 보기 / SVG</a></div><div class="diagram">${diagram.svg}</div><details><summary>Mermaid 원본</summary><pre>${escape(token.text)}</pre></details></figure>`;
      },
      table(token) {return `<div class="table-scroll"><table>${token.header.length ? '<thead><tr>' + token.header.map(cell => '<th>' + this.parser.parseInline(cell.tokens) + '</th>').join('') + '</tr></thead>' : ''}<tbody>${token.rows.map(row => '<tr>' + row.map(cell => '<td>' + this.parser.parseInline(cell.tokens) + '</td>').join('') + '</tr>').join('')}</tbody></table></div>`;},
    }});
    sections.push(`<article id="${source.id}"><div class="source-link"><a href="${source.file}">문서 원본</a></div>${parser.parse(markdown)}</article>`);
  }
  const html = `<!doctype html>
<html lang="ko"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><title>마피코 · 흐름과 구조</title>
<style>
:root{color-scheme:light;--ink:#182943;--muted:#52637a;--line:#d9e2ed;--accent:#315cca}*{box-sizing:border-box}html{scroll-behavior:smooth;scroll-padding-top:90px}body{margin:0;background:#f3f6fa;color:var(--ink);font:16px/1.75 'Malgun Gothic',sans-serif}a{color:var(--accent);text-underline-offset:3px}header{padding:48px max(24px,calc((100vw - 1200px)/2));background:#182943;color:white}header p{max-width:850px;color:#d7e1f2}header h1{font-size:38px;line-height:1.3;margin:8px 0 20px}.eyebrow{font-size:13px;letter-spacing:2px}nav{position:sticky;top:0;z-index:3;background:#fffffff5;border-bottom:1px solid var(--line);padding:14px 24px;display:flex;justify-content:center;gap:24px;flex-wrap:wrap}nav a{text-decoration:none;font-weight:700}main{max-width:1280px;margin:auto;padding:28px 24px 80px}article{background:white;border:1px solid var(--line);border-radius:16px;padding:32px;margin-bottom:32px;min-width:0}article h1{font-size:28px;line-height:1.4}h2{font-size:22px;margin-top:40px;border-top:1px solid var(--line);padding-top:24px}h3{font-size:18px}.source-link{text-align:right;font-size:13px}figure{margin:24px 0;background:#fafcff;border:1px solid var(--line);border-radius:12px;overflow:hidden}.diagram-tools{display:flex;justify-content:space-between;gap:12px;padding:10px 16px;font-size:13px;border-bottom:1px solid var(--line)}.diagram{padding:24px;overflow:auto}.diagram svg{display:block;max-width:100%;height:auto;margin:auto;min-width:580px}details{border-top:1px solid var(--line);padding:10px 16px;font-size:13px}summary{cursor:pointer}pre{overflow:auto;white-space:pre;font:13px/1.6 monospace}code{font-size:.9em;overflow-wrap:anywhere}.table-scroll{overflow:auto}table{border-collapse:collapse;width:100%;font-size:14px}th,td{padding:12px;border:1px solid var(--line);text-align:left;vertical-align:top;min-width:110px}th{background:#edf3ff}blockquote{margin:20px 0;padding:12px 20px;border-left:4px solid #cf8b24;background:#fff7e9}footer{text-align:center;color:var(--muted);padding:20px}@media(max-width:650px){header{padding:30px 20px}header h1{font-size:30px}main{padding:16px 12px}article{padding:20px 16px}nav{gap:18px;padding:12px;font-size:14px}.diagram{padding:12px}}@media print{nav,.source-link,.diagram-tools,details{display:none}body{background:white;font-size:11px}header{padding:18px;color:#182943;background:white}header p{color:#52637a}main{padding:0}article{border:0;padding:0;break-before:page}.diagram svg{min-width:0;max-width:100%}figure{break-inside:avoid}.table-scroll{overflow:visible}table{font-size:10px}th,td{min-width:0;padding:5px}}
body{word-break:keep-all;overflow-wrap:break-word}.diagram svg{max-width:none;min-width:580px}svg text{overflow-wrap:normal}@media print{.diagram svg{max-width:100%;min-width:0}}
</style></head><body><header><div class="eyebrow">MYFIT:CORE · MAFICO / 2026.10.02</div><h1>서비스 흐름과 시스템 구조</h1><p>사용자 여정에서 API·데이터·AI 연결까지 살펴보는 팀 검토본입니다. 제품 요구사항, 백엔드 로컬 구현, 외부 연동 검증 상태와 미결 정책을 구분합니다.</p></header><nav aria-label="문서 이동">${sources.map(source => `<a href="#${source.id}">${source.label}</a>`).join('')}<a href="README.md">검토 안내</a></nav><main>${sections.join('\n')}</main><footer>사용자 내용·표현 검토 전 · 다이어그램 ${diagramCount}개 · 외부 CDN 없이 열람 가능</footer></body></html>`;
  await fs.writeFile(path.join(here, 'index.html'), html);
  console.log(JSON.stringify({documents: sources.length, diagrams: diagramCount, output: path.join(here, 'index.html')}));
} finally {await browser?.close(); await new Promise(resolve => server.close(resolve));}
