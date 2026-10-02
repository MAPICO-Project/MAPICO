import { createHash } from "node:crypto";
import { copyFile, readFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import path from "node:path";

const scriptDirectory = path.dirname(fileURLToPath(import.meta.url));
const appDirectory = path.resolve(scriptDirectory, "..");
const repositoryRoot = path.resolve(appDirectory, "..", "..", "..");
const source = path.resolve(appDirectory, "..", "openapi.yaml");
const target = path.join(appDirectory, "openapi.yaml");
const checkOnly = process.argv.includes("--check");

const digest = (contents) => createHash("sha256").update(contents).digest("hex");

async function readRequired(filePath, label) {
  try {
    return await readFile(filePath);
  } catch (error) {
    if (error?.code === "ENOENT") {
      throw new Error(`${label} 파일을 찾을 수 없습니다: ${filePath}`);
    }
    throw error;
  }
}

const sourceContents = await readRequired(source, "OpenAPI 정본");

if (checkOnly) {
  const targetContents = await readRequired(target, "Swagger UI 사본");

  if (digest(sourceContents) !== digest(targetContents)) {
    console.error("OpenAPI 사본이 정본과 다릅니다. `npm run sync`를 실행하세요.");
    process.exitCode = 1;
  } else {
    console.log(`OpenAPI 동기화 확인 완료: ${digest(sourceContents)}`);
  }
} else {
  await copyFile(source, target);
  console.log(`OpenAPI 동기화 완료: ${path.relative(repositoryRoot, source)} -> ${path.relative(repositoryRoot, target)}`);
  console.log(`SHA-256: ${digest(sourceContents)}`);
}
