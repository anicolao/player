<script>
  import { buildUploadPlan, canResumeImport } from './upload-plan.js';

  let phase = 'pairing';
  let code = '';
  let token = '';
  let deviceName = 'iPhone';
  let error = '';
  let dragging = false;
  let selection = [];
  let selectionKind = 'files';
  let selectionName = '';
  let importID = '';
  let completedBytes = 0;
  let totalBytes = 0;
  let statusMessage = '';
  let activeRequest = null;
  let cancelling = false;
  let fileInput;

  const supportedExtensions = new Set(['m4a', 'm4b', 'mp3', 'zip']);

  function normalizeCode(value) {
    return value.replace(/\D/g, '').slice(0, 6);
  }

  async function pair() {
    if (code.length !== 6) return;
    error = '';
    try {
      const response = await fetch('/api/pair', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ code })
      });
      const payload = await response.json();
      if (!response.ok) throw new Error(payload.message || 'That code did not match.');
      token = payload.token;
      deviceName = payload.deviceName || 'iPhone';
      history.replaceState({}, '', '/');
      phase = 'ready';
    } catch (caught) {
      error = caught instanceof Error ? caught.message : 'Bookshelf could not be reached.';
    }
  }

  function extension(path) {
    const dot = path.lastIndexOf('.');
    return dot === -1 ? '' : path.slice(dot + 1).toLowerCase();
  }

  function acceptFiles(items) {
    error = '';
    let files = items
      .filter(({ file }) => supportedExtensions.has(extension(file.name)))
      .sort((left, right) => left.path.localeCompare(right.path, undefined, { numeric: true }));
    if (!files.length) {
      error = 'No supported audiobook files were found.';
      return;
    }
    const firstComponents = new Set(files.map(({ path }) => path.includes('/') ? path.split('/')[0] : ''));
    if (firstComponents.size === 1 && !firstComponents.has('')) {
      selectionKind = 'folder';
      selectionName = [...firstComponents][0];
      files = files.map(({ file, path }) => ({
        file,
        path: path.slice(selectionName.length + 1)
      }));
    } else {
      selectionKind = 'files';
      selectionName = files.length === 1
        ? files[0].file.name.replace(/\.[^.]+$/, '')
        : `${files.length} audio files`;
    }
    selection = files;
    void beginUpload();
  }

  function fromInput(event, folder) {
    const files = Array.from(event.currentTarget.files || []).map((file) => ({
      file,
      path: folder && file.webkitRelativePath ? file.webkitRelativePath : file.name
    }));
    event.currentTarget.value = '';
    acceptFiles(files);
  }

  async function fileFromEntry(entry, prefix) {
    return await new Promise((resolve, reject) => {
      entry.file(
        (file) => resolve({ file, path: `${prefix}${file.name}` }),
        reject
      );
    });
  }

  async function entriesFromDirectory(entry, prefix = '') {
    const directoryPrefix = `${prefix}${entry.name}/`;
    const reader = entry.createReader();
    const children = [];
    while (true) {
      const batch = await new Promise((resolve, reject) => reader.readEntries(resolve, reject));
      if (!batch.length) break;
      children.push(...batch);
    }
    const nested = await Promise.all(children.map(async (child) => {
      if (child.isDirectory) return await entriesFromDirectory(child, directoryPrefix);
      if (child.isFile) return [await fileFromEntry(child, directoryPrefix)];
      return [];
    }));
    return nested.flat();
  }

  async function dropped(event) {
    event.preventDefault();
    dragging = false;
    error = '';
    try {
      const items = Array.from(event.dataTransfer?.items || []);
      const gathered = [];
      for (const item of items) {
        const entry = item.webkitGetAsEntry?.();
        if (entry?.isDirectory) gathered.push(...await entriesFromDirectory(entry));
        else if (entry?.isFile) gathered.push(await fileFromEntry(entry, ''));
        else {
          const file = item.getAsFile();
          if (file) gathered.push({ file, path: file.name });
        }
      }
      acceptFiles(gathered);
    } catch (caught) {
      error = caught instanceof Error
        ? `That folder could not be read: ${caught.message}`
        : 'That folder could not be read. Try Choose Folder instead.';
      phase = 'ready';
    }
  }

  function openFilePickerFromKeyboard(event) {
    if (event.key !== 'Enter' && event.key !== ' ') return;
    event.preventDefault();
    fileInput?.click();
  }

  async function beginUpload() {
    importID = '';
    totalBytes = selection.reduce((total, item) => total + item.file.size, 0);
    completedBytes = 0;
    statusMessage = 'Preparing transfer…';
    phase = 'uploading';
    try {
      const response = await fetch('/api/imports', {
        method: 'POST',
        headers: {
          'Authorization': `Bearer ${token}`,
          'Content-Type': 'application/json'
        },
        body: JSON.stringify({
          entries: selection.map(({ file, path }) => ({ path, byteCount: file.size })),
          selectionKind,
          selectionName
        })
      });
      const payload = await response.json();
      if (!response.ok) throw new Error(payload.message || 'Bookshelf rejected this selection.');
      importID = payload.id;
      await transferActiveImport();
    } catch (caught) {
      await handleTransferFailure(caught);
    } finally {
      activeRequest = null;
    }
  }

  async function transferActiveImport() {
    cancelling = false;
    phase = 'uploading';
    error = '';
    const status = await fetchImportStatus();
    const plan = buildUploadPlan(selection, status.fileOffsets);
    for (const { index, item, offset, body } of plan) {
      statusMessage = offset > 0
        ? `Resuming ${index + 1} of ${selection.length} files at ${formatBytes(offset)}`
        : `Sending ${index + 1} of ${selection.length} files · waiting for Bookshelf to confirm each file`;
      await uploadFile(importID, index, item.file, offset, body);
      await fetchImportStatus();
    }
    statusMessage = 'Bookshelf is checking your files…';
    const complete = await fetch(`/api/imports/${importID}/complete`, {
      method: 'POST',
      headers: { 'Authorization': `Bearer ${token}` }
    });
    const completePayload = await complete.json();
    if (!complete.ok) throw new Error(completePayload.message || 'The upload could not be completed.');
    activeRequest = null;
    phase = 'importing';
    await pollResult();
  }

  async function retryTransfer() {
    try {
      await transferActiveImport();
    } catch (caught) {
      await handleTransferFailure(caught);
    } finally {
      activeRequest = null;
    }
  }

  async function handleTransferFailure(caught) {
    if (cancelling) return;
    const message = caught instanceof Error ? caught.message : 'The transfer was interrupted.';
    if (importID && selection.length) {
      try {
        const status = await fetchImportStatus();
        if (canResumeImport(status, selection)) {
          error = `${message} Bookshelf kept the confirmed bytes; retry to continue.`;
          statusMessage = 'Transfer paused safely.';
          phase = 'retry';
          return;
        }
        if (status.state === 'importing') {
          statusMessage = status.message || 'Bookshelf is checking your files…';
          activeRequest = null;
          phase = 'importing';
          await pollResult();
          return;
        }
        if (status.state === 'completed' || status.state === 'needsReview') {
          statusMessage = status.message || 'Your audiobook is ready in Bookshelf.';
          importID = '';
          selection = [];
          phase = 'completed';
          return;
        }
      } catch {
        // The receiver itself is unavailable; reconnect and start again.
      }
    }
    importID = '';
    completedBytes = 0;
    totalBytes = selection.reduce((total, item) => total + item.file.size, 0);
    if (/not paired|no longer has|failed to fetch|load failed|network|connection|could not be reached/i.test(message)) {
      token = '';
      code = '';
      error = 'This receiver session ended. Enter the new code shown in Bookshelf, then choose the book again.';
      phase = 'pairing';
    } else {
      error = message;
      phase = 'ready';
    }
  }

  async function fetchImportStatus() {
    const response = await fetch(`/api/imports/${importID}`, {
      headers: { 'Authorization': `Bearer ${token}` }
    });
    const payload = await response.json();
    if (!response.ok) throw new Error(payload.message || 'Bookshelf lost this import.');
    if (Number.isFinite(payload.completedBytes)) completedBytes = payload.completedBytes;
    if (Number.isFinite(payload.totalBytes)) totalBytes = payload.totalBytes;
    return payload;
  }

  async function discardImport() {
    if (!importID) return;
    const discardedID = importID;
    importID = '';
    await fetch(`/api/imports/${discardedID}`, {
      method: 'DELETE',
      headers: { 'Authorization': `Bearer ${token}` }
    }).catch(() => {});
  }

  function uploadFile(id, index, file, offset, body) {
    return new Promise((resolve, reject) => {
      const request = new XMLHttpRequest();
      let polling = false;
      const updateFromPlayer = async () => {
        if (polling) return;
        polling = true;
        try {
          const response = await fetch(`/api/imports/${id}`, {
            headers: { 'Authorization': `Bearer ${token}` }
          });
          if (!response.ok) return;
          const payload = await response.json();
          if (Number.isFinite(payload.completedBytes)) completedBytes = payload.completedBytes;
          if (Number.isFinite(payload.totalBytes)) totalBytes = payload.totalBytes;
        } catch {
          // The upload request owns connection errors; polling is best-effort.
        } finally {
          polling = false;
        }
      };
      const timer = setInterval(() => void updateFromPlayer(), 400);
      const finish = (callback) => {
        clearInterval(timer);
        callback();
      };
      activeRequest = request;
      request.open('PUT', `/api/imports/${id}/files/${index}`);
      request.setRequestHeader('Authorization', `Bearer ${token}`);
      request.setRequestHeader('Content-Type', 'application/octet-stream');
      request.setRequestHeader('X-Player-Upload-Offset', String(offset));
      request.onload = () => {
        if (request.status >= 200 && request.status < 300) finish(resolve);
        else {
          let message = `Could not send ${file.name}.`;
          try {
            message = JSON.parse(request.responseText || '{}').message || message;
          } catch {
            // Keep the actionable fallback when an intermediary returns non-JSON.
          }
          finish(() => reject(new Error(message)));
        }
      };
      request.onerror = () => finish(() => reject(new Error(`Connection lost while sending ${file.name}.`)));
      request.onabort = () => finish(() => reject(new Error('Transfer cancelled.')));
      request.send(body);
    });
  }

  async function pollResult() {
    while (true) {
      const response = await fetch(`/api/imports/${importID}`, {
        headers: { 'Authorization': `Bearer ${token}` }
      });
      const payload = await response.json();
      if (!response.ok) throw new Error(payload.message || 'Bookshelf lost this import.');
      statusMessage = payload.message || 'Bookshelf is checking your files…';
      if (payload.state === 'completed') {
        importID = '';
        selection = [];
        phase = 'completed';
        return;
      }
      if (payload.state === 'needsReview') {
        importID = '';
        selection = [];
        phase = 'completed';
        return;
      }
      if (payload.state === 'failed') throw new Error(payload.message || 'Bookshelf could not import these files.');
      await new Promise((resolve) => setTimeout(resolve, 400));
    }
  }

  async function cancelTransfer() {
    cancelling = true;
    activeRequest?.abort();
    await discardImport();
    selection = [];
    completedBytes = 0;
    totalBytes = 0;
    phase = 'ready';
    error = 'Transfer cancelled. Partial files were removed.';
    cancelling = false;
  }

  function sendAnother() {
    selection = [];
    importID = '';
    completedBytes = 0;
    totalBytes = 0;
    statusMessage = '';
    error = '';
    phase = 'ready';
  }

  function formatBytes(bytes) {
    if (bytes < 1000) return `${bytes} B`;
    if (bytes < 1000 ** 2) return `${(bytes / 1000).toFixed(1)} KB`;
    if (bytes < 1000 ** 3) return `${(bytes / 1000 ** 2).toFixed(1)} MB`;
    return `${(bytes / 1000 ** 3).toFixed(2)} GB`;
  }

  $: progress = totalBytes ? Math.min(100, Math.round(completedBytes / totalBytes * 100)) : 0;
  $: sourceName = selection.length === 1
    ? selectionName
    : selectionName || `${selection.length} audio files`;
