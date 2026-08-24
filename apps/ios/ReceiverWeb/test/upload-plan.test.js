import assert from 'node:assert/strict';
import test from 'node:test';
import { buildUploadPlan, canResumeImport } from '../src/upload-plan.js';

function item(name, contents) {
  return { file: new Blob([contents]), path: name };
}

test('buildUploadPlan sends only bytes after each server-confirmed offset', async () => {
  const selection = [item('one.m4b', '0123456789'), item('two.mp3', 'abc')];
  const plan = buildUploadPlan(selection, [4, 0]);

  assert.deepEqual(plan.map(({ index, offset }) => ({ index, offset })), [
    { index: 0, offset: 4 },
    { index: 1, offset: 0 },
  ]);
  assert.equal(await plan[0].body.text(), '456789');
  assert.equal(await plan[1].body.text(), 'abc');
});

test('buildUploadPlan skips files already confirmed in full', () => {
  const selection = [item('done.m4b', 'complete'), item('next.mp3', 'next')];
  const plan = buildUploadPlan(selection, [8, 2]);

  assert.equal(plan.length, 1);
  assert.equal(plan[0].index, 1);
  assert.equal(plan[0].offset, 2);
});

test('buildUploadPlan rejects corrupt or impossible offsets', () => {
  const selection = [item('book.m4b', '1234')];
  assert.throws(() => buildUploadPlan(selection, [5]), /invalid resume point/);
  assert.throws(() => buildUploadPlan(selection, [-1]), /invalid resume point/);
  assert.throws(() => buildUploadPlan(selection, [1.5]), /invalid resume point/);
});

test('canResumeImport requires a receiving session with one offset per file', () => {
  const selection = [item('book.m4b', '1234')];
  assert.equal(canResumeImport({ state: 'receiving', fileOffsets: [2] }, selection), true);
  assert.equal(canResumeImport({ state: 'importing', fileOffsets: [4] }, selection), false);
  assert.equal(canResumeImport({ state: 'receiving', fileOffsets: [] }, selection), false);
  assert.equal(canResumeImport({ state: 'receiving', fileOffsets: [5] }, selection), false);
  assert.equal(canResumeImport({ state: 'receiving', fileOffsets: [1.5] }, selection), false);
});
