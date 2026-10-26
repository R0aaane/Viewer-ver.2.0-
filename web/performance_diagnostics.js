// Opt-in, local-only diagnostics. No measurements are uploaded.
(function () {
  'use strict';
  if (new URLSearchParams(window.location.search).get('perf') !== '1') return;

  function summarize(values) {
    const sorted = values.slice().sort(function (a, b) { return a - b; });
    function percentile(fraction) {
      if (!sorted.length) return null;
      return Math.round(sorted[Math.ceil(sorted.length * fraction) - 1] * 10) / 10;
    }
    return { count: sorted.length, p50Ms: percentile(0.5), p95Ms: percentile(0.95), maxMs: percentile(1) };
  }

  function resourceGroup(name) {
    const path = new URL(name, window.location.href).pathname;
    if (/\/thumb$/.test(path)) return 'thumbnail';
    if (/\/page\/\d+$/.test(path)) return 'pdf-page';
    if (/\/download$/.test(path)) return 'download';
    if (path === '/health') return null; // Separately measured below.
    if (/\.(js|wasm|woff2?|ttf)$/.test(path)) return 'app-assets';
    return 'other';
  }

  const panel = document.createElement('div');
  panel.style.cssText = 'position:fixed;right:8px;bottom:8px;z-index:2147483647;background:#16191f;color:white;border:1px solid #aaa;border-radius:8px;padding:10px;max-width:calc(100vw - 36px);font:14px sans-serif;pointer-events:auto';
  const label = document.createElement('div');
  label.textContent = 'Safari性能診断（20秒・端末内のみ）';
  const button = document.createElement('button');
  button.textContent = '計測開始';
  button.style.cssText = 'margin-top:8px;padding:10px;touch-action:manipulation';
  const output = document.createElement('textarea');
  output.readOnly = true;
  output.setAttribute('aria-label', '性能診断結果。長押しでコピーできます');
  output.style.cssText = 'display:none;width:290px;max-width:70vw;height:140px;margin-top:8px;font-size:12px';
  const close = document.createElement('button');
  close.textContent = '閉じる';
  close.style.cssText = 'margin-left:10px;padding:10px';
  panel.append(label, button, close, output);
  document.body.appendChild(panel);

  let active = null;
  let result = null;
  let version = null;
  // This is only performed with ?perf=1, and never carries an API token.
  fetch(new URL('version.json', document.baseURI), { cache: 'no-store' })
    .then(function (response) { return response.ok ? response.json() : null; })
    .then(function (value) { version = value; }).catch(function () {});

  function finish(reason) {
    const sample = active;
    if (!sample) return;
    active = null;
    cancelAnimationFrame(sample.frame);
    clearTimeout(sample.endTimer);
    clearTimeout(sample.healthTimer);
    if (sample.healthController) sample.healthController.abort();
    if (sample.observer) sample.observer.disconnect();
    const end = performance.now();
    const resources = {};
    performance.getEntriesByType('resource').forEach(function (entry) {
      if (entry.startTime < sample.start || entry.responseEnd > end) return;
      const group = resourceGroup(entry.name);
      if (group) (resources[group] || (resources[group] = [])).push(entry.duration);
    });
    const resourceSummary = {};
    Object.keys(resources).forEach(function (group) { resourceSummary[group] = summarize(resources[group]); });
    result = {
      format: 1, reason: reason, version: version,
      startedAt: sample.startedAt, finishedAt: new Date().toISOString(),
      userAgent: navigator.userAgent, devicePixelRatio: window.devicePixelRatio,
      viewport: { width: window.innerWidth, height: window.innerHeight },
      durationMs: Math.round(end - sample.start),
      frames: summarize(sample.frames),
      framesOver50Ms: sample.frames.filter(function (ms) { return ms > 50; }).length,
      slowFrames: sample.slowFrames,
      longTasksSupported: sample.longTasksSupported,
      longTasks: summarize(sample.longTasks),
      health: summarize(sample.health), healthErrors: sample.healthErrors,
      healthSamples: sample.healthSamples,
      resources: resourceSummary,
      note: 'Frame intervals measure scheduling delays, not GPU time or host CPU. Resource timings may include network queueing. No file names, IDs, tokens or resource URLs are included.'
    };
    output.value = JSON.stringify(result, null, 2);
    output.style.display = 'block';
    label.textContent = '完了：結果欄を長押ししてコピー';
    button.textContent = '再計測';
  }

  function start() {
    if (active) { finish('manual'); return; }
    output.style.display = 'none';
    const sample = {
      start: performance.now(), startedAt: new Date().toISOString(),
      frames: [], lastFrame: null, slowFrames: [],
      longTasks: [], health: [], healthErrors: [], healthSamples: [],
      longTasksSupported: typeof PerformanceObserver !== 'undefined' &&
        (PerformanceObserver.supportedEntryTypes || []).includes('longtask')
    };
    active = sample;
    label.textContent = '計測中：サイドバー・スクロール・画面移動を操作';
    button.textContent = '計測終了';
    function frame(timestamp) {
      if (active !== sample) return;
      if (sample.lastFrame !== null) {
        const gap = timestamp - sample.lastFrame;
        sample.frames.push(gap);
        if (gap > 50 && sample.slowFrames.length < 200) {
          sample.slowFrames.push({ atMs: Math.round(sample.lastFrame - sample.start), durationMs: Math.round(gap) });
        }
      }
      sample.lastFrame = timestamp;
      sample.frame = requestAnimationFrame(frame);
    }
    sample.frame = requestAnimationFrame(frame);
    if (sample.longTasksSupported) {
      sample.observer = new PerformanceObserver(function (list) {
        list.getEntries().forEach(function (entry) { sample.longTasks.push(entry.duration); });
      });
      sample.observer.observe({ entryTypes: ['longtask'] });
    }
    async function health() {
      if (active !== sample) return;
      const before = performance.now();
      const controller = new AbortController();
      sample.healthController = controller;
      const timeout = setTimeout(function () { controller.abort(); }, 3000);
      try {
        const response = await fetch(new URL('health', document.baseURI), { cache: 'no-store', signal: controller.signal });
        await response.arrayBuffer();
        if (active === sample) {
          if (response.ok) {
            const duration = performance.now() - before;
            sample.health.push(duration);
            sample.healthSamples.push({ atMs: Math.round(before - sample.start), durationMs: Math.round(duration) });
          } else sample.healthErrors.push({ atMs: Math.round(before - sample.start), status: response.status });
        }
      } catch (_) {
        if (active === sample) sample.healthErrors.push({ atMs: Math.round(before - sample.start), status: 'timeout-or-network-error' });
      } finally {
        clearTimeout(timeout);
        if (active === sample) sample.healthTimer = setTimeout(health, 1000);
      }
    }
    health();
    sample.endTimer = setTimeout(function () { finish('complete'); }, 20000);
  }
  button.addEventListener('click', start);
  close.addEventListener('click', function () { finish('closed'); panel.remove(); });
  document.addEventListener('visibilitychange', function () {
    if (document.hidden) finish('tab-hidden');
  });
})();
