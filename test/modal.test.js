'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');

const { isModalOpen } = require('../lib/modal');

const file = (label, active = false) => ({ label, known: true, active });
const page = (label, active = false) => ({ label, known: false, active });

test('no modal with one group', () => {
  assert.equal(isModalOpen([{ viewColumn: 1, tabs: [page('Settings', true)] }]), false);
  assert.equal(isModalOpen([]), false);
  assert.equal(isModalOpen(undefined), false);
});

test('modal: a last group with an internal page', () => {
  const groups = [
    { viewColumn: 1, tabs: [file('a.js', true), file('b.js')] },
    { viewColumn: 2, tabs: [page('Settings', true)] },
  ];
  assert.equal(isModalOpen(groups), true);
});

test('modal: the last group is found by view column, not list order', () => {
  const groups = [
    { viewColumn: 2, tabs: [page('Keyboard Shortcuts', true)] },
    { viewColumn: 1, tabs: [file('a.js', true)] },
  ];
  assert.equal(isModalOpen(groups), true);
});

test('no modal: a split shows a file', () => {
  const groups = [
    { viewColumn: 1, tabs: [file('a.js', true)] },
    { viewColumn: 2, tabs: [file('a.js', true)] },
  ];
  assert.equal(isModalOpen(groups), false);
});

test('no modal: a split copies a page, so another group has it', () => {
  const groups = [
    { viewColumn: 1, tabs: [page('Settings', true)] },
    { viewColumn: 2, tabs: [page('Settings', true)] },
  ];
  assert.equal(isModalOpen(groups), false);
});

test('no modal: the internal page is not the active tab of the last group', () => {
  const groups = [
    { viewColumn: 1, tabs: [file('a.js', true)] },
    { viewColumn: 2, tabs: [page('Settings'), file('b.js', true)] },
  ];
  assert.equal(isModalOpen(groups), false);
});

test('no modal: an empty last group', () => {
  const groups = [
    { viewColumn: 1, tabs: [file('a.js', true)] },
    { viewColumn: 2, tabs: [] },
  ];
  assert.equal(isModalOpen(groups), false);
});
