// Derive the review ERDs from migrations in disposable embedded PostgreSQL.
import fs from 'node:fs/promises';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
import {createRequire} from 'node:module';
const here=path.dirname(fileURLToPath(import.meta.url));
const backend=path.resolve(here,'../../backend');
const require=createRequire(path.join(backend,'package.json'));
const {PGlite}=require('@electric-sql/pglite');
const db=new PGlite();
try {
 await db.exec(`create role anon; create role authenticated; create role service_role bypassrls;
 create schema auth; create schema storage; create table auth.users(id uuid primary key);
 create function auth.uid() returns uuid language sql stable as $$select nullif(current_setting('request.jwt.claim.sub', true),'')::uuid$$;
 grant usage on schema public,auth,storage to anon,authenticated,service_role;
 create table storage.buckets(id text primary key,name text,public boolean,file_size_limit bigint,allowed_mime_types text[]);
 create table storage.objects(id uuid default gen_random_uuid(),bucket_id text,name text,owner_id uuid,metadata jsonb default '{}',updated_at timestamptz not null default now());
 alter table storage.objects enable row level security; grant select on storage.objects to authenticated;`);
 const migrations=(await fs.readdir(path.join(backend,'supabase/migrations'))).filter(n=>n.endsWith('.sql')).sort();
 for(const file of migrations)await db.exec((await fs.readFile(path.join(backend,'supabase/migrations',file),'utf8')).replace(/create extension if not exists pgcrypto;/gi,''));
 const columns=(await db.query(`select table_name,column_name,data_type,is_nullable from information_schema.columns where table_schema='public' order by table_name,ordinal_position`)).rows;
 const constraints=(await db.query(`select t.relname as child,c.contype as type,pt.relname as parent,pn.nspname as parent_schema,
 array(select a.attname from unnest(c.conkey) with ordinality k(num,ord) join pg_attribute a on a.attrelid=c.conrelid and a.attnum=k.num order by k.ord) as cols,
 array(select a.attname from unnest(c.confkey) with ordinality k(num,ord) join pg_attribute a on a.attrelid=c.confrelid and a.attnum=k.num order by k.ord) as parent_cols
 from pg_constraint c join pg_class t on t.oid=c.conrelid join pg_namespace n on n.oid=t.relnamespace
 left join pg_class pt on pt.oid=c.confrelid left join pg_namespace pn on pn.oid=pt.relnamespace
 where n.nspname='public' and c.contype in ('p','u','f') order by t.relname,c.conname`)).rows;
 const names=[...new Set(columns.map(c=>c.table_name))];
 const groups=[
  ['계정·취향·중복 요청',['profiles','aesthetics','user_aesthetic_preferences','tpo_presets','idempotency_keys']],
  ['옷 등록·분석·확정',['profiles','aesthetics','garment_batches','garment_assets','analysis_jobs','garment_drafts','garments','garment_aesthetic_scores']],
  ['추천·보관함·착용 기록',['profiles','tpo_presets','garments','weather_snapshots','recommendation_requests','outfit_recommendations','outfit_items','saved_outfits','saved_outfit_items','ootd_entries']],
  ['피드·좋아요·따라입기',['profiles','aesthetics','ootd_entries','feed_posts','feed_media','post_likes','mimic_requests','mimic_source_items','mimic_candidate_items']],
 ];
 const covered=new Set(groups.flatMap(g=>g[1]));
 if(names.some(n=>!covered.has(n))||covered.size!==names.length)throw Error('Table coverage mismatch');
 const business=new Set(['status','category','display_name','weight','code','onboarding_completed','worn_on','wear_status','item_snapshot','visibility','source_item_key','garment_version','storage_object_id','asset_id','feed_media_id','garment_id','scope','key','position']);
 let md=`# DB 흐름과 상세 ERD\n\n2026-10-02 팀 검토본. 현재 migration ${migrations.length}개를 일회용 PGlite에 적용해 **public 테이블 ${names.length}개**의 실제 컬럼·PK·FK·UNIQUE를 조회했다. 원격 DB는 접근하지 않았고 Auth/Storage는 로컬 스텁이다.\n\n도메인 요약도의 화살표는 업무 흐름이며 FK가 아니다. 상세 ERD는 실제 FK만 표시하며, 읽기 쉽게 PK·FK와 주요 업무 필드만 보여준다. 겹치는 테이블은 같은 테이블의 재표시다. 전체 컬럼·제약은 [migration](../../backend/supabase/migrations/)과 [DB 설계](../../backend/docs/DB_DESIGN.md)가 기준이다.\n\n## 1. 데이터가 이어지는 흐름\n\n\`\`\`mermaid\nflowchart TD\n A["계정·취향<br/>profiles / aesthetics / user_aesthetic_preferences"] --> B["옷 등록·분석<br/>garment_batches / garment_assets<br/>analysis_jobs / garment_drafts"]\n B -->|"사용자 검토·확정"| C["내 옷장<br/>garments / garment_aesthetic_scores"]\n A --> D["날씨·추천<br/>weather_snapshots / recommendation_requests<br/>outfit_recommendations / outfit_items"]\n C --> D\n C --> E["재사용 코디 보관<br/>saved_outfits / saved_outfit_items"]\n D --> E\n D -->|"채택"| F["날짜별 비공개 착용 기록<br/>ootd_entries · item_snapshot"]\n E -->|"별도 기록"| F\n F -->|"사용자가 명시적으로 공유"| G["공개 게시물·공유 복사본<br/>feed_posts / feed_media / post_likes"]\n G --> H["따라입기 작업<br/>mimic_requests / mimic_source_items<br/>mimic_candidate_items"]\n C -. "생성 시 후보 스냅샷 · FK 아님" .-> H\n H -->|"사용자 확인·별도 저장"| E\n I["공통 지원<br/>idempotency_keys: 중복 요청 방지<br/>tpo_presets: 호환 카탈로그·정책 미결"]\n\`\`\`\n\n## ERD 범례\n\n- PK: 기본 키, FK: 외래 키, UK: 유일 키. 복합 키는 여러 컬럼이 함께 구성한다.\n- 관계 끝의 한 줄은 1, 원은 0 허용, 갈퀴는 여러 행을 뜻한다. 컬럼 주석 nullable은 NULL 허용이다.\n- 실선은 FK 컬럼이 자식 PK에 포함되는 식별 관계, 점선은 비식별 FK다. **점선도 실제 FK**이며 논리적 추정 관계라는 뜻이 아니다.\n- FK의 NULL 허용과 UNIQUE/PK 제약을 기준으로 관계 수를 도출한다. 부분 unique index 및 RPC의 추가 업무 제약은 관계 수에 모두 표현하지 않는다.\n- profiles와 auth_users는 같은 ID를 쓰며 auth_users는 외부 auth.users 표시용 이름이다. 24개 public 테이블 집계에는 넣지 않는다.\n\n`;
 for(let i=0;i<groups.length;i++){
  const [title,tables]=groups[i];const set=new Set(tables);let diagram='erDiagram\n  direction TB\n';
  const fks=constraints.filter(c=>c.type==='f'&&set.has(c.child)&&(set.has(c.parent)||c.parent_schema==='auth'));
  for(const fk of fks){
   const keys=constraints.filter(c=>c.child===fk.child&&['p','u'].includes(c.type));
   const single=keys.some(k=>k.cols.every(n=>fk.cols.includes(n)));
   const optional=fk.cols.some(n=>columns.find(c=>c.table_name===fk.child&&c.column_name===n)?.is_nullable==='YES');
   const pk=keys.find(k=>k.type==='p');const identifying=pk&&fk.cols.every(n=>pk.cols.includes(n));
   const label=fk.cols.filter(n=>n!=='user_id').join('_')||'user_id';
   diagram+=`  ${fk.parent_schema==='auth'?'auth_users':fk.parent} ${optional?'o|':'||'}${identifying?'--':'..'}${single?'o|':'o{'} ${fk.child} : "${label}"\n`;
  }
  if(fks.some(f=>f.parent_schema==='auth'))diagram+='  auth_users {\n    uuid id PK\n  }\n';
  for(const table of tables){
   diagram+=`  ${table} {\n`;
   for(const col of columns.filter(c=>c.table_name===table)){
    const keys=constraints.filter(c=>c.child===table&&c.cols.includes(col.column_name));
    if(!keys.some(c=>['p','f'].includes(c.type))&&!business.has(col.column_name))continue;
    const flags=[];if(keys.some(k=>k.type==='p'))flags.push('PK');if(keys.some(k=>k.type==='f'))flags.push('FK');if(keys.some(k=>k.type==='u'&&k.cols.length===1))flags.push('UK');
    const type=col.data_type.replaceAll(' ','_');
    diagram+=`    ${type} ${col.column_name}${flags.length?' '+flags.join(','):''} "${col.is_nullable==='YES'?'nullable':'required'}"\n`;
   }
   diagram+='  }\n';
  }
  md+=`## ${i+2}. ${title}\n\n\`\`\`mermaid\n${diagram}\`\`\`\n\n`;
 }
 md+=`## 관계를 읽을 때 주의할 점\n\n1. mimic_source_items.feed_media_id와 mimic_candidate_items.garment_id·asset_id는 저장된 식별자지만 **실제 FK가 아니다**. 두 테이블의 job_id만 mimic_requests를 참조한다. 공개성·자산 변경·후보 유효성은 RPC가 스냅샷과 현재 상태를 대조한다. 기존 ERD의 이 부분은 논리 참조와 FK가 섞여 있어 이번 공유본에서 바로잡았다.\n2. ootd_entries.item_snapshot은 기록 당시 의류를 담는 JSON이다. garments를 직접 가리키는 항목별 FK 테이블이 아니다. saved_outfit_id와 outfit_id는 둘 다 NULL일 수 있고 동시에 지정할 수는 없다.\n3. 사용자 소유권은 여러 관계에서 (user_id, id) 복합 FK로 확인한다. 실제 컬럼을 생략한 단순 ID 관계로 바꾸지 않았다.\n4. 원본·누끼는 garment_assets, 공유 이미지는 feed_media로 분리한다. Storage 객체의 ID/경로를 갖는 것과 storage.objects에 FK가 있는 것은 다르다. DB 행 삭제가 Storage 파일 삭제를 자동 보장하지 않는다.\n5. 하루 OOTD 수, wear_status, TPO 제품 정책과 최종 추구미 명칭은 DB의 현재 제약과 별개로 미결 상태를 유지한다.\n\n[기존 ERD](../../backend/docs/ERD.md) · [DB 설계](../../backend/docs/DB_DESIGN.md) · [시스템 아키텍처](ARCHITECTURE.md). 기존 백엔드 문서와 SQL은 이 작업에서 수정하지 않았다.\n`;
 await fs.writeFile(path.join(here,'ERD.md'),md);
 console.log(JSON.stringify({migrations:migrations.length,publicTables:names.length,foreignKeys:constraints.filter(c=>c.type==='f').length,diagrams:5,output:'ERD.md'}));
}finally{await db.close()}
