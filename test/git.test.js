'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');

const { countChanges } = require('../lib/git');

const repo = (merge, index, workingTree, untracked) => ({
  state: {
    mergeChanges: Array(merge).fill({}),
    indexChanges: Array(index).fill({}),
    workingTreeChanges: Array(workingTree).fill({}),
    untrackedChanges: Array(untracked).fill({}),
  },
});

test('no repositories: 0', () => {
  assert.equal(countChanges([]), 0);
  assert.equal(countChanges(undefined), 0);
});

test('a clean repository: 0', () => {
  assert.equal(countChanges([repo(0, 0, 0, 0)]), 0);
});

test('all change groups count', () => {
  assert.equal(countChanges([repo(1, 2, 3, 4)]), 10);
});

test('the changes of all repositories add up', () => {
  assert.equal(countChanges([repo(0, 1, 2, 0), repo(0, 0, 1, 1)]), 5);
});

test('a missing group or state does not count', () => {
  assert.equal(countChanges([{ state: { workingTreeChanges: [{}, {}] } }, {}, null]), 2);
});

const { changeSignature, changedPaths } = require('../lib/git');

const uri = (p) => ({ fsPath: p, toString: () => `file://${p}` });
const gitRepo = (commit, groups) => ({ state: { HEAD: { commit }, ...groups } });

test('signature: the same files in another order give the same value', () => {
  const a = gitRepo('c1', { workingTreeChanges: [{ status: 5, uri: uri('/r/a') }, { status: 5, uri: uri('/r/b') }] });
  const b = gitRepo('c1', { workingTreeChanges: [{ status: 5, uri: uri('/r/b') }, { status: 5, uri: uri('/r/a') }] });
  assert.equal(changeSignature(a), changeSignature(b));
});

test('signature: a new changed file, a staged file or a new commit changes it', () => {
  const base = gitRepo('c1', { workingTreeChanges: [{ status: 5, uri: uri('/r/a') }] });
  const more = gitRepo('c1', { workingTreeChanges: [{ status: 5, uri: uri('/r/a') }, { status: 7, uri: uri('/r/b') }] });
  const staged = gitRepo('c1', { indexChanges: [{ status: 0, uri: uri('/r/a') }] });
  const commit = gitRepo('c2', { workingTreeChanges: [{ status: 5, uri: uri('/r/a') }] });
  for (const other of [more, staged, commit]) assert.notEqual(changeSignature(base), changeSignature(other));
});

test('signature: a missing repository or state gives an empty value', () => {
  assert.equal(changeSignature(null), '');
  assert.equal(changeSignature({}), '');
});

test('changed paths: all groups of all repositories, no duplicates', () => {
  const r1 = gitRepo('c', { indexChanges: [{ uri: uri('/r/a') }], workingTreeChanges: [{ uri: uri('/r/a') }] });
  const r2 = gitRepo('c', { untrackedChanges: [{ uri: uri('/s/new') }], mergeChanges: [{ uri: uri('/s/m') }] });
  assert.deepEqual([...changedPaths([r1, r2, null])].sort(), ['/r/a', '/s/m', '/s/new']);
});