</script>

<svelte:head><title>Send audiobooks to Bookshelf</title></svelte:head>

<main>
  <header><span class="mark" aria-hidden="true">▥</span><strong>Bookshelf</strong></header>

  {#if phase === 'pairing'}
    <section class="panel pairing" aria-labelledby="pair-title">
      <h1 id="pair-title">Connect to Bookshelf</h1>
      <p>Enter the pairing code shown on your iPhone.</p>
      <input
        class="code"
        aria-label="Six-digit pairing code"
        inputmode="numeric"
        autocomplete="one-time-code"
        maxlength="6"
        bind:value={code}
        oninput={(event) => code = normalizeCode(event.currentTarget.value)}
        onkeydown={(event) => event.key === 'Enter' && pair()}
        placeholder="000 000"
      />
      <button class="primary" disabled={code.length !== 6} onclick={pair}>Connect</button>
      {#if error}<p class="error" role="alert">{error}</p>{/if}
      <p class="privacy">⌾ Private to this local network</p>
    </section>
  {:else if phase === 'ready'}
    <section class="panel" aria-labelledby="send-title">
      <p class="connected">✓ Connected to {deviceName}</p>
      <h1 id="send-title">Send audiobooks to Bookshelf</h1>
      <div
        class:dragging
        class="drop-zone"
        role="button"
        tabindex="0"
        aria-label="Drop books or folders here"
        ondragenter={(event) => { event.preventDefault(); dragging = true; }}
        ondragover={(event) => event.preventDefault()}
        ondragleave={() => dragging = false}
        ondrop={dropped}
        onkeydown={openFilePickerFromKeyboard}
      >
        <div class="drop-icons" aria-hidden="true">▱ ♫</div>
        <h2>Drop books or folders here</h2>
        <p>M4B, M4A, MP3, ZIP, or an entire directory tree</p>
        <div class="choices">
          <label class="secondary">Choose Files<input bind:this={fileInput} type="file" multiple accept=".m4b,.m4a,.mp3,.zip" onchange={(event) => fromInput(event, false)} /></label>
          <label class="secondary">Choose Folder<input type="file" webkitdirectory multiple onchange={(event) => fromInput(event, true)} /></label>
        </div>
      </div>
      {#if error}<p class="error" role="alert">{error}</p>{/if}
      <p class="privacy">⌾ Your originals stay on this computer.</p>
    </section>
  {:else if phase === 'uploading' || phase === 'retry' || phase === 'importing'}
    <section class="panel" aria-labelledby="upload-title">
      <p class="connected">✓ Connected to {deviceName}</p>
      <h1 id="upload-title">Sending {selection.length === 1 ? '1 book' : `${selection.length} files`}</h1>
      <article class="transfer-card">
        <h2>{sourceName}</h2>
        <p>{selection.length} audio {selection.length === 1 ? 'file' : 'files'} · {formatBytes(totalBytes)}</p>
        <progress value={progress} max="100">{progress}%</progress>
        <div class="progress-copy"><span>{formatBytes(completedBytes)} of {formatBytes(totalBytes)}</span><strong>{progress}%</strong></div>
        <p>{statusMessage}</p>
        {#if phase === 'retry'}
          <div class="transfer-actions">
            <button class="primary compact" onclick={retryTransfer}>Retry transfer</button>
            <button class="secondary" onclick={cancelTransfer}>Cancel and clean up</button>
          </div>
          {#if error}<p class="error" role="alert">{error}</p>{/if}
        {:else if phase === 'uploading'}
          <button class="secondary" onclick={cancelTransfer}>Cancel</button>
        {:else}
          <p class="privacy">The transfer is sealed; Bookshelf will finish even if this page closes.</p>
        {/if}
      </article>
      <p class="success-note">✓ Valid books appear automatically in your Library.</p>
    </section>
  {:else}
    <section class="panel completed" aria-labelledby="complete-title">
      <div class="complete-icon" aria-hidden="true">✓</div>
      <h1 id="complete-title">Sent to Bookshelf</h1>
      <p>{statusMessage || 'Your audiobook is ready in Library.'}</p>
      <button class="primary compact" onclick={sendAnother}>Send another book</button>
      <p class="privacy">Or close this page when you are finished.</p>
    </section>
  {/if}
</main>

<style>
  :global(*) { box-sizing: border-box; }
  :global(body) { margin: 0; min-width: 320px; color: #1e2327; background: #f6f2ea; font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; }
  :global(button), :global(input) { font: inherit; }
  main { width: min(780px, calc(100% - 32px)); margin: 0 auto; padding: 30px 0 64px; }
  header { display: flex; align-items: center; gap: 10px; font-size: 22px; }
  .mark { display: grid; place-items: center; width: 30px; height: 30px; color: #b0442a; font-size: 30px; }
  .panel { margin-top: 38px; text-align: center; }
  .pairing { width: min(480px, 100%); margin-inline: auto; }
  h1 { margin: 0 0 12px; font-size: clamp(30px, 5vw, 42px); letter-spacing: -0.035em; }
  h2 { margin: 0 0 8px; font-size: 23px; }
  p { color: #595f62; line-height: 1.5; }
  .code { display: block; width: min(390px, 100%); margin: 36px auto 24px; padding: 17px 22px; border: 1px solid #d8d2c8; border-radius: 12px; color: #1e2327; background: #fffdf8; font-size: 36px; font-weight: 650; text-align: center; letter-spacing: 0.42em; }
  button, .secondary { min-height: 52px; border-radius: 11px; border: 1.5px solid #b0442a; padding: 13px 24px; cursor: pointer; font-weight: 650; }
  button:focus-visible, .secondary:focus-within, .drop-zone:focus-visible, input:focus-visible { outline: 3px solid #1e2327; outline-offset: 3px; }
  button:disabled { opacity: 0.45; cursor: default; }
  .primary { width: min(390px, 100%); color: white; background: #b0442a; }
  .secondary { display: inline-grid; place-items: center; color: #b0442a; background: #fffdf8; }
  .secondary input { position: absolute; width: 1px; height: 1px; opacity: 0; }
  .connected { color: #22743b; font-weight: 600; }
  .drop-zone { margin-top: 26px; padding: 42px 24px; border: 2px dashed #a69d91; border-radius: 18px; background: #fffdf8; transition: border-color .15s, background .15s; }
  .drop-zone.dragging { border-color: #b0442a; background: #fff7f2; }
  .drop-icons { margin-bottom: 16px; color: #7c746a; font-size: 52px; }
  .choices { display: flex; justify-content: center; gap: 14px; margin-top: 26px; flex-wrap: wrap; }
  .privacy { margin-top: 30px; color: #6a6f70; font-size: 14px; }
  .error { color: #9b1c1c; font-weight: 600; }
  .transfer-card { margin-top: 28px; padding: 28px; border: 1px solid #ddd6cb; border-radius: 17px; background: #fffdf8; text-align: left; box-shadow: 0 12px 40px rgb(30 35 39 / 6%); }
  progress { width: 100%; height: 10px; margin: 18px 0 8px; border: 0; border-radius: 999px; overflow: hidden; appearance: none; }
  progress::-webkit-progress-bar { background: #e5dfd4; }
  progress::-webkit-progress-value { background: #b0442a; }
  progress::-moz-progress-bar { background: #b0442a; }
  .progress-copy { display: flex; justify-content: space-between; color: #595f62; }
  .transfer-card button { float: right; }
  .transfer-actions { display: flex; justify-content: flex-end; gap: 12px; flex-wrap: wrap; }
  .transfer-actions button { float: none; }
  .compact { width: auto; }
  .success-note { margin-top: 28px; padding: 17px; border: 1px solid #bdd6ba; border-radius: 12px; color: #246834; background: #eef6eb; }
  .completed { width: min(520px, 100%); margin-inline: auto; padding: 48px 26px; border: 1px solid #d5ddce; border-radius: 20px; background: #fffdf8; }
  .complete-icon { display: grid; place-items: center; width: 64px; height: 64px; margin: 0 auto 20px; border-radius: 50%; color: white; background: #347845; font-size: 34px; }
  @media (max-width: 560px) { main { padding-top: 20px; } .drop-zone { padding: 30px 16px; } .code { letter-spacing: 0.25em; } }
  @media (prefers-reduced-motion: reduce) { * { transition: none !important; } }
</style>
