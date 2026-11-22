(() => {
  const PALETTE = [
    'var(--c0)', 'var(--c1)', 'var(--c2)', 'var(--c3)',
    'var(--c4)', 'var(--c5)', 'var(--c6)', 'var(--c7)'
  ];

  const state = {
    volumes: [],
    selectedVolumeId: null,
    viewMode: 'overview', // 'overview' | 'icicle'
    layoutMode: 'scroll', // 'scroll' | 'fit'
    maxDepth: 10,         // 5 | 10 | 20 | 50 | 0 (unlimited)
    groupSmall: false,
    hideFreeSpace: false,
    highlightRebuildsOnly: false,
    vZoom: 1,             // Vertical-only zoom factor (1..25)
    scanning: false,
    scanningVolumeId: null,
    treeData: null,
    currentPath: '',
    renderedNodes: [],
    eventSource: null,
    undoCount: 0,
    undoLabel: ''
  };

  // DOM refs
  const elDrivePills = document.getElementById('drive-pills');
  const elViewControls = document.getElementById('view-controls');
  const elBtnHome = document.getElementById('btn-home');
  const elBtnScan = document.getElementById('btn-scan');
  const elBtnScanLabel = document.getElementById('btn-scan-label');
  const elBtnCancel = document.getElementById('btn-cancel');
  const elBtnUndo = document.getElementById('btn-undo');
  const elBtnUndoLabel = document.getElementById('btn-undo-label');
  const elBtnTrash = document.getElementById('btn-trash');
  const elBtnReveal = document.getElementById('btn-reveal');
  const elBreadcrumbs = document.getElementById('breadcrumbs');
  const elCacheLegend = document.getElementById('cache-legend');
  const elToggleRebuilds = document.getElementById('toggle-rebuilds');
  const elDepthHint = document.getElementById('depth-hint');
  const elScanStrip = document.getElementById('scan-strip');
  const elScanPath = document.getElementById('scan-path');
  const elScanCounters = document.getElementById('scan-counters');
  const elScanBar = document.getElementById('scan-bar');
  const elViewport = document.getElementById('viewport');
  const elHoverTooltip = document.getElementById('hover-tooltip');
  const elModeScroll = document.getElementById('mode-scroll');
  const elModeFit = document.getElementById('mode-fit');
  const elSelectDepth = document.getElementById('select-depth');
  const elToggleGroup = document.getElementById('toggle-group');
  const elToggleHideFree = document.getElementById('toggle-hide-free');
  const elBtnZoomReset = document.getElementById('btn-zoom-reset');
  const elContextMenu = document.getElementById('context-menu');
  const elToast = document.getElementById('toast');

  function fmtTimeAgo(iso) {
    if (!iso) return '';
    const diffSec = Math.max(0, Math.floor((Date.now() - new Date(iso).getTime()) / 1000));
    if (diffSec < 60) return 'just now';
    const mins = Math.floor(diffSec / 60);
    if (mins < 60) return `${mins}m ago`;
    const hrs = Math.floor(mins / 60);
    if (hrs < 24) return `${hrs}h ago`;
    return `${Math.floor(hrs / 24)}d ago`;
  }

  function fmtBytes(bytes) {
    if (!bytes || bytes <= 0) return '0 B';
    const units = ['B', 'KB', 'MB', 'GB', 'TB', 'PB'];
    let i = 0;
    let v = bytes;
    while (v >= 1000 && i < units.length - 1) {
      v /= 1000;
      i++;
    }
    return v.toFixed(v >= 100 ? 0 : v >= 10 ? 1 : 2) + ' ' + units[i];
  }

  function fmtNum(n) {
    return typeof n === 'number' ? n.toLocaleString() : '0';
  }

  function escapeHtml(s) {
    return String(s)
      .replace(/&/g, '&amp;')
      .replace(/</g, '&lt;')
      .replace(/>/g, '&gt;')
      .replace(/"/g, '&quot;');
  }

  function getSelectedVolume() {
    return state.volumes.find(v => v.id === state.selectedVolumeId) || state.volumes[0] || null;
  }

  // ---- API Calls ----
  async function loadVolumes() {
    const res = await fetch('/api/volumes');
    const data = await res.json();
    state.volumes = data.volumes || [];
    if (!state.selectedVolumeId && state.volumes.length > 0) {
      state.selectedVolumeId = state.volumes[0].id;
    }
    renderToolbar();
    if (state.viewMode === 'overview') {
      renderOverview();
      renderBreadcrumbs();
      renderFooterDefault();
    }
  }

  async function loadTree(volumeId, path, opts = {}) {
    const params = new URLSearchParams({
      volume: volumeId,
      path: path || '',
      maxDepth: String(state.maxDepth),
      groupSmall: state.groupSmall ? '1' : '0'
    });
    const res = await fetch('/api/tree?' + params.toString());
    if (!res.ok) {
      state.viewMode = 'overview';
      state.treeData = null;
      renderAll();
      return;
    }
    const prevTop = elViewport.scrollTop;
    const prevLeft = elViewport.scrollLeft;
    state.treeData = await res.json();
    state.currentPath = state.treeData.root.path;
    state.viewMode = 'icicle';
    if (!opts.preserveView) {
      state.vZoom = 1;
      targetVZoom = 1;
      elViewport.scrollTop = 0;
    }
    renderAll();
    if (opts.preserveView) {
      elViewport.scrollTop = prevTop;
      elViewport.scrollLeft = prevLeft;
    }
  }

  async function startScan(volumeId) {
    if (state.scanning) return;
    state.selectedVolumeId = volumeId;
    state.scanning = true;
    state.scanningVolumeId = volumeId;

    elScanStrip.classList.remove('hidden');
    elScanBar.style.width = '4%';
    elScanPath.textContent = 'Starting parallel multi-core scan...';
    elScanCounters.textContent = '';
    renderToolbar();

    const res = await fetch('/api/scan', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ volumeId })
    });
    if (!res.ok) {
      state.scanning = false;
      elScanStrip.classList.add('hidden');
      renderToolbar();
      return;
    }

    listenScanEvents(volumeId);
  }

  async function cancelScan() {
    await fetch('/api/scan/cancel', { method: 'POST' });
    if (state.eventSource) {
      state.eventSource.close();
      state.eventSource = null;
    }
    state.scanning = false;
    state.scanningVolumeId = null;
    elScanStrip.classList.add('hidden');
    renderToolbar();
  }

  function listenScanEvents(volumeId) {
    if (state.eventSource) {
      state.eventSource.close();
    }
    const es = new EventSource('/api/scan/events');
    state.eventSource = es;

    es.addEventListener('progress', (ev) => {
      const p = JSON.parse(ev.data);
      const vol = state.volumes.find(v => v.id === p.volumeId);
      let pct = 10;
      if (vol && vol.usedBytes > 0) {
        pct = Math.min(98, Math.max(4, Math.round((p.bytes / vol.usedBytes) * 100)));
      }
      elScanBar.style.width = pct + '%';
      elScanPath.textContent = `Scanning (${p.workers} workers): ${p.currentPath}`;
      elScanCounters.textContent = `${fmtBytes(p.bytes)} · ${fmtNum(p.files)} files · ${(p.elapsedMs / 1000).toFixed(1)}s`;
    });

    es.addEventListener('done', async (ev) => {
      es.close();
      state.eventSource = null;
      const info = JSON.parse(ev.data);
      state.scanning = false;
      state.scanningVolumeId = null;
      elScanBar.style.width = '100%';
      setTimeout(() => elScanStrip.classList.add('hidden'), 200);

      await loadVolumes();
      if (!info.canceled && !info.error) {
        await loadTree(volumeId, '');
      } else {
        renderAll();
      }
    });

    es.onerror = () => {
      es.close();
      state.eventSource = null;
      state.scanning = false;
      elScanStrip.classList.add('hidden');
      renderToolbar();
    };
  }

  async function revealInFinder(path) {
    if (!path || path.endsWith('/*') || path.endsWith('(direct files)')) return;
    await fetch('/api/reveal', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ path })
    });
  }

  async function markRuleRebuilds(path, label) {
    const res = await fetch('/api/rules/mark', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ path, label })
    });
    if (!res.ok) {
      showToast('Could not save custom rule', { error: true });
      return;
    }
    showToast(`Marked "${label}" as "Rebuilds Itself"`);
    if (state.viewMode === 'icicle' && state.treeData) {
      await loadTree(state.treeData.volumeId, state.currentPath, { preserveView: true });
    }
  }

  async function unmarkRule(path, label) {
    const res = await fetch('/api/rules/unmark', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ path })
    });
    if (!res.ok) {
      showToast('Could not update custom rules', { error: true });
      return;
    }
    showToast(`Removed "Rebuilds Itself" tag from "${label}"`);
    if (state.viewMode === 'icicle' && state.treeData) {
      await loadTree(state.treeData.volumeId, state.currentPath, { preserveView: true });
    }
  }

  const PROTECTED_PATHS = new Set([
    '/', '/System', '/Library', '/Users', '/Applications',
    '/Volumes', '/private', '/usr', '/bin', '/sbin', '/etc', '/var', '/dev', '/opt'
  ]);

  function isTrashable(node, volumeId) {
    if (!node || node.isFree || node.isSystemGap || node.isGrouped) return false;
    const p = node.path || '';
    if (!p || p === volumeId || PROTECTED_PATHS.has(p)) return false;
    if (p.endsWith('/*') || p.endsWith('(direct files)')) return false;
    return true;
  }

  let toastTimer = null;
  function showToast(message, opts = {}) {
    clearTimeout(toastTimer);
    elToast.className = 'toast' + (opts.error ? ' error' : '');
    elToast.innerHTML = `
      <span>${escapeHtml(message)}</span>
      ${opts.showUndo ? '<button id="toast-undo-btn" class="btn-undo">Undo</button>' : ''}
    `;
    elToast.classList.remove('hidden');
    if (opts.showUndo) {
      const btn = document.getElementById('toast-undo-btn');
      if (btn) btn.addEventListener('click', () => undoTrash());
    }
    toastTimer = setTimeout(() => {
      elToast.classList.add('hidden');
    }, opts.duration || 4500);
  }

  function closeContextMenu() {
    elContextMenu.classList.add('hidden');
    elContextMenu.innerHTML = '';
  }

  function openContextMenu(x, y, item) {
    const td = state.treeData;
    const n = item.node;
    if (!td || !n || n.isFree || n.isSystemGap || n.isGrouped) return;

    const canTrash = isTrashable(n, td.volumeId);
    const items = [];
    if (n.isDir) {
      items.push(`<button class="ctx-item" data-ctx="zoom"><span>Zoom Into Folder</span></button>`);
    }
    if (!n.path.endsWith('(direct files)')) {
      items.push(`<button class="ctx-item" data-ctx="reveal"><span>Reveal in Finder</span></button>`);
    }
    if (n.isDir && !n.path.endsWith('(direct files)') && n.path !== td.volumeId) {
      if (n.hint && n.hint.safety === 'rebuilds') {
        items.push(`<button class="ctx-item" data-ctx="unmark"><span>Remove "Rebuilds Itself" Tag</span></button>`);
      } else {
        items.push(`<button class="ctx-item rebuilds" data-ctx="mark"><span>Mark as "Rebuilds Itself"</span></button>`);
      }
    }
    if (canTrash) {
      items.push(`<button class="ctx-item danger" data-ctx="trash"><span>Move to Trash</span><span style="font-family:'SF Mono',monospace;font-size:10.5px;opacity:0.8">${fmtBytes(n.size)}</span></button>`);
    }
    if (!items.length) return;

    const hintHtml = n.hint
      ? `<div class="ctx-hint-row"><span>${escapeHtml(n.hint.label)}</span><span class="hint-pill ${escapeHtml(n.hint.safety)}">${escapeHtml(n.hint.tag)}</span></div>`
      : '';

    elContextMenu.innerHTML = `
      <div class="ctx-header" title="${escapeHtml(n.path)}">${escapeHtml(n.name)}</div>
      ${hintHtml}
      ${items.join('')}
    `;
    elContextMenu.classList.remove('hidden');

    // Keep menu inside window bounds
    const mw = elContextMenu.offsetWidth || 210;
    const mh = elContextMenu.offsetHeight || 120;
    const left = Math.min(x, window.innerWidth - mw - 10);
    const top = Math.min(y, window.innerHeight - mh - 10);
    elContextMenu.style.left = Math.max(8, left) + 'px';
    elContextMenu.style.top = Math.max(8, top) + 'px';

    elContextMenu.querySelectorAll('[data-ctx]').forEach(btn => {
      btn.addEventListener('click', (ev) => {
        ev.stopPropagation();
        const action = btn.dataset.ctx;
        closeContextMenu();
        if (action === 'zoom') loadTree(td.volumeId, n.path);
        else if (action === 'reveal') revealInFinder(n.path);
        else if (action === 'mark') markRuleRebuilds(n.path, n.name);
        else if (action === 'unmark') unmarkRule(n.path, n.name);
        else if (action === 'trash') moveToTrash(td.volumeId, n.path);
      });
    });
  }

  async function loadTrashStatus() {
    try {
      const res = await fetch('/api/trash/status');
      if (!res.ok) return;
      const data = await res.json();
      state.undoCount = data.undoCount || 0;
      state.undoLabel = data.undoLabel || '';
      renderUndoButton();
    } catch (_) {}
  }

  function renderUndoButton() {
    if (state.undoCount > 0) {
      elBtnUndoLabel.textContent = state.undoLabel ? `Undo "${state.undoLabel}"` : 'Undo';
      elBtnUndo.title = `Pull "${state.undoLabel}" back out of Trash (⌘Z)`;
      elBtnUndo.classList.remove('hidden');
    } else {
      elBtnUndo.classList.add('hidden');
    }
  }

  async function moveToTrash(volumeId, path) {
    const res = await fetch('/api/trash', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ volumeId, path })
    });
    if (!res.ok) {
      const msg = (await res.text()).trim() || 'Could not move item to Trash';
      showToast(msg, { error: true });
      return;
    }
    const data = await res.json();
    state.undoCount = data.undoCount || 0;
    state.undoLabel = data.undoLabel || '';
    renderUndoButton();

    showToast(`Moved "${data.name}" to Trash`, { showUndo: true });

    // If we trashed the currently focused folder, step up to its parent; otherwise refresh current view
    const nextPath = (state.currentPath === data.originalPath) ? (data.parentPath || '') : state.currentPath;
    if (state.viewMode === 'icicle' && state.treeData) {
      await loadTree(volumeId, nextPath);
    }
  }

  async function undoTrash() {
    if (state.undoCount <= 0) return;
    const res = await fetch('/api/trash/undo', { method: 'POST' });
    if (!res.ok) {
      const msg = (await res.text()).trim() || 'Could not restore item from Trash';
      showToast(msg, { error: true });
      return;
    }
    const data = await res.json();
    state.undoCount = data.undoCount || 0;
    state.undoLabel = data.undoLabel || '';
    renderUndoButton();

    showToast(`Restored "${data.name}" from Trash`);
    if (state.viewMode === 'icicle' && state.treeData && state.treeData.volumeId === data.volumeId) {
      await loadTree(data.volumeId, state.currentPath);
    }
  }

  // ---- Rendering ----
  function renderToolbar() {
    const vol = getSelectedVolume();
    elDrivePills.innerHTML = state.volumes.map(v => {
      const active = v.id === state.selectedVolumeId && state.viewMode === 'icicle';
      const usedPct = v.totalBytes > 0 ? Math.round((v.usedBytes / v.totalBytes) * 100) : 0;
      return `
        <button class="drive-pill ${active ? 'active' : ''}" data-vol="${escapeHtml(v.id)}">
          <span class="dot ${v.scanned ? 'scanned' : ''}"></span>
          <span>${escapeHtml(v.name)}</span>
          <span style="font-family: 'SF Mono', monospace; opacity: 0.7;">${usedPct}%</span>
        </button>
      `;
    }).join('');

    elDrivePills.querySelectorAll('.drive-pill').forEach(btn => {
      btn.addEventListener('click', () => {
        const id = btn.dataset.vol;
        state.selectedVolumeId = id;
        const v = state.volumes.find(x => x.id === id);
        if (v && v.scanned) {
          loadTree(id, '');
        } else {
          state.viewMode = 'overview';
          renderAll();
        }
      });
    });

    elViewControls.classList.toggle('hidden', state.viewMode !== 'icicle');
    elModeScroll.classList.toggle('active', state.layoutMode === 'scroll');
    elModeFit.classList.toggle('active', state.layoutMode === 'fit');
    renderZoomPill();

    const spinIcon = elBtnScan.querySelector('.icon-spin-target');
    if (state.scanning) {
      elBtnScanLabel.textContent = 'Scanning...';
      elBtnScan.disabled = true;
      spinIcon.classList.add('spinning');
      elBtnCancel.classList.remove('hidden');
    } else {
      elBtnScan.disabled = false;
      spinIcon.classList.remove('spinning');
      elBtnCancel.classList.add('hidden');
      if (vol && vol.scanned) {
        elBtnScanLabel.textContent = 'Rescan';
      } else {
        elBtnScanLabel.textContent = 'Scan Disk';
      }
    }
  }

  function renderBreadcrumbs() {
    renderUndoButton();
    if (state.viewMode !== 'icicle' || !state.treeData) {
      elBreadcrumbs.innerHTML = `<span class="crumb-btn current">Installed Drives</span>`;
      elDepthHint.textContent = 'Used vs. Available';
      elBtnReveal.classList.add('hidden');
      elBtnTrash.classList.add('hidden');
      if (elCacheLegend) elCacheLegend.classList.add('hidden');
      return;
    }

    const crumbs = state.treeData.breadcrumbs || [];
    const html = [
      `<button class="crumb-btn" data-crumb-home="1">Drives</button>`,
      `<span style="opacity:0.4">/</span>`
    ];
    crumbs.forEach((c, idx) => {
      const isLast = idx === crumbs.length - 1;
      html.push(`<button class="crumb-btn ${isLast ? 'current' : ''}" data-crumb-path="${escapeHtml(c.path)}">${escapeHtml(c.name)}</button>`);
      if (!isLast) html.push(`<span style="opacity:0.4">/</span>`);
    });

    elBreadcrumbs.innerHTML = html.join('');
    elBreadcrumbs.querySelectorAll('[data-crumb-home]').forEach(b => {
      b.addEventListener('click', () => {
        state.viewMode = 'overview';
        renderAll();
      });
    });
    elBreadcrumbs.querySelectorAll('[data-crumb-path]').forEach(b => {
      b.addEventListener('click', () => {
        loadTree(state.treeData.volumeId, b.dataset.crumbPath);
      });
    });

    const baseLevel = Math.max(0, crumbs.length - 1);
    elDepthHint.textContent = `Levels L${baseLevel} → L${baseLevel + state.treeData.maxDepth}`;
    elBtnReveal.classList.remove('hidden');

    const rootNode = state.treeData.root;
    if (isTrashable(rootNode, state.treeData.volumeId)) {
      elBtnTrash.classList.remove('hidden');
      elBtnTrash.title = `Move "${rootNode.name}" (${fmtBytes(rootNode.size)}) to macOS Trash`;
    } else {
      elBtnTrash.classList.add('hidden');
    }
  }

  function renderFooterDefault() {
    if (elHoverTooltip) elHoverTooltip.classList.add('hidden');
  }

  function renderOverview() {
    const cards = state.volumes.map(v => {
      const usedPct = v.totalBytes > 0 ? (v.usedBytes / v.totalBytes) * 100 : 0;
      const availPct = Math.max(0, 100 - usedPct);
      const selected = v.id === state.selectedVolumeId;
      return `
        <div class="drive-card ${selected ? 'selected' : ''}" data-card-vol="${escapeHtml(v.id)}">
          <div class="drive-card-top">
            <div>
              <div class="drive-title-row">
                <span class="drive-name">${escapeHtml(v.name)}</span>
                <span class="fs-badge">${escapeHtml(v.fsType)}</span>
              </div>
              <div class="drive-mount">${escapeHtml(v.mountPoint)} · ${escapeHtml(v.device)}</div>
            </div>
            <div style="display:flex; gap:8px;">
              ${v.scanned ? `<button class="btn-secondary" data-open-vol="${escapeHtml(v.id)}">View Breakdown</button>` : ''}
              <button class="btn-primary" data-scan-vol="${escapeHtml(v.id)}" ${state.scanning ? 'disabled' : ''}>
                ${v.scanned ? 'Rescan' : 'Scan Disk'}
              </button>
            </div>
          </div>

          <div class="usage-bar">
            <div class="usage-used" style="width: ${usedPct.toFixed(2)}%;">
              ${usedPct >= 14 ? `Used · ${fmtBytes(v.usedBytes)} (${usedPct.toFixed(0)}%)` : ''}
            </div>
            <div class="usage-avail" style="width: ${availPct.toFixed(2)}%;">
              ${availPct >= 14 ? `Available · ${fmtBytes(v.availBytes)}` : ''}
            </div>
          </div>

          <div class="drive-card-foot">
            <span>Total Capacity: ${fmtBytes(v.totalBytes)}</span>
            <span>${v.scanned ? `Cached (${fmtTimeAgo(v.scannedAt) || 'saved'}) — click View Breakdown or Rescan` : 'Ready to scan on demand'}</span>
          </div>
        </div>
      `;
    }).join('');

    elViewport.innerHTML = `
      <div class="drives-overview">
        <div class="overview-header">
          <h1>Installed Volumes</h1>
          <p>Showing live used vs. available capacity. Select a drive and click <strong>Scan Disk</strong> to inspect nested folder usage.</p>
        </div>
        ${cards || '<p style="color:var(--muted)">No mounted volumes detected.</p>'}
      </div>
    `;

    elViewport.querySelectorAll('[data-card-vol]').forEach(card => {
      card.addEventListener('click', () => {
        state.selectedVolumeId = card.dataset.cardVol;
        renderToolbar();
        renderOverview();
        renderFooterDefault();
      });
    });

    elViewport.querySelectorAll('[data-scan-vol]').forEach(btn => {
      btn.addEventListener('click', (e) => {
        e.stopPropagation();
        startScan(btn.dataset.scanVol);
      });
    });

    elViewport.querySelectorAll('[data-open-vol]').forEach(btn => {
      btn.addEventListener('click', (e) => {
        e.stopPropagation();
        state.selectedVolumeId = btn.dataset.openVol;
        loadTree(btn.dataset.openVol, '');
      });
    });
  }

  // ---- Vertical Zoom Helpers ----
  const MIN_VZOOM = 1;
  const MAX_VZOOM = 25;
  const COL_HEAD_H = 26;

  function getBaseIcicleHeight() {
    return Math.max(380, elViewport.clientHeight - 38);
  }

  function renderZoomPill() {
    if (!elBtnZoomReset) return;
    if (state.viewMode === 'icicle' && state.vZoom > 1.01) {
      elBtnZoomReset.textContent = `${state.vZoom.toFixed(1)}× · Reset`;
      elBtnZoomReset.classList.remove('hidden');
    } else {
      elBtnZoomReset.classList.add('hidden');
    }
  }

  let zoomRafId = null;
  let targetVZoom = 1;
  let pendingAnchorY = null;

  function scheduleVerticalZoom(nextZoom, anchorClientY) {
    targetVZoom = Math.min(MAX_VZOOM, Math.max(MIN_VZOOM, nextZoom));
    if (typeof anchorClientY === 'number') {
      pendingAnchorY = anchorClientY;
    }
    if (zoomRafId !== null) return;
    zoomRafId = requestAnimationFrame(() => {
      zoomRafId = null;
      if (state.viewMode !== 'icicle' || !state.treeData) return;
      const oldZoom = state.vZoom;
      const newZoom = targetVZoom;
      const anchorClient = pendingAnchorY;
      pendingAnchorY = null;
      if (Math.abs(newZoom - oldZoom) < 0.002) return;

      const baseH = getBaseIcicleHeight();
      const vpRect = elViewport.getBoundingClientRect();
      const anchorY = typeof anchorClient === 'number'
        ? anchorClient - vpRect.top
        : vpRect.height / 2;
      const prevScrollLeft = elViewport.scrollLeft;
      const contentY = elViewport.scrollTop + anchorY - COL_HEAD_H;
      const ratio = Math.max(0, contentY) / Math.max(1, baseH * oldZoom);

      state.vZoom = newZoom;
      renderZoomPill();
      renderIcicle();

      const nextScrollTop = Math.max(0, ratio * (baseH * newZoom) - (anchorY - COL_HEAD_H));
      elViewport.scrollTop = nextScrollTop;
      elViewport.scrollLeft = prevScrollLeft;
    });
  }

  function applyZoomMultiplier(factor, anchorClientY) {
    scheduleVerticalZoom(targetVZoom * factor, anchorClientY);
  }

  // ---- Horizontal Icicle Renderer ----
  function renderIcicle() {
    const td = state.treeData;
    if (!td || !td.root) return;

    const baseH = getBaseIcicleHeight();
    const totalH = Math.round(baseH * state.vZoom);
    const isRoot = td.isRoot;
    const baseDepth = Math.max(0, (td.breadcrumbs || []).length - 1);

    // Prepare root children: if at disk root and volume.UsedBytes > scanned root.Size,
    // append a transparent "System / APFS Snapshots / Restricted" slice so Used matches disk reality.
    const rootClone = Object.assign({}, td.root);
    let rootChildren = (td.root.children || []).slice();
    let rootDisplaySize = td.root.size;

    if (isRoot && td.usedBytes > td.root.size) {
      const gap = td.usedBytes - td.root.size;
      if (gap > td.totalBytes * 0.005) {
        rootChildren.push({
          name: 'System / APFS Snapshots',
          path: '(system-unscanned)',
          size: gap,
          apparent: gap,
          files: 0,
          isDir: false,
          isSystemGap: true,
          children: []
        });
        rootDisplaySize = td.usedBytes;
      }
    }
    rootClone.children = rootChildren;
    rootClone.size = rootDisplaySize;

    const maxCols = Math.max(2, td.maxDepth + 1);
    const cols = Array.from({ length: maxCols }, () => []);

    const showFree = isRoot && !state.hideFreeSpace && td.totalBytes > 0;
    const usedHeight = showFree
      ? (Math.min(rootDisplaySize, td.totalBytes) / td.totalBytes) * totalH
      : totalH;
    const scaleBytes = showFree ? td.totalBytes : Math.max(1, rootDisplaySize);

    let hasVisibleRebuilds = false;

    function walk(node, relDepth, yStart, height, color, ancestorPaths, inRebuilds) {
      if (relDepth >= cols.length || height < 1.2) return;

      const isRebuildsHint = !!(node.hint && node.hint.safety === 'rebuilds');
      const nodeInRebuilds = inRebuilds || isRebuildsHint;
      const nodeColor = nodeInRebuilds ? 'var(--cache-rebuilds)' : color;
      if (nodeInRebuilds) hasVisibleRebuilds = true;

      const myAncestors = [...ancestorPaths, node.path];
      cols[relDepth].push({
        node,
        relDepth,
        absDepth: baseDepth + relDepth,
        y: yStart,
        h: height,
        color: nodeColor,
        inRebuilds: nodeInRebuilds,
        ancestorPaths: myAncestors
      });

      const kids = node.children || [];
      if (!kids.length) return;

      const sumKids = kids.reduce((acc, k) => acc + (k.size || 0), 0) || node.size || 1;
      let curY = yStart;
      kids.forEach((child, i) => {
        const ch = ((child.size || 0) / sumKids) * height;
        // Assign distinct colors at depth 1 (immediate children of focused root), inherit deeper
        let childColor = nodeColor;
        if (relDepth === 0 && !nodeInRebuilds) {
          childColor = child.isSystemGap || child.isGrouped
            ? 'var(--c-muted)'
            : PALETTE[i % PALETTE.length];
        } else if (child.isGrouped) {
          childColor = 'var(--c-muted)';
        }
        walk(child, relDepth + 1, curY, ch, childColor, myAncestors, nodeInRebuilds);
        curY += ch;
      });
    }

    walk(rootClone, 0, 0, usedHeight, 'var(--c0)', [], false);
    if (!hasVisibleRebuilds) {
      state.highlightRebuildsOnly = false;
    }
    if (elCacheLegend) {
      elCacheLegend.classList.toggle('hidden', !hasVisibleRebuilds);
    }
    if (elToggleRebuilds) {
      elToggleRebuilds.checked = state.highlightRebuildsOnly;
    }

    if (showFree && totalH - usedHeight >= 2) {
      cols[0].push({
        node: {
          name: 'Available Space',
          path: td.volumeId + ' (available)',
          size: td.availBytes,
          files: 0,
          isFree: true
        },
        relDepth: 0,
        absDepth: 0,
        y: usedHeight,
        h: totalH - usedHeight,
        color: 'transparent',
        ancestorPaths: []
      });
    }

    // Trim empty trailing columns
    let lastNonEmpty = cols.length - 1;
    while (lastNonEmpty > 1 && cols[lastNonEmpty].length === 0) lastNonEmpty--;
    const activeCols = cols.slice(0, lastNonEmpty + 1);

    state.renderedNodes = [];

    const colsHtml = activeCols.map((items, colIdx) => {
      const absLevel = baseDepth + colIdx;
      const headTitle = (isRoot && colIdx === 0) ? 'L0 · Disk' : `L${absLevel}`;

      const blocksHtml = items.map(item => {
        const idx = state.renderedNodes.length;
        state.renderedNodes.push(item);
        const n = item.node;
        const isFree = !!n.isFree;
        const isGap = !!n.isSystemGap;
        const clickable = !isFree && !isGap && !n.isGrouped && n.isDir;
        const baseOpacity = isFree ? 1 : Math.max(0.42, 0.96 - colIdx * 0.042);

        const showTitle = item.h >= 20;
        const showSub = item.h >= 36;
        const showHintLine = !!(n.hint && item.h >= 54);
        const showHintDot = !!(n.hint && showTitle && !showHintLine);
        const pct = ((n.size / scaleBytes) * 100).toFixed(1);
        const gap = item.h >= 10 ? 3 : item.h >= 5 ? 2 : 1;
        const blockH = Math.max(item.h - gap, 1.5);
        const radius = blockH >= 20 ? 7 : blockH >= 11 ? 4 : blockH >= 5 ? 2.5 : 1;
        const cacheCls = item.inRebuilds ? 'cache-rebuilds' : '';

        return `
          <div
            class="icicle-block ${clickable ? 'clickable' : ''} ${isFree ? 'free-space' : ''} ${isGap ? 'system-gap' : ''} ${cacheCls}"
            data-idx="${idx}"
            data-path="${escapeHtml(n.path)}"
            data-base-opacity="${baseOpacity}"
            style="top:${item.y}px; height:${blockH}px; border-radius:${radius}px; background:${item.color}; opacity:${baseOpacity};"
          >
            ${showTitle ? `<div class="icicle-block-title-row">${showHintDot ? `<span class="hint-dot ${escapeHtml(n.hint.safety)}"></span>` : ''}<div class="icicle-block-title">${escapeHtml(n.name)}</div></div>` : ''}
            ${showSub ? `<div class="icicle-block-sub">${fmtBytes(n.size)} · ${pct}%</div>` : ''}
            ${showHintLine ? `<div class="icicle-block-hint"><span class="icicle-block-hint-tag ${escapeHtml(n.hint.safety)}">${escapeHtml(n.hint.tag)}</span><span>${escapeHtml(n.hint.label)}</span></div>` : ''}
          </div>
        `;
      }).join('');

      return `
        <div class="icicle-col">
          <div class="icicle-col-head">
            <span>${headTitle}</span>
            <span style="opacity:0.6">${items.length}</span>
          </div>
          <div class="icicle-col-body" style="height:${totalH}px;">
            ${blocksHtml}
          </div>
        </div>
      `;
    }).join('');

    const modeCls = state.layoutMode === 'scroll' ? 'mode-scroll' : 'mode-fit';
    elViewport.innerHTML = `<div class="icicle-wrap ${modeCls}">${colsHtml}</div>`;
    applyDefaultBlockStyles();

    // Attach fast event delegation on the container
    const wrap = elViewport.querySelector('.icicle-wrap');
    wrap.addEventListener('mouseover', (e) => {
      const blk = e.target.closest('.icicle-block');
      if (!blk) return;
      highlightLineage(Number(blk.dataset.idx), e.clientX, e.clientY);
    });
    wrap.addEventListener('mousemove', (e) => {
      if (!elHoverTooltip.classList.contains('hidden')) {
        positionTooltip(e.clientX, e.clientY);
      }
    });
    wrap.addEventListener('mouseleave', () => highlightLineage(-1));
    wrap.addEventListener('click', (e) => {
      const blk = e.target.closest('.icicle-block');
      if (!blk) return;
      elHoverTooltip.classList.add('hidden');
      const item = state.renderedNodes[Number(blk.dataset.idx)];
      if (!item || !item.node.isDir || item.node.isFree || item.node.isSystemGap || item.node.isGrouped) return;
      loadTree(td.volumeId, item.node.path);
    });
    wrap.addEventListener('contextmenu', (e) => {
      const blk = e.target.closest('.icicle-block');
      if (!blk) return;
      e.preventDefault();
      elHoverTooltip.classList.add('hidden');
      const item = state.renderedNodes[Number(blk.dataset.idx)];
      if (item) {
        openContextMenu(e.clientX, e.clientY, item);
      }
    });
  }

  function positionTooltip(x, y) {
    const pad = 14;
    const tw = elHoverTooltip.offsetWidth || 260;
    const th = elHoverTooltip.offsetHeight || 54;
    let left = x + pad;
    let top = y + pad;
    if (left + tw > window.innerWidth - 10) left = x - tw - pad;
    if (top + th > window.innerHeight - 10) top = y - th - pad;
    elHoverTooltip.style.left = Math.max(8, left) + 'px';
    elHoverTooltip.style.top = Math.max(8, top) + 'px';
  }

  function applyDefaultBlockStyles() {
    const blocks = elViewport.querySelectorAll('.icicle-block');
    blocks.forEach(el => {
      if (state.highlightRebuildsOnly) {
        if (el.classList.contains('cache-rebuilds')) {
          el.style.opacity = '1';
          el.style.borderColor = 'rgba(167, 243, 208, 0.85)';
          el.style.boxShadow = '0 0 0 1px rgba(16, 185, 129, 0.45)';
          el.style.zIndex = '4';
        } else {
          el.style.opacity = '0.15';
          el.style.borderColor = '';
          el.style.boxShadow = 'none';
          el.style.zIndex = '1';
        }
      } else {
        el.style.opacity = el.dataset.baseOpacity;
        el.style.boxShadow = 'none';
        el.style.borderColor = '';
        el.style.zIndex = '';
      }
    });
  }

  function highlightLineage(idx, clientX, clientY) {
    const blocks = elViewport.querySelectorAll('.icicle-block');
    if (idx < 0 || !state.renderedNodes[idx]) {
      applyDefaultBlockStyles();
      elHoverTooltip.classList.add('hidden');
      return;
    }

    const item = state.renderedNodes[idx];
    const targetPath = item.node.path;
    const isFree = !!item.node.isFree;
    const ancestorSet = new Set(item.ancestorPaths);

    blocks.forEach(el => {
      const p = el.dataset.path;
      const isSelf = p === targetPath;
      const isAnc = ancestorSet.has(p);
      const isDesc = !isFree && !item.node.isSystemGap && (
        (targetPath === '/' && p.startsWith('/') && p !== '/' && !p.includes('(available)')) ||
        (targetPath !== '/' && p.startsWith(targetPath + '/'))
      );

      if (isSelf) {
        el.style.opacity = '1';
        el.style.borderColor = 'rgba(214, 235, 253, 0.95)';
        el.style.boxShadow = '0 0 0 1px rgba(214, 235, 253, 0.65)';
        el.style.zIndex = '10';
      } else if (isAnc || isDesc) {
        el.style.opacity = '0.96';
        el.style.borderColor = 'rgba(255, 255, 255, 0.25)';
        el.style.boxShadow = 'none';
        el.style.zIndex = '2';
      } else {
        el.style.opacity = '0.16';
        el.style.borderColor = '';
        el.style.boxShadow = 'none';
        el.style.zIndex = '1';
      }
    });

    const td = state.treeData;
    const pctUsed = td.usedBytes > 0 ? ((item.node.size / td.usedBytes) * 100).toFixed(1) : '0';
    const pctDisk = td.totalBytes > 0 ? ((item.node.size / td.totalBytes) * 100).toFixed(1) : '0';
    const hint = item.node.hint;
    const hintBlock = hint ? `
      <div class="hover-tooltip-hint">
        <span class="hover-tooltip-label">${escapeHtml(hint.label)}</span>
        <span class="hint-pill ${escapeHtml(hint.safety)}">${escapeHtml(hint.tag)}</span>
      </div>
      ${hint.description ? `<div class="hover-tooltip-desc">${escapeHtml(hint.description)}</div>` : ''}
    ` : '';
    elHoverTooltip.innerHTML = `
      ${hintBlock}
      <div class="hover-tooltip-path">L${item.absDepth} · ${escapeHtml(targetPath)}</div>
      <div class="hover-tooltip-meta">
        <span><strong>${fmtBytes(item.node.size)}</strong></span>
        <span>${pctUsed}% used (${pctDisk}% disk)</span>
        ${item.node.files ? `<span>${fmtNum(item.node.files)} files</span>` : ''}
      </div>
    `;
    elHoverTooltip.classList.remove('hidden');
    if (typeof clientX === 'number' && typeof clientY === 'number') {
      positionTooltip(clientX, clientY);
    }
  }

  function renderAll() {
    renderToolbar();
    renderBreadcrumbs();
    if (state.viewMode === 'icicle' && state.treeData) {
      renderIcicle();
    } else {
      renderOverview();
    }
    renderFooterDefault();
  }

  // ---- Wire Controls ----
  elBtnHome.addEventListener('click', () => {
    state.viewMode = 'overview';
    renderAll();
  });

  elBtnScan.addEventListener('click', () => {
    const vol = getSelectedVolume();
    if (vol) startScan(vol.id);
  });

  elBtnCancel.addEventListener('click', cancelScan);

  elBtnReveal.addEventListener('click', () => {
    if (state.treeData && state.treeData.root) {
      revealInFinder(state.treeData.root.path);
    }
  });

  elBtnTrash.addEventListener('click', () => {
    if (state.treeData && state.treeData.root) {
      moveToTrash(state.treeData.volumeId, state.treeData.root.path);
    }
  });

  elBtnUndo.addEventListener('click', undoTrash);

  document.addEventListener('click', (e) => {
    if (!elContextMenu.classList.contains('hidden') && !elContextMenu.contains(e.target)) {
      closeContextMenu();
    }
  });

  document.addEventListener('keydown', (e) => {
    if (e.key === 'Escape') {
      closeContextMenu();
    } else if ((e.metaKey || e.ctrlKey) && !e.shiftKey && e.key.toLowerCase() === 'z') {
      if (state.undoCount > 0) {
        e.preventDefault();
        undoTrash();
      }
    } else if (state.viewMode === 'icicle' && (e.metaKey || e.ctrlKey)) {
      if (e.key === '=' || e.key === '+') {
        e.preventDefault();
        applyZoomMultiplier(1.35);
      } else if (e.key === '-') {
        e.preventDefault();
        applyZoomMultiplier(1 / 1.35);
      } else if (e.key === '0') {
        e.preventDefault();
        scheduleVerticalZoom(1);
      }
    }
  });

  if (elBtnZoomReset) {
    elBtnZoomReset.addEventListener('click', () => {
      scheduleVerticalZoom(1);
    });
  }

  // Native macOS WKWebView trackpad magnifyWithEvent: bridge (continuous vertical-only zoom)
  window.__xnkMagnify = (delta, clientY) => {
    if (state.viewMode !== 'icicle' || !state.treeData) return;
    if (typeof delta !== 'number' || !Number.isFinite(delta) || delta === 0) return;
    const factor = Math.exp(delta * 2.0);
    applyZoomMultiplier(factor, clientY);
  };

  // Cross-browser fallback for Ctrl+wheel / trackpad pinch when opened outside native WKWebView
  elViewport.addEventListener('wheel', (e) => {
    if (!e.ctrlKey || state.viewMode !== 'icicle') return;
    e.preventDefault();
    const factor = Math.exp(-e.deltaY * 0.015);
    applyZoomMultiplier(factor, e.clientY);
  }, { passive: false });

  elModeScroll.addEventListener('click', () => {
    state.layoutMode = 'scroll';
    renderAll();
  });

  elModeFit.addEventListener('click', () => {
    state.layoutMode = 'fit';
    renderAll();
  });

  elSelectDepth.addEventListener('change', (e) => {
    state.maxDepth = Number(e.target.value);
    if (state.viewMode === 'icicle' && state.treeData) {
      loadTree(state.treeData.volumeId, state.currentPath);
    }
  });

  elToggleGroup.addEventListener('change', (e) => {
    state.groupSmall = e.target.checked;
    if (state.viewMode === 'icicle' && state.treeData) {
      loadTree(state.treeData.volumeId, state.currentPath);
    }
  });

  if (elToggleHideFree) {
    elToggleHideFree.addEventListener('change', (e) => {
      state.hideFreeSpace = e.target.checked;
      if (state.viewMode === 'icicle' && state.treeData) {
        renderIcicle();
      }
    });
  }

  if (elToggleRebuilds) {
    elToggleRebuilds.addEventListener('change', (e) => {
      state.highlightRebuildsOnly = e.target.checked;
      applyDefaultBlockStyles();
    });
  }

  let resizeTimer = null;
  window.addEventListener('resize', () => {
    if (state.viewMode !== 'icicle') return;
    clearTimeout(resizeTimer);
    resizeTimer = setTimeout(renderIcicle, 60);
  });

  // Boot
  loadVolumes();
  loadTrashStatus();
})();
