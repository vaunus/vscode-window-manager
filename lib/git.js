'use strict';

// The number on VSCode's Source Control icon: the changes in all git
// repositories of the window. The same sum as VSCode's git extension with
// its default settings. A file that is staged and then changed again
// counts two times, as in VSCode.
function countChanges(repositories) {
  let count = 0;
  for (const repo of repositories || []) {
    const s = repo && repo.state;
    if (!s) continue;
    for (const list of [s.mergeChanges, s.indexChanges, s.workingTreeChanges, s.untrackedChanges]) {
      if (Array.isArray(list)) count += list.length;
    }
  }
  return count;
}

const GROUPS = [
  ['merge', 'mergeChanges'],
  ['index', 'indexChanges'],
  ['tree', 'workingTreeChanges'],
  ['untracked', 'untrackedChanges'],
];

// A repository's commit and changed files as one string. A new value
// means something changed the files or the commit: an edit by any tool, a
// stage, a commit, a pull. A fetch does not change it.
function changeSignature(repo) {
  const s = repo && repo.state;
  if (!s) return '';
  const files = [];
  for (const [name, key] of GROUPS) {
    for (const c of Array.isArray(s[key]) ? s[key] : []) {
      files.push(`${name}:${c && c.status}:${c && c.uri ? c.uri.toString() : ''}`);
    }
  }
  return [(s.HEAD && s.HEAD.commit) || '', ...files.sort()].join('\n');
}

// The paths of the changed files in all repositories. Git leaves out
// ignored files, such as node_modules and build output.
function changedPaths(repositories) {
  const paths = new Set();
  for (const repo of repositories || []) {
    const s = repo && repo.state;
    if (!s) continue;
    for (const [, key] of GROUPS) {
      for (const c of Array.isArray(s[key]) ? s[key] : []) {
        if (c && c.uri && c.uri.fsPath) paths.add(c.uri.fsPath);
      }
    }
  }
  return paths;
}

module.exports = { countChanges, changeSignature, changedPaths };
