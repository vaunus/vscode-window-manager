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

module.exports = { countChanges };
