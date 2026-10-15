#!/usr/bin/env node
// greenroom setup: give a repo a studio/ folder, a playground worktree, a user service and a Tailscale Serve entry.
// Usage: node setup.mjs "<studio name>" [--owner Name] [--dir /repo] [--greenroom /path] [--port 4400]
//        [--preview-port 4322] [--serve-port 8443] [--allow login]... [--serve] [--force]
// Idempotent: existing studio files are kept unless --force; the service is always rewritten and restarted.
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { execFileSync, spawnSync } from 'node:child_process';

const args = process.argv.slice(2);
const opt = { allow: [] };
const positional = [];
for (let i = 0; i < args.length; i++) {
  const a = args[i];
  if (a === '--serve' || a === '--force') opt[a.slice(2)] = true;
  else if (a.startsWith('--')) { const k = a.slice(2).replace(/-([a-z])/g, (_, c) => c.toUpperCase()); const v = args[++i]; if (k === 'allow') opt.allow.push(v); else opt[k] = v; }
  else positional.push(a);
}
const NAME = positional[0] || opt.name;
if (!NAME) { console.error('usage: setup.mjs "<studio name>" [--owner Name] [--port N] [--preview-port N] [--serve-port N] [--allow login] [--serve]'); process.exit(2); }

const REPO = path.resolve(opt.dir || process.cwd());
const HOME = os.homedir();
const GREENROOM = path.resolve(opt.greenroom || path.join(HOME, 'personal_projects/repos/greenroom'));
const STUDIO = path.join(REPO, 'studio');
const slug = path.basename(REPO).toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-|-$/g, '');
const PORT = Number(opt.port || 4400), PREVIEW = Number(opt.previewPort || 4322), SERVE = Number(opt.servePort || 8443);
const OWNER = opt.owner || os.userInfo().username;
const PLAYGROUND = path.join(path.dirname(REPO), `${path.basename(REPO)}-playground`);
const ENV_FILE = path.join(HOME, '.config/greenroom.env');

