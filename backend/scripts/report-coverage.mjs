import { readFile, readdir, stat } from 'node:fs/promises';
import { resolve } from 'node:path';

const root = resolve(import.meta.dirname, '..');
const openapiText = await readFile(resolve(root, 'docs/openapi.yaml'), 'utf8');
const openapi = JSON.parse(openapiText.slice(openapiText.indexOf('{')));
const implementation = JSON.parse(await readFile(resolve(root, 'coverage/implementation.json'), 'utf8'));
const methods = new Set(['get', 'post', 'put', 'patch', 'delete']);
const operations = new Map();
for (const [path, item] of Object.entries(openapi.paths ?? {})) {
  for (const [method, operation] of Object.entries(item)) {
    if (methods.has(method) && operation?.operationId) {
      operations.set(operation.operationId, { path, method, status: operation['x-implementation-status'] });
    }
  }
}

const migrationDir = resolve(root, 'supabase/migrations');
const migrationFiles = (await readdir(migrationDir)).filter(name => name.endsWith('.sql')).sort();
const tables = new Set();
for (const file of migrationFiles) {
  const sql = await readFile(resolve(migrationDir, file), 'utf8');
  for (const match of sql.matchAll(/create\s+table\s+public\.([a-z][a-z0-9_]*)/gi)) tables.add(match[1]);
}

const errors = [];
const implemented = Object.entries(implementation.operations ?? {});
for (const [operationId, entry] of implemented) {
  const contract = operations.get(operationId);
  if (!contract) errors.push(`unknown operation: ${operationId}`);
  if (contract && contract.status !== entry.status) errors.push(`status mismatch: ${operationId}`);
  for (const table of entry.tables ?? []) if (!tables.has(table)) errors.push(`unknown table: ${table}`);
  for (const file of [entry.contract_test, entry.rls_test]) {
    try { if (!(await stat(resolve(root, file))).isFile()) errors.push(`not a file: ${file}`); }
    catch { errors.push(`missing evidence: ${file}`); }
  }
  if (entry.rls_test) {
    try {
      const rlsEvidence = await readFile(resolve(root, entry.rls_test), 'utf8');
      for (const table of entry.tables ?? []) {
        if (!new RegExp(`\\b${table}\\b`).test(rlsEvidence)) errors.push(`RLS evidence does not name ${table}: ${entry.rls_test}`);
      }
    } catch {
      // Missing evidence is reported above.
    }
  }
}

const implementedIds = new Set(implemented.map(([id]) => id));
const referencedTables = new Set(implemented.flatMap(([, entry]) => entry.tables ?? []));
const report = {
  openapi: {
    total: operations.size,
    implemented_local: [...operations.values()].filter(value => value.status === 'implemented-local').length,
    planned: [...operations.values()].filter(value => value.status === 'planned').length,
    registry_covered: implementedIds.size,
    registry_missing: [...operations.keys()].filter(id => !implementedIds.has(id)).sort()
  },
  erd: {
    total_tables: tables.size,
    referenced_by_implemented_operations: referencedTables.size,
    unreferenced_tables: [...tables].filter(table => !referencedTables.has(table)).sort()
  },
  evidence: {
    contract_tested_operations: implemented.filter(([, entry]) => entry.contract_test).length,
    rls_evidence_operations: implemented.filter(([, entry]) => entry.rls_test).length
  },
  valid: errors.length === 0 && operations.size === 50 && tables.size === 24,
  errors
};
console.log(JSON.stringify(report, null, 2));
if (!report.valid) process.exitCode = 1;
