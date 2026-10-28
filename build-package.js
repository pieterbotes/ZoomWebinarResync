#!/usr/bin/env node
/**
 * Builds a Workbench-ready deploy zip from the force-app source.
 *
 *   node build-package.js owner.username@yourorg.com
 *
 * Output: deploy/zoom-webinar-resync.zip  (package.xml at the root -> tick "Single Package")
 *
 * Why this is needed:
 *   The project is in "source format" (what the sf CLI and VS Code use). Workbench only
 *   understands the older "metadata API format". The differences we handle:
 *     1. Each object's fields live in separate files in source format; in MDAPI format they are
 *        merged into ONE <object>.object file.
 *     2. Source files end in "-meta.xml" (e.g. X.md-meta.xml); MDAPI drops that (X.md),
 *        except for code files, which keep a separate .cls / .cls-meta.xml pair in both.
 *     3. MDAPI needs a package.xml manifest listing everything in the zip.
 *
 * Only Node built-ins are used (fs, path, child_process) - no npm install needed.
 */

// `require` loads a module. These three ship with Node.
const fs = require('fs');
const path = require('path');
const { execFileSync } = require('child_process');

const API_VERSION = '62.0';
const PLACEHOLDER = 'REPLACE_WITH_WEBINAR_OWNER_USERNAME';

// process.argv = ['node', 'build-package.js', ...yourArgs], so the username is index 2.
const ownerUsername = process.argv[2];
if (!ownerUsername || !ownerUsername.includes('@')) {
  console.error('Usage: node build-package.js <webinar-owner-username>');
  console.error('  e.g. node build-package.js webinar.owner@yourorg.com');
  process.exit(1); // non-zero exit code = "failed", so scripts/CI can detect it
}

// __dirname = folder this script lives in, so it works no matter where you run it from.
const SRC = path.join(__dirname, 'force-app', 'main', 'default');
const OUT_ROOT = path.join(__dirname, 'deploy');
const OUT = path.join(OUT_ROOT, 'zoom-webinar-resync');
const ZIP = path.join(OUT_ROOT, 'zoom-webinar-resync.zip');

// Start clean each run. { recursive, force } = like `rm -rf`.
fs.rmSync(OUT_ROOT, { recursive: true, force: true });
fs.mkdirSync(OUT, { recursive: true });

// The manifest: metadata type -> list of member names. Filled as we copy things.
const manifest = {};
function addToManifest(type, member) {
  (manifest[type] = manifest[type] || []).push(member);
}

function ensureDir(dir) {
  fs.mkdirSync(dir, { recursive: true });
}

// ---------- 1. Apex classes and triggers: copied as-is ----------
// Each entry: [source/target folder, file extension, metadata type name]
const codeTypes = [
  ['classes', '.cls', 'ApexClass'],
  ['triggers', '.trigger', 'ApexTrigger'],
];
for (const [folder, ext, type] of codeTypes) {
  const from = path.join(SRC, folder);
  const to = path.join(OUT, folder);
  ensureDir(to);
  for (const file of fs.readdirSync(from)) {
    fs.copyFileSync(path.join(from, file), path.join(to, file)); // copies .cls AND .cls-meta.xml
    if (file.endsWith(ext)) {
      addToManifest(type, path.basename(file, ext)); // "Foo.cls" -> "Foo"
    }
  }
}

// ---------- 2. Objects: merge field files into one .object file ----------
// Strip the XML declaration and the outer <CustomField ...> wrapper, keep the inside.
function innerXml(xml, tag) {
  const open = xml.indexOf('>', xml.indexOf(`<${tag}`)) + 1;
  const close = xml.lastIndexOf(`</${tag}>`);
  return xml.slice(open, close).trim();
}

ensureDir(path.join(OUT, 'objects'));
for (const objName of fs.readdirSync(path.join(SRC, 'objects'))) {
  const objDir = path.join(SRC, 'objects', objName);
  let objectXml = fs.readFileSync(path.join(objDir, `${objName}.object-meta.xml`), 'utf8');

  const fieldsDir = path.join(objDir, 'fields');
  const fieldBlocks = fs.existsSync(fieldsDir)
    ? fs.readdirSync(fieldsDir).sort().map((f) => {
        const fieldXml = fs.readFileSync(path.join(fieldsDir, f), 'utf8');
        // Template literal (backticks) lets us build multi-line strings with ${...} inserts.
        // Re-indent every inner line by 8 spaces so the merged file stays readable.
        const body = innerXml(fieldXml, 'CustomField').replace(/\n\s*/g, '\n        ');
        return `    <fields>\n        ${body}\n    </fields>\n`;
      })
    : [];

  // Metadata API expects elements in alphabetical order; <fields> comes just before <label>.
  const labelPos = objectXml.indexOf('    <label>');
  objectXml = objectXml.slice(0, labelPos) + fieldBlocks.join('') + objectXml.slice(labelPos);

  fs.writeFileSync(path.join(OUT, 'objects', `${objName}.object`), objectXml);
  addToManifest('CustomObject', objName);
}

// ---------- 3. Custom Metadata records + subscriber config: rename + fill placeholder ----------
// [folder, source suffix, MDAPI suffix, metadata type]
const recordTypes = [
  ['customMetadata', '.md-meta.xml', '.md', 'CustomMetadata'],
  ['PlatformEventSubscriberConfigs', '.platformEventSubscriberConfig-meta.xml', '.platformEventSubscriberConfig', 'PlatformEventSubscriberConfig'],
];
for (const [folder, srcSuffix, outSuffix, type] of recordTypes) {
  ensureDir(path.join(OUT, folder));
  for (const file of fs.readdirSync(path.join(SRC, folder))) {
    if (!file.endsWith(srcSuffix)) continue;
    const member = file.slice(0, -srcSuffix.length);
    // split/join = "replace all" that works in every Node version
    const xml = fs.readFileSync(path.join(SRC, folder, file), 'utf8').split(PLACEHOLDER).join(ownerUsername);
    fs.writeFileSync(path.join(OUT, folder, member + outSuffix), xml);
    addToManifest(type, member);
  }
}

// ---------- 4. package.xml ----------
const typesXml = Object.keys(manifest).sort().map((type) => {
  const members = manifest[type].sort().map((m) => `        <members>${m}</members>`).join('\n');
  return `    <types>\n${members}\n        <name>${type}</name>\n    </types>`;
}).join('\n');

fs.writeFileSync(path.join(OUT, 'package.xml'),
`<?xml version="1.0" encoding="UTF-8"?>
<Package xmlns="http://soap.sforce.com/2006/04/metadata">
${typesXml}
    <version>${API_VERSION}</version>
</Package>
`);

// ---------- 5. Zip it ----------
// Node has no built-in zip writer, so we call the `zip` command that ships with macOS.
// Running it with cwd = OUT puts package.xml at the ROOT of the zip (Workbench "Single Package").
execFileSync('zip', ['-r', '-q', ZIP, '.'], { cwd: OUT, stdio: 'inherit' });

console.log(`Built ${path.relative(process.cwd(), ZIP)}  (webinar owner: ${ownerUsername})`);
console.log('Contents:');
for (const [type, members] of Object.entries(manifest)) {
  console.log(`  ${type}: ${members.join(', ')}`);
}