const sh = (cmd, cwd = REPO, opts = {}) => { console.log(`  $ ${cmd}`); return execFileSync('sh', ['-c', cmd], { cwd, stdio: opts.quiet ? 'pipe' : 'inherit', encoding: 'utf8' }); };
const out = (cmd, cwd = REPO) => { try { return execFileSync('sh', ['-c', cmd], { cwd, encoding: 'utf8', stdio: 'pipe' }).trim(); } catch { return ''; } };
const readJson = (p) => { try { return JSON.parse(fs.readFileSync(p, 'utf8').replace(/^\s*\/\/.*$/gm, '').replace(/\/\*[\s\S]*?\*\//g, '')); } catch { return null; } };
const exists = (p) => fs.existsSync(path.join(REPO, p));
const writeIfMissing = (p, content) => { if (fs.existsSync(p) && !opt.force) { console.log(`  keep  ${path.relative(REPO, p)}`); return; } fs.writeFileSync(p, content); console.log(`  write ${path.relative(REPO, p)}`); };

// ---------- sanity ----------
if (!fs.existsSync(path.join(REPO, '.git'))) { console.error(`${REPO} is not a git repository`); process.exit(1); }
const existing = readJson(path.join(STUDIO, 'greenroom.config.json'));
const rerun = existing?.port === PORT && existing?.preview?.port === PREVIEW;
for (const p of [PORT, PREVIEW]) {
  const inUse = out(`ss -ltn | awk '{print $4}' | grep -E ':${p}$'`);
  if (inUse && !rerun) { console.error(`port ${p} is already in use; pass --port / --preview-port`); process.exit(1); }
}
const remote = out('git remote get-url origin');
if (!remote) { console.error('no origin remote; greenroom pushes branches and opens PRs there'); process.exit(1); }
const base = out('git symbolic-ref --short refs/remotes/origin/HEAD').replace(/^origin\//, '') || 'main';

// ---------- greenroom itself ----------
console.log(`\ngreenroom at ${GREENROOM}`);
if (!fs.existsSync(path.join(GREENROOM, 'server.mjs'))) sh(`git clone -q https://github.com/samotherguy/greenroom "${GREENROOM}"`, HOME);
else sh('git pull -q --ff-only', GREENROOM);

// ---------- what kind of project ----------
const pkg = readJson(path.join(REPO, 'package.json')) || {};
const deps = { ...(pkg.dependencies || {}), ...(pkg.devDependencies || {}) };
const wrangler = readJson(path.join(REPO, 'wrangler.jsonc')) || readJson(path.join(REPO, 'wrangler.json'));
const d1 = wrangler?.d1_databases?.[0]?.database_name || null;
// Astro: the preview gets its own Vite cache (studio/astro.preview.config.mjs) so a build in the playground never breaks it.
// Other Vite projects share the cache, so greenroom restarts the preview with a clean cache after a turn that ran the build.
const preview = deps.astro
  ? { command: 'npx astro dev --force --host 127.0.0.1 --port {port} --root . --config studio/astro.preview.config.mjs' }
  : deps.vite ? { command: 'npx vite --host 127.0.0.1 --port {port}', clearCache: 'node_modules/.vite' }
  : { command: 'npm run dev -- --host 127.0.0.1 --port {port}' };
const hasTest = Boolean(pkg.scripts?.test);
const copyFile = ['src/lib/copy.ts', 'src/content/copy.ts', 'src/copy.ts'].find(exists);
const imgDir = ['public/img', 'public/images', 'public/uploads', 'public/art'].find(exists) || 'public/img';
const tiers = {
  words: [copyFile, exists('src/content') ? 'src/content/**' : null, `${imgDir}/**`].filter(Boolean),
  content: exists('migrations') ? ['migrations/*.sql'] : [],
  design: ['src/styles/**', 'src/pages/**', 'src/components/**', 'src/layouts/**', 'src/app/**'].filter((g) => exists(g.split('/**')[0])),
};
const allowed = ['Read', 'Edit', 'Write', 'MultiEdit', 'Glob', 'Grep', 'LS', 'Bash(npm run build:*)', 'Bash(npm run build)',
  ...(hasTest ? ['Bash(npm test:*)', 'Bash(npm test)'] : []),
  ...(d1 ? ['Bash(npm run db:migrate:local)', `Bash(npx wrangler d1 migrations apply ${d1} --local:*)`, `Bash(npx wrangler d1 execute ${d1} --local:*)`] : []),
  'Bash(git status:*)', 'Bash(git diff:*)', 'Bash(git log:*)', 'Bash(ls:*)'];
const disallowed = ['Bash(git push:*)', 'Bash(git commit:*)', 'Bash(git pull:*)', 'Bash(git fetch:*)', 'Bash(git merge:*)', 'Bash(git rebase:*)', 'Bash(git stash:*)', 'Bash(git reset:*)', 'Bash(git checkout:*)', 'Bash(git clean:*)',
  ...(wrangler ? ['Bash(npx wrangler deploy:*)', 'Bash(npx wrangler secret:*)', 'Bash(npx wrangler r2:*)', 'Bash(npm run deploy:*)'] : []),
  ...(d1 ? [`Bash(npx wrangler d1 migrations apply ${d1} --remote:*)`, `Bash(npx wrangler d1 execute ${d1} --remote:*)`] : []),
  'Bash(sudo:*)', 'Bash(curl:*)', 'WebFetch', 'WebSearch', 'Agent', 'Task'];
const syncAfter = d1 ? [`npx wrangler d1 export ${d1} --remote --output .wrangler/live-snapshot.sql && rm -rf .wrangler/state/v3/d1 && npx wrangler d1 execute ${d1} --local --file .wrangler/live-snapshot.sql && npx wrangler d1 migrations apply ${d1} --local`] : [];

// ---------- studio/ ----------
console.log(`\nstudio/ in ${REPO}`);
fs.mkdirSync(STUDIO, { recursive: true });
const config = {
  _comment: `${NAME}: greenroom config. server.mjs and index.html run from ${GREENROOM}; everything project-specific is here.`,
  name: NAME, owner: OWNER,
  playground: path.relative(STUDIO, PLAYGROUND), baseBranch: base, remote: 'origin', branchPrefix: 'studio/', port: PORT,
  preview: { port: PREVIEW, ...preview, url: '/' },
  sync: { everyMinutes: 10, after: syncAfter },
  claude: { allowedTools: allowed, disallowedTools: disallowed },
  prompt: 'PROMPT.md', barePrompt: 'PROMPT.bare.md',
  ideas: ['Make the headline on the home page bigger', 'Change the accent colour to something warmer', 'Put this photo on the about page', 'Rewrite the introduction to sound warmer', 'Add a new page called…'],
  tiers,
  policy: { autoMerge: false, autoMergeTiers: ['words'] },
  upload: { dir: imgDir, maxWidth: 1600 },
  files: { allowed: 'allowed.txt', model: 'model.txt', models: 'models.json', state: 'state.json', decisions: 'decisions.jsonl' },
};
writeIfMissing(path.join(STUDIO, 'greenroom.config.json'), JSON.stringify(config, null, 2) + '\n');
if (deps.astro) writeIfMissing(path.join(STUDIO, 'astro.preview.config.mjs'), `// The studio preview runs the dev server with this config: the project's own config plus a private Vite cache,
// so \`npm run build\` inside the playground never clobbers the running preview's optimised dependencies.
import base from '../astro.config.mjs';
export default { ...base, vite: { ...(base.vite || {}), cacheDir: 'node_modules/.vite-preview' } };
`);
writeIfMissing(path.join(STUDIO, 'PROMPT.md'), fs.readFileSync(path.join(GREENROOM, 'PROMPT.md'), 'utf8'));
writeIfMissing(path.join(STUDIO, 'PROMPT.bare.md'), fs.readFileSync(path.join(GREENROOM, 'PROMPT.bare.md'), 'utf8'));
writeIfMissing(path.join(STUDIO, 'models.json'), fs.readFileSync(path.join(GREENROOM, 'example/models.json'), 'utf8'));
writeIfMissing(path.join(STUDIO, 'model.txt'), 'opus\n');
writeIfMissing(path.join(STUDIO, 'allowed.txt'), `# one Tailscale login per line, as the admin console shows it\n${opt.allow.join('\n')}\n`);
const service = `greenroom-${slug}`;
const node = process.execPath;
fs.writeFileSync(path.join(STUDIO, `${service}.service`), `[Unit]
Description=${NAME} (greenroom: chat + live preview for the site owner, tailnet only)
After=network-online.target tailscaled.service

[Service]
WorkingDirectory=${REPO}
ExecStart=${node} ${GREENROOM}/server.mjs ${STUDIO}/greenroom.config.json
Environment=PATH=${HOME}/.npm-global/bin:${HOME}/.local/bin:${path.dirname(node)}:/usr/local/bin:/usr/bin:/bin
Environment=HOME=${HOME}
EnvironmentFile=-%h/.config/greenroom.env
Restart=always
RestartSec=3

[Install]
WantedBy=default.target
`);
console.log(`  write studio/${service}.service`);
const gi = path.join(REPO, '.gitignore');
let ignore = fs.existsSync(gi) ? fs.readFileSync(gi, 'utf8') : '';
for (const line of ['studio/state.json', 'studio/decisions.jsonl', 'studio/usage.jsonl']) if (!ignore.split('\n').includes(line)) { ignore += (ignore.endsWith('\n') || !ignore ? '' : '\n') + line + '\n'; console.log(`  .gitignore += ${line}`); }
fs.writeFileSync(gi, ignore);
if (!fs.existsSync(ENV_FILE)) { fs.mkdirSync(path.dirname(ENV_FILE), { recursive: true }); fs.writeFileSync(ENV_FILE, '# keys for greenroom services: ANTHROPIC_API_KEY=..., OPENROUTER_API_KEY=..., MOONSHOT_API_KEY=...\n', { mode: 0o600 }); console.log(`  write ${ENV_FILE}`); }

// ---------- playground worktree ----------
console.log(`\nplayground at ${PLAYGROUND}`);
if (!fs.existsSync(PLAYGROUND)) {
  sh('git fetch -q origin');
  const hasBranch = out('git branch --list playground');
  sh(hasBranch ? `git worktree add "${PLAYGROUND}" playground` : `git worktree add "${PLAYGROUND}" -b playground origin/${base}`);
  for (const f of ['.dev.vars', '.env']) if (exists(f)) { fs.copyFileSync(path.join(REPO, f), path.join(PLAYGROUND, f)); console.log(`  copy ${f}`); }
  if (fs.existsSync(path.join(REPO, 'package-lock.json'))) sh('npm ci --no-audit --no-fund', PLAYGROUND);
  if (d1) sh(`npx wrangler d1 migrations apply ${d1} --local`, PLAYGROUND);
} else console.log('  exists');

// ---------- service ----------
console.log(`\nservice ${service}`);
const unitDir = path.join(HOME, '.config/systemd/user');
fs.mkdirSync(unitDir, { recursive: true });
fs.copyFileSync(path.join(STUDIO, `${service}.service`), path.join(unitDir, `${service}.service`));
sh('systemctl --user daemon-reload');
sh(`systemctl --user enable --now ${service}`);
sh(`systemctl --user restart ${service}`);
spawnSync('loginctl', ['enable-linger', os.userInfo().username], { stdio: 'ignore' });

// ---------- check ----------
const probe = (hdr) => out(`curl -s -o /dev/null -w '%{http_code}' -H 'Sec-Fetch-Dest: document' ${hdr} http://127.0.0.1:${PORT}/`);
let anon = '', ok = '';
for (let i = 0; i < 20 && ok !== '200'; i++) { spawnSync('sleep', ['0.5']); anon = probe(''); ok = probe(`-H 'Tailscale-User-Login: ${opt.allow[0] || 'nobody@example'}'`); }
console.log(`\ncheck: anonymous ${anon || 'no answer'} (want 403), allowed ${ok || 'no answer'} (want 200)`);
if (ok !== '200') { console.error(`service did not answer; see: journalctl --user -u ${service} -n 50`); process.exit(1); }

// ---------- tailscale ----------
const serveCmd = `sudo tailscale serve --bg --https=${SERVE} http://127.0.0.1:${PORT}`;
const host = out('tailscale status --json | node -e "let s=\'\';process.stdin.on(\'data\',d=>s+=d).on(\'end\',()=>{const j=JSON.parse(s);console.log((j.Self.DNSName||\'\').replace(/\\.$/,\'\'))})"');
if (opt.serve) sh(serveCmd); else console.log(`\nexpose on the tailnet (needs sudo once, persists):\n  ${serveCmd}`);
console.log(`\ndone. studio: https://${host || '<machine>.<tailnet>.ts.net'}:${SERVE}
next: fill the map in studio/PROMPT.bare.md, check tiers in studio/greenroom.config.json,
      add the person's Tailscale login to studio/allowed.txt, commit studio/ and .gitignore.`);
