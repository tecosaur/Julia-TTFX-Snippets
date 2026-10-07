// Run with `node --test .github/scripts/ttfx.test.js`

const assert = require('assert');
const fs = require('fs');
const os = require('os');
const path = require('path');
const { test } = require('node:test');
const ttfx = require('./ttfx.js');

const CODE = '```julia\nfunction f()\n    a = 1\n\n\n    ### not a heading\n    a\nend\n```';

test('parseIssueForm keeps code intact and normalises fields', () => {
  const body = [
    '### Primary package', '', '  Ferrite  ', '',
    '### Dependencies (optional)', '', '_No response_', '',
    '### Task code', '', CODE, ''].join('\r\n');
  assert.deepStrictEqual(ttfx.parseIssueForm(body),
    { primary_package: 'Ferrite', dependencies: '', task_code: CODE });
});

test('taskAuthor reads the header only', () => {
  assert.strictEqual(ttfx.taskAuthor('# Task: X\n# Author: @someone\n\ncode'), 'someone');
  assert.strictEqual(ttfx.taskAuthor('# Task: X\n# Author: Someone\n'), null);
  assert.strictEqual(ttfx.taskAuthor('# Task: X\n\n# Author: @late\n'), null);
});

function withTask(fn) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'ttfx-test-'));
  const stagedDir = path.join(root, 'staged'), workspace = path.join(root, 'workspace');
  fs.mkdirSync(stagedDir);
  fs.mkdirSync(workspace);
  fs.writeFileSync(path.join(stagedDir, 'task.jl'), '# Task: T\n# Author: @me\n\ncode\n');
  fs.writeFileSync(path.join(stagedDir, 'Project.toml'), '[deps]\n');
  const args = {
    stagedDir, workspace, taskDir: 'tasks/F/Foo/Some-Task', pkg: 'Foo', submitter: 'me',
    timings: { install: '1.5', using: '0.2', script: '0.1', total: '0.3' },
  };
  try { fn(args); } finally { fs.rmSync(root, { recursive: true, force: true }); }
}

test('prepareTask copies a valid new task', () => withTask(args => {
  const result = ttfx.prepareTask(args);
  assert.deepStrictEqual(result, {
    nature: 'New task', authorship: 'none',
    timings: { install: 1.5, using: 0.2, script: 0.1, total: 0.3 },
  });
  const dest = path.join(args.workspace, args.taskDir);
  assert.deepStrictEqual(fs.readdirSync(dest).sort(), ['Project.toml', 'task.jl']);
}));

test('prepareTask identifies updates by authorship', () => withTask(args => {
  const dest = path.join(args.workspace, args.taskDir);
  fs.mkdirSync(dest, { recursive: true });
  fs.writeFileSync(path.join(dest, 'task.jl'), '# Task: T\n# Author: @me\n');
  fs.writeFileSync(path.join(dest, 'stale.txt'), '');
  assert.strictEqual(ttfx.prepareTask(args).authorship, 'self');
  assert.ok(!fs.existsSync(path.join(dest, 'stale.txt')));
  fs.writeFileSync(path.join(dest, 'task.jl'), '# Task: T\n# Author: @someone-else\n');
  assert.deepStrictEqual(
    (({ nature, authorship }) => ({ nature, authorship }))(ttfx.prepareTask(args)),
    { nature: 'Task update', authorship: 'other' });
}));

test('prepareTask rejects task directories outside the package', () => withTask(args => {
  for (const taskDir of ['tasks/F/Foo/../../../etc', 'tasks/B/Bar/T', 'tasks/f/Foo/T', '/tasks/F/Foo/T',
                         'tasks/F/Foo/T/extra', 'tasks/F/Foo/.', 'tasks/F/Foo/', '']) {
    assert.throws(() => ttfx.prepareTask({ ...args, taskDir }), ttfx.InvalidResult, taskDir);
  }
  assert.throws(() => ttfx.prepareTask({ ...args, pkg: '../Foo' }), ttfx.InvalidResult);
}));

