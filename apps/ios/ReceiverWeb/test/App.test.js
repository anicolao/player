import { fireEvent, render, screen, waitFor } from '@testing-library/svelte';
import { afterEach, beforeEach, describe, expect, test, vi } from 'vitest';
import App from '../src/App.svelte';

function jsonResponse(status, payload) {
  return {
    ok: status >= 200 && status < 300,
    status,
    json: async () => payload,
  };
}

function blobText(blob) {
  return new Promise((resolve, reject) => {
    const reader = new FileReader();
    reader.onload = () => resolve(reader.result);
    reader.onerror = () => reject(reader.error);
    reader.readAsText(blob);
  });
}

async function connect(fetchImplementation = async () => jsonResponse(200, {
  token: 'browser-token',
  deviceName: 'Test iPhone',
})) {
  globalThis.fetch = vi.fn(fetchImplementation);
  render(App);
  const input = screen.getByLabelText('Six-digit pairing code');
  await fireEvent.input(input, { target: { value: '48a27-31' } });
  expect(input.value).toBe('482731');
  await fireEvent.keyDown(input, { key: 'Enter' });
  await screen.findByText('✓ Connected to Test iPhone');
}

class ScriptedXMLHttpRequest {
  static scripts = [];
  static requests = [];

  headers = {};
  status = 0;
  responseText = '';

  open(method, path) {
    this.method = method;
    this.path = path;
  }

  setRequestHeader(field, value) {
    this.headers[field] = value;
  }

  send(body) {
    this.body = body;
    ScriptedXMLHttpRequest.requests.push(this);
    const script = ScriptedXMLHttpRequest.scripts.shift() ?? { outcome: 'success' };
    if (script.outcome === 'pending') return;
    queueMicrotask(() => {
      if (script.outcome === 'error') this.onerror?.();
      else {
        this.status = script.status ?? 200;
        this.responseText = JSON.stringify(script.payload ?? {});
        this.onload?.();
      }
    });
  }

  abort() {
    this.onabort?.();
  }
}

