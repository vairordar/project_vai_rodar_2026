#!/usr/bin/env node
// scripts/build-dist.js — Vai Rodar build script
// Genera dist/ con rutas limpias para Netlify
// Uso: node scripts/build-dist.js   (o: npm run build)

const fs   = require("fs");
const path = require("path");

const ROOT = path.resolve(__dirname, "..");
const DIST = path.join(ROOT, "dist");
const APPS = path.join(ROOT, "apps");

// ─── Utilidades ────────────────────────────────────────────────
function rm(dir) {
  if (fs.existsSync(dir)) fs.rmSync(dir, { recursive: true, force: true });
}

function mkdirp(dir) {
  fs.mkdirSync(dir, { recursive: true });
}

function copyFile(src, dest) {
  if (!fs.existsSync(src)) { console.warn(`  SKIP (not found): ${src}`); return; }
  mkdirp(path.dirname(dest));
  fs.copyFileSync(src, dest);
  console.log(`  ✓ ${path.relative(ROOT, dest)}`);
}

function copyDir(src, dest) {
  if (!fs.existsSync(src)) { console.warn(`  SKIP dir (not found): ${src}`); return; }
  const entries = fs.readdirSync(src, { withFileTypes: true });
  for (const entry of entries) {
    const srcPath  = path.join(src,  entry.name);
    const destPath = path.join(dest, entry.name);
    if (entry.isDirectory()) {
      copyDir(srcPath, destPath);
    } else {
      mkdirp(dest);
      fs.copyFileSync(srcPath, destPath);
    }
  }
  console.log(`  ✓ ${path.relative(ROOT, dest)}/`);
}

// ─── Build ─────────────────────────────────────────────────────
console.log("\n🔧 Vai Rodar — build-dist\n");

// 1. Limpiar dist/
console.log("1. Limpiando dist/...");
rm(DIST);
mkdirp(DIST);

// 2. user-app → dist/
console.log("\n2. user-app → dist/");
copyFile(path.join(APPS, "user-app", "index.html"),   path.join(DIST, "index.html"));
copyFile(path.join(APPS, "user-app", "manifest.json"), path.join(DIST, "manifest.json"));
copyFile(path.join(APPS, "user-app", "service-worker.js"), path.join(DIST, "service-worker.js"));
copyDir( path.join(APPS, "user-app", "assets"),       path.join(DIST, "assets"));

// OneSignalSDKWorker si existe
const oneSignalSrc = path.join(APPS, "user-app", "OneSignalSDKWorker.js");
if (fs.existsSync(oneSignalSrc)) copyFile(oneSignalSrc, path.join(DIST, "OneSignalSDKWorker.js"));

// 3. workshop-entry → dist/oficinas/
console.log("\n3. workshop-entry → dist/oficinas/");
copyFile(path.join(APPS, "workshop-entry", "index.html"), path.join(DIST, "oficinas", "index.html"));

// 4. workshop-register-supabase → dist/oficinas/cadastro/
console.log("\n4. workshop-register-supabase → dist/oficinas/cadastro/");
copyFile(path.join(APPS, "workshop-register-supabase", "index.html"), path.join(DIST, "oficinas", "cadastro", "index.html"));
const wsRegAssets = path.join(APPS, "workshop-register-supabase", "assets");
if (fs.existsSync(wsRegAssets)) copyDir(wsRegAssets, path.join(DIST, "oficinas", "cadastro", "assets"));

// 5. workshop-app → dist/oficinas/painel/
console.log("\n5. workshop-app → dist/oficinas/painel/");
copyFile(path.join(APPS, "workshop-app", "index.html"), path.join(DIST, "oficinas", "painel", "index.html"));
copyDir( path.join(APPS, "workshop-app", "assets"),     path.join(DIST, "oficinas", "painel", "assets"));

// 6. admin-backoffice → dist/admin/
console.log("\n6. admin-backoffice → dist/admin/");
copyFile(path.join(APPS, "admin-backoffice", "index.html"), path.join(DIST, "admin", "index.html"));
copyDir( path.join(APPS, "admin-backoffice", "assets"),     path.join(DIST, "admin", "assets"));

// ─── Resumen ───────────────────────────────────────────────────
console.log("\n✅ dist/ generado:\n");
console.log("  /                   → user-app");
console.log("  /oficinas           → workshop-entry");
console.log("  /oficinas/cadastro  → workshop-register-supabase");
console.log("  /oficinas/painel    → workshop-app");
console.log("  /admin              → admin-backoffice");
console.log("");
