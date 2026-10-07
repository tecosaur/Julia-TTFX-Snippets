// Helpers for the task workflows. The publish job runs these over results
// from the build job, which runs submitted code, so nothing it produces is
// trusted: paths, files, and numbers are all checked before use.

const fs = require('fs');
const path = require('path');

const TASK_FILES = ['Project.toml', 'task.jl'];
const MAX_TASK_FILE_BYTES = 1024 * 1024;
const MAX_LOG_CHARS = 60000; // GitHub comments are capped at 65536 characters
const TIMING_KEYS = ['install', 'using', 'script', 'total'];
const REGISTRY_URL = 'https://raw.githubusercontent.com/JuliaRegistries/General/master';

class InvalidResult extends Error {
  constructor(subject, reason) {
    super(`Rejected build result: ${subject} ${reason}`);
    this.name = 'InvalidResult';
    this.subject = subject;
    this.reason = reason;
  }
}

/**
 * Parse an issue form body into `{field: value}`, keyed by section label
 * (e.g. "Dependencies (optional)" → `dependencies`). Values are trimmed
 * whole, so fenced code keeps its indentation; "_No response_" becomes "".
 */
function parseIssueForm(body) {
  const sections = {};
  let key = null, infence = false;
  for (const line of body.replace(/\r\n/g, '\n').split('\n')) {
    if (line.startsWith('```')) infence = !infence;
    if (!infence && line.startsWith('### ')) {
      key = line.slice(4).replace(/\(optional\)/i, '').trim().toLowerCase().replace(/\s+/g, '_');
      sections[key] = [];
    } else if (key) {
      sections[key].push(line);
    }
  }
  return Object.fromEntries(Object.entries(sections).map(([key, lines]) => {
    const value = lines.join('\n').trim();
    return [key, value === '_No response_' ? '' : value];
  }));
}

/** The `@login` from a task script's `# Author:` header line, or null. */
function taskAuthor(script) {
  for (const line of script.split('\n')) {
    if (line.trim() === '') break;
    const author = line.match(/^# Author: @(\S+)/);
    if (author) return author[1];
  }
  return null;
}

/**
 * Check the staged build result and copy the task into the workspace.
 *
 * - `stagedDir`: directory holding exactly the task files
 * - `taskDir`: claimed relative task path, which must belong to `pkg`
 * - `timings`: claimed timings in seconds, keyed by `TIMING_KEYS`
 *
 * Returns `{nature, authorship, timings}`, where authorship is relative to
 * `submitter`: "self", "other", or "none" for a new task.
 * Throws `InvalidResult` for anything malformed.
 */
function prepareTask({ stagedDir, workspace, taskDir, pkg, submitter, timings }) {
  checkTaskDir(taskDir, pkg);
  const staged = fs.readdirSync(stagedDir).sort();
  if (staged.join() !== TASK_FILES.join())
    throw new InvalidResult('task files', `are [${staged}], expected [${TASK_FILES}]`);
  for (const file of TASK_FILES) {
    const stat = fs.lstatSync(path.join(stagedDir, file));
    if (!stat.isFile()) throw new InvalidResult(file, 'is not a regular file');
    if (stat.size > MAX_TASK_FILE_BYTES) throw new InvalidResult(file, `is too large (${stat.size} bytes)`);
  }
  const seconds = Object.fromEntries(TIMING_KEYS.map(key => {
    const value = Number(timings[key]);
    if (timings[key] === '' || !Number.isFinite(value) || value < 0)
      throw new InvalidResult(`${key} timing`, `is not a non-negative number: ${JSON.stringify(timings[key])}`);
    return [key, value];
  }));
  const dest = path.join(workspace, taskDir);
  const existing = path.join(dest, 'task.jl');
  const isUpdate = fs.existsSync(existing);
  const previousAuthor = isUpdate ? taskAuthor(fs.readFileSync(existing, 'utf8')) : null;
  fs.rmSync(dest, { recursive: true, force: true });
  fs.mkdirSync(dest, { recursive: true });
  for (const file of TASK_FILES) fs.copyFileSync(path.join(stagedDir, file), path.join(dest, file));
  return {
    nature: isUpdate ? 'Task update' : 'New task',
    authorship: !isUpdate ? 'none' : previousAuthor === submitter ? 'self' : 'other',
    timings: seconds,
  };
}

function checkTaskDir(taskDir, pkg) {
  if (!/^[A-Za-z][A-Za-z0-9_]*$/.test(pkg))
    throw new InvalidResult('package name', `is not a valid Julia package name: ${JSON.stringify(pkg)}`);
  const parts = String(taskDir).match(/^tasks\/([A-Z])\/([^/]+)\/([A-Za-z0-9_-]+)$/);
  if (!parts || parts[1] !== pkg[0].toUpperCase() || parts[2] !== pkg)
    throw new InvalidResult('task directory', `${JSON.stringify(taskDir)} is not a task directory for ${pkg}`);
}

/**
 * The GitHub `{owner, repo}` of a package in the General registry, or null
 * when it isn't registered there or isn't hosted on GitHub.
 */
async function registryRepo(pkg, fetchFn = fetch) {
  const dir = pkg.endsWith('_jll') ? `jll/${pkg[0].toUpperCase()}` : pkg[0].toUpperCase();
  const response = await fetchFn(`${REGISTRY_URL}/${dir}/${pkg}/Package.toml`);
  if (response.status === 404) return null;
  if (!response.ok) throw new Error(`Fetching registry entry for ${pkg} failed: HTTP ${response.status}`);
  const repo = (await response.text()).match(/^repo\s*=\s*"https:\/\/github\.com\/([^/"]+)\/([^/"]+?)(?:\.git)?"/m);
  return repo && { owner: repo[1], repo: repo[2] };
}

/**
 * Why `submitter`'s task can be merged without review, or null. Checked in
 * order: task author, package owner, member of the package's org, JuliaLang
 * member. `isPublicMember(org)` must resolve false for non-org accounts.
 */
async function automergeReason({ authorship, submitter, pkgOwner, isPublicMember }) {
  if (authorship === 'self') return 'the author of the task';
  if (pkgOwner && submitter === pkgOwner) return 'the owner of the target package';
  if (pkgOwner && await isPublicMember(pkgOwner))
    return `a public member of ${pkgOwner}, which owns the target package`;
  if (await isPublicMember('JuliaLang')) return 'a public member of the JuliaLang organisation';
  return null;
}

/**
 * `text` as a Markdown code block that it can't break out of, keeping the
 * end (where errors are) when it's too long for a comment.
 */
function fencedLog(text, maxChars = MAX_LOG_CHARS) {
  const tail = text.length > maxChars ? '[…earlier output truncated…]\n' + text.slice(-maxChars) : text;
  const longestRun = Math.max(0, ...(tail.match(/`+/g) || []).map(run => run.length));
  const fence = '`'.repeat(Math.max(3, longestRun + 1));
  return `${fence}\n${tail}\n${fence}`;
}

module.exports = {
  InvalidResult, parseIssueForm, taskAuthor, prepareTask, registryRepo, automergeReason, fencedLog,
};
