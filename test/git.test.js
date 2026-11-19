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
