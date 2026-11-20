// Checagem rápida do site: roda no Vercel CI (tarefa "check" do Turborepo).
// 1. index.html existe e tem a estrutura básica.
// 2. Todo <script> inline do index.html compila (sem erro de sintaxe).
// 3. Todo .js em api/ (funções da Vercel) compila.
import { readFileSync, writeFileSync, existsSync, readdirSync, statSync } from "node:fs";
import { join } from "node:path";
import vm from "node:vm";
import { tmpdir } from "node:os";
import { execFileSync } from "node:child_process";

const erros = [];
const html = readFileSync("index.html", "utf8");

for (const tag of ["<!DOCTYPE html>", "<html", "<head", "<body", "</html>"]) {
  if (!html.toLowerCase().includes(tag.toLowerCase())) erros.push(`index.html sem ${tag}`);
}

const inline = [...html.matchAll(/<script(?![^>]*\bsrc=)([^>]*)>([\s\S]*?)<\/script>/gi)];
inline.forEach(([, attrs, code], i) => {
  if (/type=["']?(application\/(ld\+)?json|text\/template)/i.test(attrs)) return;
  try {
    if (/type=["']?module/i.test(attrs)) {
      const tmp = join(tmpdir(), `vanguarda-check-${i}.mjs`);
      writeFileSync(tmp, code);
      execFileSync(process.execPath, ["--check", tmp], { stdio: "pipe" });
    } else new vm.Script(code, { filename: `index.html <script #${i + 1}>` });
  } catch (e) {
    erros.push(`index.html <script #${i + 1}>: ${e.stderr ? String(e.stderr).trim() : e.message}`);
  }
});

function arquivosJs(dir) {
  if (!existsSync(dir)) return [];
  return readdirSync(dir).flatMap((nome) => {
    const p = join(dir, nome);
    if (statSync(p).isDirectory()) return arquivosJs(p);
    return /\.(m?js|cjs)$/.test(nome) ? [p] : [];
  });
}
const funcoes = arquivosJs("api");
for (const arq of funcoes) {
  try {
    execFileSync(process.execPath, ["--check", arq], { stdio: "pipe" });
  } catch (e) {
    erros.push(`${arq}: ${String(e.stderr).trim()}`);
  }
}

if (erros.length) {
  console.error("Falhou:\n- " + erros.join("\n- "));
  process.exit(1);
}
console.log(`OK: index.html (${inline.length} script(s) inline) e ${funcoes.length} função(ões) em api/.`);