test('prepareTask rejects unexpected staged files', () => withTask(args => {
  fs.writeFileSync(path.join(args.stagedDir, 'extra.jl'), '');
  assert.throws(() => ttfx.prepareTask(args), /task files/);
}));

test('prepareTask rejects symlinks and oversized files', () => withTask(args => {
  const project = path.join(args.stagedDir, 'Project.toml');
  fs.rmSync(project);
  fs.symlinkSync('/etc/hostname', project);
  assert.throws(() => ttfx.prepareTask(args), /not a regular file/);
  fs.rmSync(project);
  fs.writeFileSync(project, 'x'.repeat(2 * 1024 * 1024));
  assert.throws(() => ttfx.prepareTask(args), /too large/);
}));

test('prepareTask rejects malformed timings', () => withTask(args => {
  for (const bad of ['', 'NaN', '-1', 'Infinity', '1; rm -rf /', undefined]) {
    assert.throws(() => ttfx.prepareTask({ ...args, timings: { ...args.timings, total: bad } }),
                  /total timing/, String(bad));
  }
  assert.ok(!fs.existsSync(path.join(args.workspace, 'tasks')), 'nothing copied on rejection');
}));

function fakeFetch(responses) {
  return async url => {
    const [status, text] = responses[url] ?? [404, ''];
    return { status, ok: status < 400, text: async () => text };
  };
}

test('registryRepo reads GitHub repos from General', async () => {
  const base = 'https://raw.githubusercontent.com/JuliaRegistries/General/master';
  const fetchFn = fakeFetch({
    [`${base}/F/Ferrite/Package.toml`]: [200, 'name = "Ferrite"\nrepo = "https://github.com/Ferrite-FEM/Ferrite.jl.git"\n'],
    [`${base}/G/GitLabbed/Package.toml`]: [200, 'repo = "https://gitlab.com/someone/GitLabbed.jl.git"\n'],
    [`${base}/jll/Z/Zlib_jll/Package.toml`]: [200, 'repo = "https://github.com/JuliaBinaryWrappers/Zlib_jll.jl.git"\n'],
    [`${base}/B/Broken/Package.toml`]: [500, ''],
  });
  assert.deepStrictEqual(await ttfx.registryRepo('Ferrite', fetchFn), { owner: 'Ferrite-FEM', repo: 'Ferrite.jl' });
  assert.deepStrictEqual(await ttfx.registryRepo('Zlib_jll', fetchFn), { owner: 'JuliaBinaryWrappers', repo: 'Zlib_jll.jl' });
  assert.strictEqual(await ttfx.registryRepo('GitLabbed', fetchFn), null);
  assert.strictEqual(await ttfx.registryRepo('Unregistered', fetchFn), null);
  await assert.rejects(ttfx.registryRepo('Broken', fetchFn), /HTTP 500/);
});

test('automergeReason checks trust in order', async () => {
  const members = { 'Ferrite-FEM': ['fem-dev'], JuliaLang: ['core-dev', 'fem-dev'] };
  const reason = (authorship, submitter, pkgOwner) => ttfx.automergeReason({
    authorship, submitter, pkgOwner,
    isPublicMember: async org => (members[org] ?? []).includes(submitter),
  });
  assert.match(await reason('self', 'anyone', null), /author of the task/);
  assert.match(await reason('none', 'solo', 'solo'), /owner of the target package/);
  assert.match(await reason('other', 'fem-dev', 'Ferrite-FEM'), /member of Ferrite-FEM/);
  assert.match(await reason('none', 'core-dev', 'Ferrite-FEM'), /JuliaLang/);
  assert.match(await reason('none', 'core-dev', null), /JuliaLang/);
  assert.strictEqual(await reason('other', 'stranger', 'Ferrite-FEM'), null);
});

test('fencedLog cannot be escaped and keeps the end', () => {
  const fenced = ttfx.fencedLog('a\n```\n@everyone\n````x');
  assert.ok(fenced.startsWith('`````\n') && fenced.endsWith('\n`````'));
  const long = ttfx.fencedLog('x'.repeat(100) + 'ERROR at the end', 50);
  assert.match(long, /truncated[\s\S]*ERROR at the end/);
  assert.ok(long.length < 120);
});
