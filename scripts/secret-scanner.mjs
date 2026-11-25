import fs from 'node:fs';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath, pathToFileURL } from 'node:url';

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const MAX_SCAN_BYTES = 2 * 1024 * 1024;
const BINARY_EXTENSIONS = new Set(['.png','.jpg','.jpeg','.gif','.webp','.ico','.pdf','.zip','.7z','.mp4','.mov','.woff','.woff2','.ttf','.exe','.dll','.node','.tgz','.gz','.res']);
const rules = [
  { kind: 'private-key', regex: /-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----/g },
  { kind: 'openai-key', regex: /\bsk-(?:proj-)?[A-Za-z0-9_-]{20,}\b/g },
  { kind: 'github-token', regex: /\b(?:gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,})\b/g },
  { kind: 'aws-access-key', regex: /\bAKIA[0-9A-Z]{16}\b/g },
  { kind: 'google-api-key', regex: /\bAIza[0-9A-Za-z_-]{35}\b/g },
  { kind: 'slack-token', regex: /\bxox[baprs]-[A-Za-z0-9-]{20,}\b/g },
  { kind: 'jwt', regex: /\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\b/g },
  { kind: 'tunnel-id', regex: /\btunnel_(?:[a-z0-9]{4}_)?[a-z0-9]{32}\b/g },
  { kind: 'personal-path', regex: /(?:[A-Za-z]:\\Users\\[A-Za-z0-9 ._-]+|D:\\(?:DeskPilot|DesktopCommander)\\[^\s"'<>|]+)/gi },
];

function placeholder(value) {
  return /dummy|synthetic|test|example|changeme|change-me|placeholder|sentinel|outside|text-of|only the|your[-_ ]|env:|\$\{|<[^>]+>/i.test(value);
}

export function scanText(text) {
  const findings = [];
  for (const rule of rules) {
    rule.regex.lastIndex = 0;
    for (const match of text.matchAll(rule.regex)) {
      if (rule.kind === 'personal-path' && /\\Users\\(?:test|someone|alice|me|user|example|o'brien|john smith|\[)/i.test(match[0])) continue;
      const before = text.slice(0, match.index);
      const line = before.split('\n').length;
      findings.push({ kind: rule.kind, line, preview: `${match[0].slice(0, 8)}…` });
    }
  }
  const generic = /\b(api[_-]?key|access[_-]?token|refresh[_-]?token|client[_-]?secret|password|secret)\b\s*[:=]\s*["']([^"'\r\n]{8,})["']/gi;
  for (const match of text.matchAll(generic)) {
    if (placeholder(match[2])) continue;
    const before = text.slice(0, match.index);
    findings.push({ kind: 'generic-secret', line: before.split('\n').length, preview: `${match[2].slice(0, 8)}…` });
  }
  return findings;
}

function git(args, options = {}) {
  const result = spawnSync('git', args, { cwd: ROOT, encoding: 'utf8', maxBuffer: 256 * 1024 * 1024, ...options });
  if (result.status !== 0) throw new Error(result.stderr || `git ${args.join(' ')} failed`);
  return result.stdout;
}

function scannable(file, size) {
  return size <= MAX_SCAN_BYTES && !BINARY_EXTENSIONS.has(path.extname(file).toLowerCase());
}

export function scanWorktree() {
  const files = git(['ls-files', '-co', '--exclude-standard', '-z']).split('\0').filter(Boolean);
  const findings = [];
  let scanned = 0;
  for (const file of files) {
    const absolute = path.join(ROOT, file);
    let stat;
    try { stat = fs.statSync(absolute); } catch { continue; }
    if (!stat.isFile() || !scannable(file, stat.size)) continue;
    const bytes = fs.readFileSync(absolute);
    if (bytes.includes(0)) continue;
    scanned++;
    for (const finding of scanText(bytes.toString('utf8'))) findings.push({ file, ...finding });
  }
  return { findings, scanned };
}

export function scanHistory(revisions = ['--all']) {
  const objects = git(['rev-list', '--objects', ...revisions]).split('\n').filter(Boolean).map((line) => {
    const split = line.indexOf(' ');
    return { sha: line.slice(0, split), file: split < 0 ? line : line.slice(split + 1) };
  });
  const unique = new Map();
  for (const object of objects) if (!unique.has(object.sha)) unique.set(object.sha, object.file);
  const shas = [...unique.keys()];
  const checks = git(['cat-file', '--batch-check=%(objectname) %(objecttype) %(objectsize)'], { input: `${shas.join('\n')}\n` });
  const selected = [];
  const paths = new Map();
  for (const line of checks.split('\n')) {
    const [sha, type, sizeText] = line.split(' ');
    if (type !== 'blob') continue;
    const size = Number(sizeText);
    const file = unique.get(sha);
    if (scannable(file, size)) { selected.push(sha); paths.set(sha, file); }
  }
  const batch = spawnSync('git', ['cat-file', '--batch'], { cwd: ROOT, input: Buffer.from(`${selected.join('\n')}\n`), maxBuffer: 256 * 1024 * 1024 });
  if (batch.status !== 0) throw new Error(batch.stderr?.toString() || 'git cat-file --batch failed');
  const output = batch.stdout;
  const findings = [];
  let offset = 0;
  while (offset < output.length) {
    const headerEnd = output.indexOf(10, offset);
    if (headerEnd < 0) throw new Error('Truncated git cat-file header');
    const [sha, type, sizeText] = output.subarray(offset, headerEnd).toString('utf8').split(' ');
    const size = Number(sizeText);
    const start = headerEnd + 1;
    if (type !== 'blob' || !Number.isSafeInteger(size)) throw new Error(`Unexpected git cat-file record: ${sha} ${type} ${sizeText}`);
    const content = output.subarray(start, start + size);
    offset = start + size + 1;
    if (content.includes(0)) continue;
    for (const finding of scanText(content.toString('utf8'))) findings.push({ file: paths.get(sha), ...finding });
  }
  return { findings, scanned: selected.length };
}

function main() {
  const history = process.argv.includes('--history');
  const refIndex = process.argv.indexOf('--history-ref');
  const historyRef = refIndex >= 0 ? process.argv[refIndex + 1] : undefined;
  if (refIndex >= 0 && !historyRef) throw new Error('--history-ref requires a Git revision');
  const worktree = process.argv.includes('--worktree') || (!history && !historyRef);
  const reports = [];
  if (worktree) reports.push(['worktree', scanWorktree()]);
  if (history) reports.push(['history', scanHistory()]);
  if (historyRef) reports.push([`history ${historyRef}`, scanHistory([historyRef])]);
  let count = 0;
  for (const [scope, report] of reports) {
    console.log(`Scanned ${report.scanned} ${scope} text blobs`);
    for (const finding of report.findings) {
      count++;
      console.error(`${finding.file}:${finding.line}: ${finding.kind} ${finding.preview}`);
    }
  }
  if (count) {
    console.error(`Secret scan found ${count} potential finding(s)`);
    process.exitCode = 1;
  } else {
    console.log('Secret scan passed');
  }
}

if (process.argv[1] && pathToFileURL(path.resolve(process.argv[1])).href === import.meta.url) main();