describe('receiver browser', () => {
  beforeEach(() => {
    ScriptedXMLHttpRequest.scripts = [];
    ScriptedXMLHttpRequest.requests = [];
    globalThis.XMLHttpRequest = ScriptedXMLHttpRequest;
  });

  afterEach(() => {
    vi.restoreAllMocks();
  });

  test('pairs from the keyboard and reports a rejected code without leaving pairing', async () => {
    globalThis.fetch = vi.fn()
      .mockResolvedValueOnce(jsonResponse(401, { message: 'That code did not match.' }))
      .mockResolvedValueOnce(jsonResponse(200, {
        token: 'browser-token',
        deviceName: 'Test iPhone',
      }));
    render(App);
    const input = screen.getByLabelText('Six-digit pairing code');
    await fireEvent.input(input, { target: { value: '482731' } });
    await fireEvent.keyDown(input, { key: 'Enter' });
    expect((await screen.findByRole('alert')).textContent).toContain('That code did not match.');
    await fireEvent.click(screen.getByRole('button', { name: 'Connect' }));
    await screen.findByText('✓ Connected to Test iPhone');
  });

  test('opens the file picker when the drop target receives Enter or Space', async () => {
    await connect();
    const nativeClick = vi.spyOn(HTMLInputElement.prototype, 'click').mockImplementation(() => {});
    const dropTarget = screen.getByRole('button', { name: 'Drop books or folders here' });

    await fireEvent.keyDown(dropTarget, { key: 'Enter' });
    await fireEvent.keyDown(dropTarget, { key: ' ' });

    expect(nativeClick).toHaveBeenCalledTimes(2);
  });

  test('uploads a file, follows importing, and presents a needs-review completion', async () => {
    const statuses = [
      { state: 'receiving', fileOffsets: [0], completedBytes: 0, totalBytes: 6 },
      { state: 'receiving', fileOffsets: [6], completedBytes: 6, totalBytes: 6 },
      { state: 'importing', fileOffsets: [6], completedBytes: 6, totalBytes: 6,
        message: 'Bookshelf is checking your files…' },
      { state: 'needsReview', fileOffsets: [6], completedBytes: 6, totalBytes: 6,
        message: 'Open Inbox to review this import.' },
    ];
    await connect(async (path, options = {}) => {
      if (path === '/api/pair') return jsonResponse(200, { token: 'browser-token', deviceName: 'Test iPhone' });
      if (path === '/api/imports' && options.method === 'POST') return jsonResponse(201, { id: 'import-1' });
      if (path.endsWith('/complete')) return jsonResponse(202, { state: 'importing' });
      if (path === '/api/imports/import-1') return jsonResponse(200, statuses.shift());
      throw new Error(`Unexpected request: ${options.method ?? 'GET'} ${path}`);
    });
    ScriptedXMLHttpRequest.scripts.push({ outcome: 'success' });
    const file = new File(['abcdef'], 'Novel.m4b', { type: 'audio/mp4' });

    await fireEvent.change(screen.getByLabelText('Choose Files'), { target: { files: [file] } });

    expect(await screen.findByRole('heading', { name: 'Sent to Bookshelf' })).toBeTruthy();
    expect(screen.getByText('Open Inbox to review this import.')).toBeTruthy();
    expect(ScriptedXMLHttpRequest.requests[0].headers['X-Player-Upload-Offset']).toBe('0');
    await fireEvent.click(screen.getByRole('button', { name: 'Send another book' }));
    expect(screen.getByRole('heading', { name: 'Send audiobooks to Bookshelf' })).toBeTruthy();
  });

  test('retries only from server-confirmed bytes and can cancel a partial request', async () => {
    let statusIndex = 0;
    const statuses = [
      { state: 'receiving', fileOffsets: [0], completedBytes: 0, totalBytes: 10 },
      { state: 'receiving', fileOffsets: [4], completedBytes: 4, totalBytes: 10 },
      { state: 'receiving', fileOffsets: [4], completedBytes: 4, totalBytes: 10 },
      { state: 'receiving', fileOffsets: [10], completedBytes: 10, totalBytes: 10 },
      { state: 'completed', fileOffsets: [10], completedBytes: 10, totalBytes: 10,
        message: 'Novel added' },
    ];
    const deleted = [];
    await connect(async (path, options = {}) => {
      if (path === '/api/pair') return jsonResponse(200, { token: 'browser-token', deviceName: 'Test iPhone' });
      if (path === '/api/imports' && options.method === 'POST') return jsonResponse(201, { id: 'import-2' });
      if (options.method === 'DELETE') {
        deleted.push(path);
        return jsonResponse(200, { state: 'cancelled' });
      }
      if (path.endsWith('/complete')) return jsonResponse(202, { state: 'importing' });
      if (path === '/api/imports/import-2') return jsonResponse(200, statuses[statusIndex++]);
      throw new Error(`Unexpected request: ${options.method ?? 'GET'} ${path}`);
    });
    ScriptedXMLHttpRequest.scripts.push({ outcome: 'error' }, { outcome: 'success' });
    const file = new File(['0123456789'], 'Novel.m4b', { type: 'audio/mp4' });
    await fireEvent.change(screen.getByLabelText('Choose Files'), { target: { files: [file] } });
    const retry = await screen.findByRole('button', { name: 'Retry transfer' });

    await fireEvent.click(retry);

    expect(await screen.findByText('Novel added')).toBeTruthy();
    expect(ScriptedXMLHttpRequest.requests[1].headers['X-Player-Upload-Offset']).toBe('4');
    expect(await blobText(ScriptedXMLHttpRequest.requests[1].body)).toBe('456789');
    expect(deleted).toEqual([]);

    await fireEvent.click(screen.getByRole('button', { name: 'Send another book' }));
    statusIndex = 0;
    statuses.splice(0, statuses.length,
      { state: 'receiving', fileOffsets: [0], completedBytes: 0, totalBytes: 10 });
    globalThis.fetch.mockImplementation(async (path, options = {}) => {
      if (path === '/api/imports' && options.method === 'POST') return jsonResponse(201, { id: 'import-3' });
      if (path === '/api/imports/import-3' && options.method === 'DELETE') {
        deleted.push(path);
        return jsonResponse(200, { state: 'cancelled' });
      }
      if (path === '/api/imports/import-3') return jsonResponse(200, statuses[statusIndex++]);
      throw new Error(`Unexpected request: ${options.method ?? 'GET'} ${path}`);
    });
    ScriptedXMLHttpRequest.scripts.push({ outcome: 'pending' });
    await fireEvent.change(screen.getByLabelText('Choose Files'), { target: { files: [file] } });
    await fireEvent.click(await screen.findByRole('button', { name: 'Cancel' }));

    expect((await screen.findByRole('alert')).textContent).toContain('Partial files were removed.');
    expect(deleted).toEqual(['/api/imports/import-3']);
  });

  test('preserves folder paths, accepts drag/drop, and returns to pairing after session expiry', async () => {
    const manifests = [];
    await connect(async (path, options = {}) => {
      if (path === '/api/pair') return jsonResponse(200, { token: 'browser-token', deviceName: 'Test iPhone' });
      if (path === '/api/imports') {
        manifests.push(JSON.parse(options.body));
        return jsonResponse(400, { message: manifests.length === 3
          ? 'This browser no longer has access to the receiver.'
          : 'Test selection captured.' });
      }
      throw new Error(`Unexpected request: ${options.method ?? 'GET'} ${path}`);
    });

    const folderFile = new File(['chapter'], 'Chapter 01.mp3', { type: 'audio/mpeg' });
    Object.defineProperty(folderFile, 'webkitRelativePath', { value: 'My Book/Disc 1/Chapter 01.mp3' });
    await fireEvent.change(screen.getByLabelText('Choose Folder'), {
      target: { files: [folderFile] },
    });
    await screen.findByText('Test selection captured.');
    expect(manifests[0]).toMatchObject({
      selectionKind: 'folder',
      selectionName: 'My Book',
      entries: [{ path: 'Disc 1/Chapter 01.mp3', byteCount: 7 }],
    });

    const droppedFile = new File(['drop'], 'Dropped.m4a', { type: 'audio/mp4' });
    const dropTarget = screen.getByRole('button', { name: 'Drop books or folders here' });
    await fireEvent.drop(dropTarget, {
      dataTransfer: { items: [{ getAsFile: () => droppedFile }] },
    });
    await waitFor(() => expect(manifests).toHaveLength(2));
    expect(manifests[1]).toMatchObject({
      selectionKind: 'files',
      entries: [{ path: 'Dropped.m4a', byteCount: 4 }],
    });

    const expired = new File(['expired'], 'Expired.mp3', { type: 'audio/mpeg' });
    await fireEvent.change(screen.getByLabelText('Choose Files'), { target: { files: [expired] } });
    expect(await screen.findByRole('heading', { name: 'Connect to Bookshelf' })).toBeTruthy();
    expect(screen.getByRole('alert').textContent).toContain('Enter the new code shown in Bookshelf');
  });
});
