(function () {
  'use strict';

  var $ = function (sel, root) { return (root || document).querySelector(sel); };
  var $$ = function (sel, root) { return Array.prototype.slice.call((root || document).querySelectorAll(sel)); };

  // ---------- toast ----------
  var toastEl = $('#toast');
  var toastTimer;
  function toast(msg) {
    toastEl.textContent = msg;
    toastEl.classList.add('show');
    clearTimeout(toastTimer);
    toastTimer = setTimeout(function () { toastEl.classList.remove('show'); }, 1800);
  }

  // ---------- theme ----------
  $('#themeBtn').addEventListener('click', function () {
    var root = document.documentElement;
    var current = root.getAttribute('data-theme') ||
      (window.matchMedia('(prefers-color-scheme: dark)').matches ? 'dark' : 'light');
    var next = current === 'dark' ? 'light' : 'dark';
    root.setAttribute('data-theme', next);
    try { localStorage.setItem('theme', next); } catch (e) {}
  });

  // ---------- mobile menu ----------
  var toc = $('#toc');
  var menuBtn = $('#menuBtn');
  function setMenu(open) {
    toc.classList.toggle('open', open);
    menuBtn.setAttribute('aria-expanded', String(open));
  }
  menuBtn.addEventListener('click', function () { setMenu(!toc.classList.contains('open')); });
  $$('a', toc).forEach(function (a) { a.addEventListener('click', function () { setMenu(false); }); });

  // ---------- scrollspy ----------
  var links = $$('a[href^="#"]', toc);
  var sections = links.map(function (a) { return document.getElementById(a.getAttribute('href').slice(1)); });
  if ('IntersectionObserver' in window) {
    var visible = {};
    var spy = new IntersectionObserver(function (entries) {
      entries.forEach(function (e) { visible[e.target.id] = e.isIntersecting; });
      var firstVisible = sections.find(function (s) { return s && visible[s.id]; });
      if (!firstVisible) return;
      links.forEach(function (a) {
        a.classList.toggle('active', a.getAttribute('href') === '#' + firstVisible.id);
      });
    }, { rootMargin: '-70px 0px -55% 0px' });
    sections.forEach(function (s) { if (s) spy.observe(s); });
  }

  // ---------- tabs ----------
  var tabs = $$('.tab');
  function selectTab(name, focus) {
    tabs.forEach(function (t) {
      var on = t.dataset.tab === name;
      t.setAttribute('aria-selected', String(on));
      t.tabIndex = on ? 0 : -1;
      $('#' + t.getAttribute('aria-controls')).hidden = !on;
      if (on && focus) t.focus();
    });
  }
  tabs.forEach(function (t, i) {
    t.addEventListener('click', function () { selectTab(t.dataset.tab); });
    t.addEventListener('keydown', function (e) {
      if (e.key !== 'ArrowRight' && e.key !== 'ArrowLeft') return;
      var next = tabs[(i + (e.key === 'ArrowRight' ? 1 : tabs.length - 1)) % tabs.length];
      selectTab(next.dataset.tab, true);
    });
  });
  selectTab('sqlite');
  $$('[data-open-tab]').forEach(function (a) {
    a.addEventListener('click', function () { selectTab(a.dataset.openTab); });
  });

  // ---------- table reference: search, expand, collapse ----------
  var tblList = $$('#tableList details.tbl');
  var noMatch = $('#noMatch');
  $('#tableSearch').addEventListener('input', function (e) {
    var q = e.target.value.trim().toLowerCase();
    var shown = 0;
    tblList.forEach(function (d) {
      var hit = !q || d.textContent.toLowerCase().indexOf(q) !== -1;
      d.hidden = !hit;
      if (hit) shown++;
      d.open = !!q && hit;
    });
    noMatch.hidden = shown !== 0;
  });
  $('#expandAll').addEventListener('click', function () { tblList.forEach(function (d) { if (!d.hidden) d.open = true; }); });
  $('#collapseAll').addEventListener('click', function () { tblList.forEach(function (d) { d.open = false; }); });

  // ---------- file sizes (from downloads/manifest.json, written by build_site.py) ----------
  function formatSize(bytes) {
    if (bytes < 1024) return bytes + ' B';
    if (bytes < 1024 * 1024) return Math.round(bytes / 1024) + ' KB';
    return (bytes / 1024 / 1024).toFixed(1) + ' MB';
  }
  fetch('downloads/manifest.json')
    .then(function (r) { return r.ok ? r.json() : null; })
    .then(function (m) {
      if (!m || !m.files) return;
      $$('[data-size]').forEach(function (el) {
        var f = m.files[el.dataset.size];
        if (!f) return;
        var label = formatSize(f.bytes) + (f.lines ? ' · ' + f.lines + ' lines' : '');
        if (el.classList.contains('fsize')) el.textContent = label;
        else el.appendChild(document.createTextNode(' · ' + formatSize(f.bytes)));
      });
    })
    .catch(function () { /* sizes are optional */ });

  // ---------- SQL viewer ----------
  var viewer = $('#viewer');
  var viewerCode = $('#viewerCode');
  var viewerTitle = $('#viewerTitle');
  var viewerDownload = $('#viewerDownload');
  var currentText = '';

  function openViewer(path) {
    var url = 'downloads/' + path;
    viewerTitle.textContent = path;
    viewerDownload.href = url;
    viewerCode.textContent = 'Loading…';
    currentText = '';
    if (typeof viewer.showModal === 'function') viewer.showModal(); else viewer.setAttribute('open', '');
    fetch(url)
      .then(function (r) { if (!r.ok) throw new Error(r.status); return r.text(); })
      .then(function (text) {
        currentText = text;
        if (window.hljs) {
          viewerCode.innerHTML = window.hljs.highlight(text, { language: 'sql', ignoreIllegals: true }).value;
        } else {
          viewerCode.textContent = text;
        }
      })
      .catch(function () {
        viewerCode.textContent = 'Could not load this file. If you opened index.html straight from disk, ' +
          'serve the folder with a web server (or deploy it) and try again. The Download button still works.';
      });
  }
  function closeViewer() {
    if (typeof viewer.close === 'function') viewer.close(); else viewer.removeAttribute('open');
  }

  $$('[data-view]').forEach(function (b) {
    b.addEventListener('click', function () { openViewer(b.dataset.view); });
  });
  $('#viewerClose').addEventListener('click', closeViewer);
  viewer.addEventListener('click', function (e) { if (e.target === viewer) closeViewer(); });
  $('#viewerCopy').addEventListener('click', function () {
    if (!currentText) return;
    if (navigator.clipboard && navigator.clipboard.writeText) {
      navigator.clipboard.writeText(currentText).then(
        function () { toast('Copied to clipboard'); },
        function () { toast('Copy failed: select the text instead'); });
    } else {
      toast('Copy is not available here: select the text instead');
    }
  });
})();
