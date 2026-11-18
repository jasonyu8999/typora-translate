/*
 * Typora Translate — Typora integration
 * =====================================================================
 * Adds, for the currently selected text:
 *   - a "翻译成中文 / 翻译成英文" item in Typora's right-click menu,
 *   - a floating translation panel (copy / replace / retry / settings),
 *   - a configurable hotkey (default Ctrl+Shift+T; with no selection it
 *     translates the block under the cursor).
 *
 * Environment notes (Typora 1.12.x, Electron 35):
 *   - window.require is undefined; window.reqnode(name) gives Node modules.
 *   - Typora's context menus are DOM: <ul class="dropdown-menu context-menu">
 *     with <li data-key> items; menus are shown by Typora's own frame.js.
 *   - The editor lives in the same document (#write, contenteditable);
 *     source mode uses CodeMirror via File.editor.sourceView.cm.
 *
 * The translation engine itself lives in service.js (window.TyTranslateService).
 * This file must never throw uncaught: a broken plugin must not break Typora.
 */
(function () {
  'use strict';

  var NS = (window.TyporaTranslate = window.TyporaTranslate || {});
  var VERSION = window.__TY_TRANSLATE_VERSION__ || '1.0.0';
  var BASE = window.__TY_TRANSLATE_BASE__ || './plugin/typora-translate/';

  /* ===================================================================
   * 1. Node bridge, paths, logging, status file
   * =================================================================== */

  function nodeRequire(name) {
    try {
      if (window.reqnode) return window.reqnode(name);
    } catch (e) {}
    try {
      // Only available in dev/Node context, not inside Typora.
      if (typeof require === 'function') return require(name);
    } catch (e) {}
    return null;
  }

  var fs = nodeRequire('fs');
  var path = nodeRequire('path');
  var os = nodeRequire('os');
  var electron = nodeRequire('electron');
  var hasNode = !!(fs && path);

  var APP_DIR = '';
  var CONFIG_PATH = '';
  var LOG_PATH = '';
  var STATUS_PATH = '';
  var LOG_MAX_BYTES = 512 * 1024;

  function initPaths() {
    if (!hasNode) return;
    try {
      var appData = (typeof process !== 'undefined' && process.env && process.env.APPDATA) || '';
      if (!appData) appData = path.join(os.homedir(), 'AppData', 'Roaming');
      APP_DIR = path.join(appData, 'Typora', 'typora-translate');
      fs.mkdirSync(APP_DIR, { recursive: true });
      CONFIG_PATH = path.join(APP_DIR, 'config.json');
      LOG_PATH = path.join(APP_DIR, 'plugin.log');
      STATUS_PATH = path.join(APP_DIR, 'status.json');
    } catch (e) {
      APP_DIR = '';
    }
  }

  function log(level, message, extra) {
    var line = new Date().toISOString() + ' [' + String(level).toUpperCase() + '] ' + message;
    if (extra !== undefined && extra !== null) {
      try {
        line += ' ' + (typeof extra === 'string' ? extra : JSON.stringify(extra));
      } catch (e) {}
    }
    try {
      console.log('[typora-translate] ' + line);
    } catch (e) {}
    if (!hasNode || !LOG_PATH) return;
    try {
      try {
        var st = fs.statSync(LOG_PATH);
        if (st.size > LOG_MAX_BYTES) {
          try {
            fs.unlinkSync(LOG_PATH + '.1');
          } catch (e) {}
          fs.renameSync(LOG_PATH, LOG_PATH + '.1');
        }
      } catch (e) {}
      fs.appendFileSync(LOG_PATH, line + '\n', 'utf8');
    } catch (e) {}
  }

  var status = {
    version: VERSION,
    booted: false,
    bootAt: null,
    typoraVersion: '',
    menus: { rich: false, source: false },
    lastSelection: null,
    lastTranslate: null,
    lastError: null,
  };

  function writeStatus(patch) {
    if (patch) {
      Object.keys(patch).forEach(function (k) {
        status[k] = patch[k];
      });
    }
    if (!hasNode || !STATUS_PATH) return;
    try {
      status.updatedAt = new Date().toISOString();
      fs.writeFileSync(STATUS_PATH, JSON.stringify(status, null, 2), 'utf8');
    } catch (e) {}
  }

  function recordError(where, err) {
    var msg = where + ': ' + (err && err.message ? err.message : String(err));
    status.lastError = { at: new Date().toISOString(), message: msg };
    log('error', '[ERROR] ' + msg);
    writeStatus();
  }

  /* ===================================================================
   * 2. Configuration
   * =================================================================== */

  var DEFAULT_CONFIG = {
    enabled: true,
    providers: ['bing', 'mymemory'],
    targetLang: 'auto', // 'auto' | 'zh-Hans' | 'en'
    shortcut: 'Ctrl+Shift+T',
    panelWidth: 480,
    lookupWords: true,
    maxChars: 20000,
    language: 'auto', // 'auto' | 'zh' | 'en'
    logLevel: 'info',
    llm: {
      enabled: false,
      baseUrl: 'https://api.deepseek.com/v1',
      apiKey: '',
      model: 'deepseek-chat',
    },
  };

  function deepMerge(base, override) {
    var out = {};
    Object.keys(base).forEach(function (k) {
      out[k] = base[k];
    });
    if (!override || typeof override !== 'object') return out;
    Object.keys(override).forEach(function (k) {
      var v = override[k];
      if (v && typeof v === 'object' && !Array.isArray(v) && base[k] && typeof base[k] === 'object' && !Array.isArray(base[k])) {
        out[k] = deepMerge(base[k], v);
      } else if (v !== undefined) {
        out[k] = v;
      }
    });
    return out;
  }

  var config = deepMerge(DEFAULT_CONFIG, null);
  var configMtime = 0;

  function loadConfig(force) {
    if (!hasNode || !CONFIG_PATH) return config;
    try {
      var mtime = 0;
      try {
        mtime = fs.statSync(CONFIG_PATH).mtimeMs;
      } catch (e) {
        mtime = 0;
      }
      if (!force && mtime === configMtime) return config;
      if (!mtime) {
        // first run: materialize the default config so users can edit it
        fs.writeFileSync(CONFIG_PATH, JSON.stringify(DEFAULT_CONFIG, null, 2), 'utf8');
        configMtime = 0;
        config = deepMerge(DEFAULT_CONFIG, null);
        log('info', '[CONFIG] created default config at ' + CONFIG_PATH);
        return config;
      }
      var raw = fs.readFileSync(CONFIG_PATH, 'utf8');
      var parsed = JSON.parse(raw.replace(/^\uFEFF/, ''));
      config = deepMerge(DEFAULT_CONFIG, parsed);
      configMtime = mtime;
      log('info', '[CONFIG] loaded ' + CONFIG_PATH);
    } catch (e) {
      log('error', '[CONFIG] failed to load, using defaults: ' + (e && e.message));
    }
    return config;
  }

  /* ===================================================================
   * 3. Small helpers (i18n, DOM, theme)
   * =================================================================== */

  function lang() {
    var l = String(config.language || 'auto').toLowerCase();
    if (l === 'zh' || l === 'en') return l;
    var nav = String((navigator && navigator.language) || '').toLowerCase();
    var htmlLang = String((document.documentElement && document.documentElement.lang) || '').toLowerCase();
    if (nav.indexOf('zh') === 0 || htmlLang.indexOf('zh') === 0) return 'zh';
    return 'en';
  }

  var STRINGS = {
    zh: {
      translateToZh: '翻译成中文',
      translateToEn: '翻译成英文',
      translate: '翻译',
      title: '翻译',
      loading: '正在翻译…',
      copy: '复制',
      copied: '已复制译文',
      replace: '替换',
      replaced: '已替换选中文本',
      retry: '重试',
      settings: '设置',
      close: '关闭',
      copyFailed: '复制失败',
      replaceFailed: '替换失败，已改为复制到剪贴板',
      emptySelection: '请先选中要翻译的文本',
      disabled: '插件已在配置中停用（enabled: false）',
      tooLong: '选中内容过长，已截取前 {n} 个字符',
      noService: '翻译服务未加载（service.js 缺失）',
      errorPrefix: '翻译失败',
      hint: '请检查网络，或在设置中更换翻译服务',
      provideBy: '由 {p} 提供',
      dictTitle: '词典释义',
      machineTitle: '机器翻译',
      noText: '没有可翻译的内容',
      sourceZh: '中文',
      sourceEn: '英文',
      sourceAuto: '自动',
      openConfigFailed: '无法打开配置文件，路径已复制到剪贴板',
    },
    en: {
      translateToZh: 'Translate to Chinese',
      translateToEn: 'Translate to English',
      translate: 'Translate',
      title: 'Translate',
      loading: 'Translating…',
      copy: 'Copy',
      copied: 'Translation copied',
      replace: 'Replace',
      replaced: 'Selection replaced',
      retry: 'Retry',
      settings: 'Settings',
      close: 'Close',
      copyFailed: 'Copy failed',
      replaceFailed: 'Replace failed — copied to clipboard instead',
      emptySelection: 'Select some text first',
      disabled: 'Plugin is disabled in config.json (enabled: false)',
      tooLong: 'Selection too long — truncated to {n} characters',
      noService: 'Translation service is not loaded (service.js missing)',
      errorPrefix: 'Translation failed',
      hint: 'Check your network, or change providers in settings.',
      provideBy: 'via {p}',
      dictTitle: 'Dictionary',
      machineTitle: 'Machine translation',
      noText: 'Nothing to translate',
      sourceZh: 'Chinese',
      sourceEn: 'English',
      sourceAuto: 'Auto',
      openConfigFailed: 'Could not open config file; its path was copied to the clipboard',
    },
  };

  function t(key, vars) {
    var table = STRINGS[lang()] || STRINGS.zh;
    var s = table[key] || STRINGS.zh[key] || key;
    if (vars) {
      Object.keys(vars).forEach(function (k) {
        s = s.replace(new RegExp('\\{' + k + '\\}', 'g'), String(vars[k]));
      });
    }
    return s;
  }

  function el(tag, attrs, children) {
    var node = document.createElement(tag);
    if (attrs) {
      Object.keys(attrs).forEach(function (k) {
        if (k === 'className') node.className = attrs[k];
        else if (k === 'text') node.textContent = attrs[k];
        else if (k === 'style') node.setAttribute('style', attrs[k]);
        else node.setAttribute(k, attrs[k]);
      });
    }
    (children || []).forEach(function (c) {
      if (c) node.appendChild(typeof c === 'string' ? document.createTextNode(c) : c);
    });
    return node;
  }

  function clamp(n, lo, hi) {
    return Math.max(lo, Math.min(hi, n));
  }

  function isDarkTheme() {
    try {
      var probes = [document.body, document.documentElement, document.getElementById('write')];
      for (var i = 0; i < probes.length; i++) {
        var node = probes[i];
        if (!node) continue;
        var bg = getComputedStyle(node).backgroundColor || '';
        var m = bg.match(/rgba?\(([^)]+)\)/);
        if (!m) continue;
        var parts = m[1].split(',').map(function (x) {
          return parseFloat(x);
        });
        if (parts.length < 3) continue;
        var alpha = parts.length >= 4 ? parts[3] : 1;
        if (alpha < 0.2) continue;
        var lum = (0.299 * parts[0] + 0.587 * parts[1] + 0.114 * parts[2]) / 255;
        return lum < 0.5;
      }
    } catch (e) {}
    return false;
  }

  /* ===================================================================
   * 4. Translation service
   * =================================================================== */

  var service = null;
  var serviceConfigMtime = null;
  // Generation counter: every user-initiated translation bumps it, and all
  // async callbacks must verify they still own the latest operation before
  // touching the panel/status (prevents a slow response overwriting a newer one).
  var opSeq = 0;

  function getService() {
    loadConfig();
    if (service && serviceConfigMtime !== configMtime) {
      // engine-relevant config changed (providers / llm / timeouts...): rebuild
      service = null;
      log('info', '[CONFIG] engine config changed, recreating translation service');
    }
    if (service) return service;
    var factory = window.TyTranslateService;
    if (!factory || typeof factory.createService !== 'function') {
      throw new Error(t('noService'));
    }
    service = factory.createService({
      appName: 'typora-translate',
      config: loadConfig(),
      log: function (level, msg, extra) {
        log(level || 'info', '[SVC] ' + msg, extra);
      },
    });
    serviceConfigMtime = configMtime;
    return service;
  }

  function resetService() {
    service = null;
  }

  function containsCJK(text) {
    var m = String(text || '').match(/[\u3400-\u4dbf\u4e00-\u9fff\uf900-\ufaff]/g);
    return m ? m.length : 0;
  }

  function looksChinese(text) {
    var s = String(text || '');
    if (!s) return false;
    var cjk = containsCJK(s);
    var latin = (s.match(/[A-Za-z]/g) || []).length;
    return cjk > 0 && cjk >= latin * 0.2;
  }

  // Decide translation direction for the given text.
  function resolveDirection(text) {
    var explicit = String(config.targetLang || 'auto').toLowerCase();
    if (explicit === 'zh' || explicit === 'zh-hans' || explicit === 'zh-hant' || explicit === 'zh-cn') {
      return { target: 'zh-Hans', source: looksChinese(text) ? 'zh' : 'en' };
    }
    if (explicit === 'en') {
      return { target: 'en', source: looksChinese(text) ? 'zh' : 'en' };
    }
    // auto: English -> Chinese, Chinese -> English
    if (looksChinese(text)) return { target: 'en', source: 'zh' };
    return { target: 'zh-Hans', source: 'en' };
  }

  /* ===================================================================
   * 5. Selection snapshots
   * =================================================================== */

  function editorState() {
    var ed = window.File && window.File.editor;
    var inSource = !!(ed && ed.sourceView && ed.sourceView.inSourceMode);
    return { editor: ed, inSource: inSource, cm: inSource && ed.sourceView ? ed.sourceView.cm : null };
  }

  function normalizeText(text) {
    var s = String(text == null ? '' : text);
    s = s.replace(/\u00a0/g, ' ').replace(/\r\n?/g, '\n');
    s = s.replace(/[ \t]+\n/g, '\n').replace(/\n{3,}/g, '\n\n');
    return s.trim();
  }

  function truncateText(text) {
    var max = parseInt(config.maxChars, 10) || 20000;
    if (text.length <= max) return { text: text, truncated: false };
    var cut = text.slice(0, max);
    var boundary = Math.max(cut.lastIndexOf('. '), cut.lastIndexOf('。'), cut.lastIndexOf('\n'), cut.lastIndexOf('; '));
    if (boundary > max * 0.6) cut = cut.slice(0, boundary + 1);
    return { text: cut, truncated: true };
  }

  // Snapshot the current selection (rich mode DOM selection or source-mode CM).
  function snapshotSelection(evt) {
    var st = editorState();
    var snap = {
      at: Date.now(),
      mode: st.inSource ? 'source' : 'rich',
      text: '',
      rect: null,
      range: null,
      cmFrom: null,
      cmTo: null,
      charCount: 0,
    };
    try {
      if (st.inSource) {
        var cm = st.cm;
        if (cm) {
          if (typeof cm.getSelection === 'function') snap.text = cm.getSelection() || '';
          if (snap.text) {
            try {
              snap.cmFrom = cm.getCursor('from');
              snap.cmTo = cm.getCursor('to');
              var coords = cm.cursorCoords(true, 'window');
              snap.rect = { left: coords.left, top: coords.top, width: 2, height: Math.max(2, (coords.bottom || coords.top + 16) - coords.top) };
            } catch (e) {}
          }
        }
      } else {
        var sel = window.getSelection();
        var write = document.getElementById('write');
        if (sel && sel.rangeCount > 0 && write) {
          var range = sel.getRangeAt(0);
          var inWrite =
            (range.startContainer && write.contains(range.startContainer)) ||
            (range.endContainer && write.contains(range.endContainer));
          if (inWrite) {
            snap.text = sel.toString();
            try {
              snap.range = range.cloneRange();
            } catch (e) {}
            try {
              var r = range.getBoundingClientRect();
              if (r && (r.width > 1 || r.height > 1)) {
                snap.rect = { left: r.left, top: r.top, width: r.width, height: r.height };
              }
            } catch (e) {}
          }
        }
      }
    } catch (e) {
      log('error', '[ERROR] snapshotSelection: ' + (e && e.message));
    }

    snap.text = normalizeText(snap.text);
    snap.charCount = snap.text.length;
    if (!snap.rect && evt && typeof evt.clientX === 'number') {
      snap.rect = { left: evt.clientX, top: evt.clientY, width: 0, height: 0 };
    }
    return snap;
  }

  // Text of the block under the cursor (hotkey with no selection).
  function snapshotCursorBlock() {
    var st = editorState();
    var snap = {
      at: Date.now(),
      mode: st.inSource ? 'source' : 'rich',
      text: '',
      rect: null,
      range: null,
      cmFrom: null,
      cmTo: null,
      charCount: 0,
    };
    try {
      if (st.inSource && st.cm) {
        var cursor = st.cm.getCursor();
        var line = st.cm.getLine(cursor.line) || '';
        snap.text = line;
        try {
          var coords = st.cm.cursorCoords(cursor, 'window');
          snap.rect = { left: coords.left, top: coords.top, width: 2, height: 18 };
        } catch (e) {}
        if (snap.text) {
          snap.cmFrom = { line: cursor.line, ch: 0 };
          snap.cmTo = { line: cursor.line, ch: line.length };
        }
      } else {
        var sel = window.getSelection();
        var node = sel && sel.anchorNode;
        if (node) {
          if (node.nodeType === 3) node = node.parentElement;
          var block = node && node.closest ? node.closest('[cid]') : null;
          if (block) {
            snap.text = block.textContent || '';
            try {
              var r = block.getBoundingClientRect();
              snap.rect = { left: r.left, top: r.top, width: r.width, height: r.height };
              var range = document.createRange();
              range.selectNodeContents(block);
              snap.range = range.cloneRange();
            } catch (e) {}
          }
        }
      }
    } catch (e) {
      log('error', '[ERROR] snapshotCursorBlock: ' + (e && e.message));
    }
    snap.text = normalizeText(snap.text);
    snap.charCount = snap.text.length;
    return snap;
  }

  function isSingleWord(text) {
    var s = String(text || '').trim();
    return s.length > 0 && s.length <= 40 && /^[A-Za-z][A-Za-z'’\-]*$/.test(s);
  }

  /* ===================================================================
   * 6. Context menu integration
   * =================================================================== */

  var MENU_GROUP = 'ty-translate';
  var MENU_KEY = 'ty-translate';
  var RICH_MENU_ID = 'context-menu';
  var SOURCE_MENU_ID = 'context-menu-for-source';

  var lastSnapshot = null;

  function createMenuNodes() {
    var divider = el('li', {
      className: 'divider',
      'data-group': MENU_GROUP,
      'aria-hidden': 'true',
    });
    divider.style.display = 'none';
    var li = el('li', { 'data-group': MENU_GROUP, 'data-key': MENU_KEY });
    li.style.display = 'none';
    var a = el('a', { role: 'menuitem' });
    var label = el('span', { className: 'ty-translate-menu-label', text: t('translate') });
    var hint = el('span', { className: 'ty-menu-shortcut', text: config.shortcut || '' });
    a.appendChild(label);
    a.appendChild(hint);
    li.appendChild(a);
    return { divider: divider, item: li, label: label };
  }

  var menuNodes = null; // { rich: {...}, source: {...} }

  function ensureMenuItems() {
    try {
      var rich = document.getElementById(RICH_MENU_ID);
      var source = document.getElementById(SOURCE_MENU_ID);
      if (!menuNodes) menuNodes = {};

      if (rich && (!menuNodes.rich || !rich.contains(menuNodes.rich.item))) {
        if (!rich.querySelector('li[data-key="' + MENU_KEY + '"]')) {
          var nodes = createMenuNodes();
          var placeholder = document.getElementById('search-service-placeholder');
          var ref = placeholder && placeholder.parentNode === rich ? placeholder : null;
          if (ref) {
            ref.parentNode.insertBefore(nodes.divider, ref.nextSibling);
            ref.parentNode.insertBefore(nodes.item, nodes.divider.nextSibling);
          } else {
            rich.appendChild(nodes.divider);
            rich.appendChild(nodes.item);
          }
          menuNodes.rich = nodes;
        }
      }
      if (source && (!menuNodes.source || !source.contains(menuNodes.source.item))) {
        if (!source.querySelector('li[data-key="' + MENU_KEY + '"]')) {
          var snodes = createMenuNodes();
          source.appendChild(snodes.divider);
          source.appendChild(snodes.item);
          menuNodes.source = snodes;
        }
      }
      var okRich = !!(menuNodes.rich && rich && rich.contains(menuNodes.rich.item));
      var okSource = !!(menuNodes.source && source && source.contains(menuNodes.source.item));
      if (status.menus.rich !== okRich || status.menus.source !== okSource) {
        writeStatus({ menus: { rich: okRich, source: okSource } });
        log('info', '[MENU] inserted rich=' + okRich + ' source=' + okSource);
      }
      return { rich: okRich, source: okSource };
    } catch (e) {
      recordError('ensureMenuItems', e);
      return { rich: false, source: false };
    }
  }

  function updateMenuForSnapshot(snap) {
    try {
      var editable = !!(snap && snap.charCount > 0);
      var dir = editable ? resolveDirection(snap.text) : null;
      ['rich', 'source'].forEach(function (kind) {
        var nodes = menuNodes && menuNodes[kind];
        if (!nodes) return;
        if (nodes.divider) nodes.divider.style.display = editable ? '' : 'none';
        nodes.item.style.display = editable ? '' : 'none';
        if (editable && nodes.label) {
          nodes.label.textContent = dir.target === 'en' ? t('translateToEn') : t('translateToZh');
        }
        var hint = nodes.item.querySelector('.ty-menu-shortcut');
        if (hint) hint.textContent = config.shortcut || '';
      });
      if (editable) {
        lastSnapshot = snap;
        writeStatus({
          lastSelection: {
            at: new Date().toISOString(),
            mode: snap.mode,
            textLen: snap.charCount,
            preview: snap.text.slice(0, 160),
          },
        });
        log('info', '[MENU] show mode=' + snap.mode + ' len=' + snap.charCount);
        // Dev diagnostics: expose where the menu item was rendered, so the
        // end-to-end harness can click the real item with the mouse.
        // Typora shows the menu asynchronously, so poll briefly for layout.
        var nodesForRect = snap.mode === 'source' ? menuNodes && menuNodes.source : menuNodes && menuNodes.rich;
        var rectTries = 0;
        (function pollItemRect() {
          try {
            var li = nodesForRect && nodesForRect.item;
            if (li && li.offsetParent) {
              var r = li.getBoundingClientRect();
              if (r.width > 0 && r.height > 0) {
                log(
                  'info',
                  '[MENU] itemRect x=' + Math.round(r.left) + ' y=' + Math.round(r.top) + ' w=' + Math.round(r.width) + ' h=' + Math.round(r.height) +
                    ' win=' + window.innerWidth + 'x' + window.innerHeight
                );
                return;
              }
            }
          } catch (e) {}
          if (++rectTries < 20) setTimeout(pollItemRect, 60);
        })();
      }
    } catch (e) {
      recordError('updateMenuForSnapshot', e);
    }
  }

  function hideAllMenus() {
    try {
      if (window.File && File.editor && File.editor.contextMenu && typeof File.editor.contextMenu.hide === 'function') {
        File.editor.contextMenu.hide();
      }
    } catch (e) {}
    try {
      var shown = document.querySelectorAll('ul.context-menu.show');
      for (var i = 0; i < shown.length; i++) shown[i].classList.remove('show');
    } catch (e) {}
  }

  function onContextMenuCapture(evt) {
    try {
      var snap = snapshotSelection(evt);
      updateMenuForSnapshot(snap);
    } catch (e) {
      recordError('onContextMenuCapture', e);
    }
  }

  function onClickCapture(evt) {
    try {
      var target = evt.target;
      if (!target || !target.closest) return;
      var item = target.closest('li[data-key="' + MENU_KEY + '"]');
      if (!item) return;
      evt.preventDefault();
      evt.stopPropagation();
      evt.stopImmediatePropagation && evt.stopImmediatePropagation();
      hideAllMenus();
      var snap = lastSnapshot && lastSnapshot.charCount ? lastSnapshot : snapshotSelection(evt);
      translateSnapshot(snap);
    } catch (e) {
      recordError('onClickCapture', e);
    }
  }

  /* ===================================================================
   * 7. Floating panel
   * =================================================================== */

  var panel = null;
  var panelParts = null;
  var panelOpen = false;
  var currentTranslate = null;
  var lastPanelAnchor = null;

  function ensurePanel() {
    if (panel && document.body.contains(panel)) return panel;
    panel = el('div', {
      id: 'ty-translate-panel',
      role: 'dialog',
      'aria-label': t('title'),
    });
    panel.style.display = 'none';

    var head = el('div', { className: 'ty-translate-head' });
    var logo = el('span', { className: 'ty-translate-logo', text: '译' });
    var title = el('span', { className: 'ty-translate-title', text: t('title') });
    var meta = el('span', { className: 'ty-translate-meta', text: '' });
    var closeBtn = el('button', { className: 'ty-translate-close', type: 'button', title: t('close'), text: '×' });
    closeBtn.addEventListener('click', function (e) {
      e.preventDefault();
      e.stopPropagation();
      hidePanel();
    });
    head.appendChild(logo);
    head.appendChild(title);
    head.appendChild(meta);
    head.appendChild(closeBtn);

    var body = el('div', { className: 'ty-translate-body' });
    var sourceLine = el('div', { className: 'ty-translate-source', text: '' });
    var result = el('div', { className: 'ty-translate-result' });
    body.appendChild(sourceLine);
    body.appendChild(result);

    var foot = el('div', { className: 'ty-translate-foot' });
    var copyBtn = el('button', { className: 'ty-translate-btn', type: 'button', text: t('copy') });
    var replaceBtn = el('button', { className: 'ty-translate-btn', type: 'button', text: t('replace') });
    var retryBtn = el('button', { className: 'ty-translate-btn ty-translate-hidden', type: 'button', text: t('retry') });
    var spacer = el('span', { className: 'ty-translate-spacer' });
    var provider = el('span', { className: 'ty-translate-provider', text: '' });
    var settingsBtn = el('button', { className: 'ty-translate-icon-btn', type: 'button', title: t('settings'), text: '⚙' });

    copyBtn.addEventListener('click', function () {
      var text = currentTranslate && currentTranslate.text;
      if (text) copyText(text);
    });
    replaceBtn.addEventListener('click', function () {
      if (currentTranslate && currentTranslate.snapshot && currentTranslate.text) {
        replaceSelection(currentTranslate.snapshot, currentTranslate.text);
      }
    });
    retryBtn.addEventListener('click', function () {
      if (currentTranslate && currentTranslate.snapshot) translateSnapshot(currentTranslate.snapshot);
    });
    settingsBtn.addEventListener('click', function () {
      openConfigFile();
    });
    foot.appendChild(copyBtn);
    foot.appendChild(replaceBtn);
    foot.appendChild(retryBtn);
    foot.appendChild(spacer);
    foot.appendChild(provider);
    foot.appendChild(settingsBtn);

    panel.appendChild(head);
    panel.appendChild(body);
    panel.appendChild(foot);
    document.body.appendChild(panel);

    panelParts = {
      head: head,
      meta: meta,
      body: body,
      sourceLine: sourceLine,
      result: result,
      foot: foot,
      copyBtn: copyBtn,
      replaceBtn: replaceBtn,
      retryBtn: retryBtn,
      provider: provider,
    };
    return panel;
  }

  function panelWidth() {
    var w = parseInt(config.panelWidth, 10) || 480;
    return Math.min(w, window.innerWidth - 16);
  }

  function positionPanel(anchor) {
    if (!panel) return;
    var anchorRect = anchor || null;
    var width = panelWidth();
    panel.style.width = width + 'px';
    var rect = panel.getBoundingClientRect();
    var height = rect.height || 120;
    var left;
    var top;
    if (anchorRect && (anchorRect.width > 1 || anchorRect.height > 1)) {
      left = anchorRect.left;
      top = anchorRect.top + anchorRect.height + 8;
      if (top + height > window.innerHeight - 8) {
        top = anchorRect.top - height - 8;
      }
    } else if (anchorRect) {
      left = anchorRect.left;
      top = anchorRect.top + 14;
    } else {
      left = (window.innerWidth - width) / 2;
      top = 120;
    }
    left = clamp(left, 8, Math.max(8, window.innerWidth - width - 8));
    top = clamp(top, 8, Math.max(8, window.innerHeight - height - 8));
    panel.style.left = Math.round(left) + 'px';
    panel.style.top = Math.round(top) + 'px';
    lastPanelAnchor = anchorRect;
  }

  function setPanelTheme() {
    if (!panel) return;
    panel.classList.toggle('ty-translate-dark', isDarkTheme());
  }

  function showPanelShell(snap) {
    ensurePanel();
    setPanelTheme();
    panelOpen = true;
    panel.style.display = 'flex';
    log('info', '[UI] panel show id=ty-translate-panel mode=' + snap.mode + ' anchor=' + JSON.stringify(snap.rect || null));
    panelParts.meta.textContent = '';
    panelParts.provider.textContent = '';
    panelParts.retryBtn.classList.add('ty-translate-hidden');
    panelParts.copyBtn.disabled = true;
    panelParts.replaceBtn.disabled = true;

    var dir = resolveDirection(snap.text);
    var dirLabel = dir.target === 'en' ? t('translateToEn') : t('translateToZh');
    panelParts.meta.textContent = dirLabel;
    panelParts.sourceLine.textContent = snap.text.length > 160 ? snap.text.slice(0, 160) + '…' : snap.text;
    panelParts.body.style.display = '';
    panelParts.result.className = 'ty-translate-result';
    panelParts.result.textContent = '';
    panelParts.result.style.display = 'none';
    panelParts.result.innerHTML = '';
    // defensive: never stack spinners (a previous load may have been hidden mid-flight)
    Array.prototype.forEach.call(panelParts.body.querySelectorAll('.ty-translate-loading'), function (old) {
      if (old.parentNode) old.parentNode.removeChild(old);
    });
    var loading = el('div', { className: 'ty-translate-loading' });
    loading.appendChild(el('span', { className: 'ty-translate-spinner' }));
    loading.appendChild(el('span', { text: t('loading') }));
    panelParts.body.appendChild(loading);
    panelParts._loading = loading;

    positionPanel(snap.rect);
  }

  function clearPanelBody() {
    if (!panelParts) return;
    if (panelParts._loading && panelParts._loading.parentNode) {
      panelParts._loading.parentNode.removeChild(panelParts._loading);
    }
    panelParts._loading = null;
    panelParts.result.innerHTML = '';
    panelParts.result.textContent = '';
    panelParts.result.style.display = 'none';
  }

  function showPanelError(message, hint) {
    ensurePanel();
    log('info', '[UI] panel error ' + message + (hint ? ' | ' + hint : ''));
    clearPanelBody();
    panelParts.result.style.display = '';
    var box = el('div', { className: 'ty-translate-error' });
    box.appendChild(el('div', { text: message }));
    if (hint) box.appendChild(el('div', { className: 'ty-translate-hint', text: hint }));
    panelParts.result.appendChild(box);
    panelParts.result.className = 'ty-translate-result';
    panelParts.retryBtn.classList.remove('ty-translate-hidden');
    positionPanel(lastPanelAnchor);
  }

  function langLabel(code) {
    var c = String(code || '').toLowerCase();
    if (c.indexOf('zh') === 0) return t('sourceZh');
    if (c === 'en') return t('sourceEn');
    return code || '';
  }

  function showPanelTranslation(snap, dict, trans, dir) {
    ensurePanel();
    clearPanelBody();
    panelParts.result.style.display = '';
    panelParts.result.className = 'ty-translate-result';

    var actualDir = dir || resolveDirection(snap.text);
    // prefer what the engine actually did over a fresh(er) config guess
    var srcLang = (trans && trans.sourceLang) || actualDir.source;
    var tgtLang = (trans && trans.targetLang) || actualDir.target;
    panelParts.meta.textContent = langLabel(srcLang) + ' → ' + langLabel(tgtLang);

    var hasDict = !!(dict && dict.ok && dict.translations && dict.translations.length);
    var hasTrans = !!(trans && trans.ok && trans.text);
    log(
      'info',
      '[UI] panel result dict=' + hasDict + ' trans=' + hasTrans + ' provider=' + ((dict && dict.provider) || (trans && trans.provider) || '-')
    );

    if (hasDict) {
      var wordHead = el('div', { className: 'ty-translate-word-head' });
      wordHead.appendChild(el('span', { className: 'ty-translate-word', text: dict.word || snap.text }));
      var phonetic = dict.phonetic || dict.usphone || dict.ukphone || '';
      if (phonetic) wordHead.appendChild(el('span', { className: 'ty-translate-phonetic', text: phonetic }));
      panelParts.result.appendChild(wordHead);
      var defs = el('ul', { className: 'ty-translate-defs' });
      dict.translations.slice(0, 8).forEach(function (entry) {
        var row = el('li');
        if (entry.pos) row.appendChild(el('span', { className: 'ty-translate-pos', text: entry.pos }));
        row.appendChild(document.createTextNode(entry.def || ''));
        defs.appendChild(row);
      });
      panelParts.result.appendChild(defs);
      if (hasTrans && trans.text) {
        panelParts.result.appendChild(el('div', { className: 'ty-translate-divider-line' }));
        panelParts.result.appendChild(el('div', { className: 'ty-translate-subtitle', text: t('machineTitle') }));
        panelParts.result.appendChild(el('div', { className: 'ty-translate-result', text: trans.text }));
      }
      var dictProvider = dict.provider || 'dictionary';
      if (hasTrans && trans.provider) dictProvider += ' + ' + trans.provider;
      panelParts.provider.textContent = t('provideBy', { p: dictProvider });
      if (hasTrans && trans.elapsedMs) panelParts.meta.textContent += '  ·  ' + trans.elapsedMs + 'ms';
      currentTranslate = {
        snapshot: snap,
        text: hasTrans && trans.text ? trans.text : (dict.translations[0] && dict.translations[0].def) || '',
        hasMachine: hasTrans,
      };
    } else if (hasTrans) {
      panelParts.result.appendChild(el('div', { className: 'ty-translate-result', text: trans.text }));
      var label = trans.provider || 'unknown';
      if (trans.cached) label += ' · cache';
      panelParts.provider.textContent = t('provideBy', { p: label });
      if (trans.elapsedMs) panelParts.meta.textContent += '  ·  ' + trans.elapsedMs + 'ms';
      currentTranslate = { snapshot: snap, text: trans.text, hasMachine: true };
    } else {
      showPanelError(t('errorPrefix'), (trans && trans.error) || (dict && dict.error) || t('hint'));
      return;
    }

    panelParts.copyBtn.disabled = !(currentTranslate && currentTranslate.text);
    // dictionary-only results (no MT gloss) must not be inserted into the doc
    panelParts.replaceBtn.disabled = !(currentTranslate && currentTranslate.hasMachine && currentTranslate.text);
    positionPanel(lastPanelAnchor);
  }

  function hidePanel() {
    if (panelOpen) log('info', '[UI] panel hide');
    // invalidate any in-flight translation so its callbacks cannot resurrect
    // the panel or overwrite status.json after the user closed it
    opSeq++;
    panelOpen = false;
    if (panel) panel.style.display = 'none';
    currentTranslate = null;
    clearPanelBody();
  }

  function markTranslate(result) {
    writeStatus({
      lastTranslate: {
        at: new Date().toISOString(),
        ok: !!result.ok,
        provider: result.provider || null,
        sourceLang: result.sourceLang || null,
        targetLang: result.targetLang || null,
        // keep only a bounded preview in the diagnostic status file
        sourceText: String(result.sourceText || '').slice(0, 500),
        resultText: String(result.text || '').slice(0, 2000),
        elapsedMs: result.elapsedMs || 0,
      },
    });
  }

  /* ===================================================================
   * 8. Translation flow
   * =================================================================== */

  function translateSnapshot(snap) {
    if (!snap || !snap.charCount) {
      toast(t('emptySelection'));
      return;
    }
    loadConfig();
    if (config.enabled === false) {
      toast(t('disabled'));
      return;
    }
    var trimmed = truncateText(snap.text);
    var work = {
      at: snap.at,
      mode: snap.mode,
      text: trimmed.text,
      rect: snap.rect,
      range: snap.range,
      cmFrom: snap.cmFrom,
      cmTo: snap.cmTo,
      charCount: trimmed.text.length,
    };
    if (trimmed.truncated) toast(t('tooLong', { n: trimmed.text.length }));

    var seq = ++opSeq;
    // Point retry/copy at this request from the start, so a failed first
    // translation can still be retried and a stale one is never reused.
    currentTranslate = { snapshot: work, text: '', hasMachine: false };
    showPanelShell(work);
    var dir = resolveDirection(work.text);
    var started = Date.now();
    log('info', '[TRANSLATE] start mode=' + work.mode + ' len=' + work.charCount + ' target=' + dir.target);

    var svc;
    try {
      svc = getService();
    } catch (e) {
      log('error', '[ERROR] service unavailable: ' + (e && e.message));
      if (seq === opSeq) showPanelError(t('noService'), e && e.message);
      return;
    }

    // Single English word: dictionary (phonetics/definitions) AND machine
    // translation (a clean gloss that is safe for copy/replace) in parallel.
    if (config.lookupWords !== false && dir.target === 'zh-Hans' && isSingleWord(work.text)) {
      var dictPromise = svc.lookupWord(work.text).catch(function (e) {
        return { ok: false, error: (e && e.message) || 'lookup failed' };
      });
      var transPromise = svc.translate(work.text, { targetLang: dir.target, sourceLang: 'auto' });
      Promise.all([dictPromise, transPromise])
        .then(function (pair) {
          if (seq !== opSeq) return;
          var dict = pair[0];
          var trans = pair[1];
          var dictOk = !!(dict && dict.ok && dict.translations && dict.translations.length);
          if (!dictOk) {
            handleMachineResult(work, dir, started, trans, seq);
            return;
          }
          var elapsed = Date.now() - started;
          var machineOk = !!(trans && trans.ok && trans.text);
          showPanelTranslation(work, dict, machineOk ? trans : null, dir);
          markTranslate({
            ok: true,
            provider: dict.provider || 'dictionary',
            sourceLang: 'en',
            targetLang: 'zh-Hans',
            sourceText: work.text,
            text: machineOk ? trans.text : (dict.translations[0] && dict.translations[0].def) || '',
            elapsedMs: elapsed,
          });
          log('info', '[TRANSLATE] ok dict word=' + work.text + ' elapsed=' + elapsed + ' machine=' + machineOk);
        })
        .catch(function (e) {
          if (seq !== opSeq) return;
          handleMachineError(work, dir, Date.now() - started, e, seq);
        });
      return;
    }

    runMachineTranslation(svc, work, dir, started, seq);
  }

  function runMachineTranslation(svc, work, dir, started, seq) {
    svc
      .translate(work.text, { targetLang: dir.target, sourceLang: 'auto' })
      .then(function (res) {
        handleMachineResult(work, dir, started, res, seq);
      })
      .catch(function (e) {
        handleMachineError(work, dir, Date.now() - started, e, seq);
      });
  }

  function handleMachineResult(work, dir, started, res, seq) {
    if (seq !== opSeq) return; // a newer translation owns the panel now
    var elapsed = Date.now() - started;
    if (!res || !res.ok) {
      var err = (res && res.error) || 'unknown error';
      showPanelError(t('errorPrefix') + '：' + t('hint'), err);
      writeStatus({
        lastTranslate: {
          at: new Date().toISOString(),
          ok: false,
          provider: (res && res.provider) || null,
          sourceLang: dir.source,
          targetLang: dir.target,
          sourceText: String(work.text || '').slice(0, 500),
          resultText: '',
          elapsedMs: elapsed,
          error: err,
        },
      });
      log('error', '[TRANSLATE] fail ' + err);
      return;
    }
    showPanelTranslation(work, null, res, dir);
    markTranslate({
      ok: true,
      provider: res.provider,
      sourceLang: res.sourceLang || dir.source,
      targetLang: res.targetLang || dir.target,
      sourceText: work.text,
      text: res.text,
      elapsedMs: elapsed,
    });
    log('info', '[TRANSLATE] ok provider=' + res.provider + ' elapsed=' + elapsed + ' cached=' + !!res.cached);
  }

  function handleMachineError(work, dir, elapsed, e, seq) {
    if (seq !== opSeq) return;
    showPanelError(t('errorPrefix') + '：' + t('hint'), e && e.message);
    recordError('translate', e);
    writeStatus({
      lastTranslate: {
        at: new Date().toISOString(),
        ok: false,
        provider: null,
        sourceLang: dir.source,
        targetLang: dir.target,
        sourceText: String(work.text || '').slice(0, 500),
        resultText: '',
        elapsedMs: elapsed,
        error: String(e && e.message),
      },
    });
  }

  /* ===================================================================
   * 9. Actions: copy / replace / config / toast
   * =================================================================== */

  function copyText(text) {
    try {
      if (electron && electron.clipboard && typeof electron.clipboard.writeText === 'function') {
        electron.clipboard.writeText(String(text));
        toast(t('copied'));
        return true;
      }
    } catch (e) {}
    try {
      if (navigator.clipboard && navigator.clipboard.writeText) {
        navigator.clipboard.writeText(String(text)).then(function () {
          toast(t('copied'));
        });
        return true;
      }
    } catch (e) {}
    try {
      var ta = document.createElement('textarea');
      ta.value = String(text);
      ta.style.position = 'fixed';
      ta.style.left = '-9999px';
      document.body.appendChild(ta);
      ta.select();
      var ok = document.execCommand('copy');
      document.body.removeChild(ta);
      if (ok) {
        toast(t('copied'));
        return true;
      }
    } catch (e) {}
    toast(t('copyFailed'));
    return false;
  }

  function replaceSelection(snap, text) {
    try {
      if (snap.mode === 'source') {
        var st = editorState();
        var cm = st.cm;
        if (cm && snap.cmFrom && snap.cmTo && typeof cm.replaceRange === 'function') {
          cm.replaceRange(String(text), snap.cmFrom, snap.cmTo);
          toast(t('replaced'));
          hidePanel();
          return true;
        }
      } else {
        var write = document.getElementById('write');
        if (write && snap.range && snap.range.startContainer && snap.range.startContainer.isConnected) {
          write.focus();
          var sel = window.getSelection();
          sel.removeAllRanges();
          sel.addRange(snap.range);
          var ok = document.execCommand('insertText', false, String(text));
          if (ok) {
            toast(t('replaced'));
            hidePanel();
            return true;
          }
        }
      }
    } catch (e) {
      log('error', '[ERROR] replaceSelection: ' + (e && e.message));
    }
    // fallback: copy instead of corrupting the document
    copyText(text);
    toast(t('replaceFailed'));
    return false;
  }

  function openConfigFile() {
    try {
      loadConfig(true);
      if (electron && electron.shell && typeof electron.shell.openPath === 'function' && CONFIG_PATH) {
        electron.shell.openPath(CONFIG_PATH);
        return;
      }
    } catch (e) {}
    if (CONFIG_PATH) copyText(CONFIG_PATH);
    toast(t('openConfigFailed'));
  }

  var toastEl = null;
  var toastTimer = null;

  function ensureToast() {
    if (toastEl && document.body.contains(toastEl)) return toastEl;
    toastEl = el('div', { id: 'ty-translate-toast' });
    document.body.appendChild(toastEl);
    return toastEl;
  }

  function toast(message) {
    try {
      ensureToast();
      toastEl.textContent = message;
      toastEl.classList.add('show');
      if (toastTimer) clearTimeout(toastTimer);
      toastTimer = setTimeout(function () {
        toastEl.classList.remove('show');
      }, 1800);
    } catch (e) {}
  }

  /* ===================================================================
   * 10. Hotkey
   * =================================================================== */

  function parseShortcut(spec) {
    var parts = String(spec || 'Ctrl+Shift+T')
      .split('+')
      .map(function (p) {
        return p.trim().toLowerCase();
      })
      .filter(Boolean);
    var out = { ctrl: false, shift: false, alt: false, meta: false, key: '' };
    parts.forEach(function (p) {
      if (p === 'ctrl' || p === 'control') out.ctrl = true;
      else if (p === 'shift') out.shift = true;
      else if (p === 'alt' || p === 'option') out.alt = true;
      else if (p === 'meta' || p === 'cmd' || p === 'win' || p === 'super') out.meta = true;
      else out.key = p;
    });
    return out;
  }

  function isEditorFocused() {
    try {
      var active = document.activeElement;
      var write = document.getElementById('write');
      if (active) {
        if (write && (active === write || write.contains(active))) return true;
        if (active.closest && active.closest('.CodeMirror, .cm-editor')) return true;
        if (active.tagName === 'TEXTAREA') return true;
      }
      var st = editorState();
      if (st.inSource && st.cm) return true;
      var sel = window.getSelection();
      if (sel && sel.rangeCount && write) {
        var node = sel.anchorNode;
        if (node && (node === write || write.contains(node))) return true;
      }
    } catch (e) {}
    return false;
  }

  function onKeyDown(evt) {
    try {
      if (!config.enabled) return;
      var sc = parseShortcut(config.shortcut);
      if (!sc.key) return;
      var key = String(evt.key || '').toLowerCase();
      var matchesKey = key === sc.key || (sc.key.length === 1 && key === sc.key) || (evt.code || '').toLowerCase() === 'key' + sc.key;
      if (!matchesKey) return;
      var modOK =
        !!evt.ctrlKey === sc.ctrl &&
        !!evt.shiftKey === sc.shift &&
        !!evt.altKey === sc.alt &&
        !!evt.metaKey === sc.meta;
      if (!modOK) return;
      if (!isEditorFocused()) return;
      evt.preventDefault();
      evt.stopPropagation();
      var sel = window.getSelection();
      var hasSelection = sel && sel.rangeCount > 0 && String(sel).trim().length > 0;
      var snap = hasSelection ? snapshotSelection(evt) : snapshotCursorBlock();
      if (!snap.charCount) {
        var st = editorState();
        if (st.inSource && st.cm) snap = snapshotCursorBlock();
      }
      if (!snap.charCount) {
        toast(t('emptySelection'));
        return;
      }
      // place the panel near the click/caret, not the shortcut event
      if (!hasSelection && !snap.rect) {
        var write = document.getElementById('write');
        var r = write ? write.getBoundingClientRect() : null;
        snap.rect = r ? { left: r.left + 40, top: r.top + 40, width: 0, height: 0 } : null;
      }
      translateSnapshot(snap);
    } catch (e) {
      recordError('onKeyDown', e);
    }
  }

  function onDocMouseDown(evt) {
    try {
      if (!panelOpen) return;
      var target = evt.target;
      if (panel && target && panel.contains(target)) return;
      if (target && target.closest && target.closest('ul.context-menu')) return;
      hidePanel();
    } catch (e) {}
  }

  function onDocKeyDownEscape(evt) {
    try {
      if (evt.key === 'Escape' && panelOpen) {
        hidePanel();
      }
    } catch (e) {}
  }

  /* ===================================================================
   * 11. Boot
   * =================================================================== */

  var booted = false;

  function bindEvents() {
    document.addEventListener('contextmenu', onContextMenuCapture, true);
    document.addEventListener('click', onClickCapture, true);
    document.addEventListener('keydown', onKeyDown, true);
    document.addEventListener('keydown', onDocKeyDownEscape, true);
    document.addEventListener('mousedown', onDocMouseDown, true);
    window.addEventListener('resize', function () {
      if (panelOpen && lastPanelAnchor) positionPanel(lastPanelAnchor);
    });
  }

  function onReady() {
    try {
      if (booted) return;
      loadConfig(true);
      if (config.enabled === false) {
        log('info', '[BOOT] disabled by config');
        return;
      }
      ensurePanel();
      ensureToast();
      ensureMenuItems();
      bindEvents();
      booted = true;
      status.booted = true;
      status.bootAt = new Date().toISOString();
      status.typoraVersion = (navigator.userAgent.match(/Typora\/([\d.]+)/) || [])[1] || 'unknown';
      status.serviceAvailable = !!(window.TyTranslateService && window.TyTranslateService.createService);
      writeStatus();
      log('info', '[BOOT] ready version=' + VERSION + ' typora=' + status.typoraVersion + ' base=' + BASE);
      // Menus are static today, but keep a light guard in case Typora re-renders them.
      setInterval(function () {
        try {
          ensureMenuItems();
        } catch (e) {}
      }, 5000);
    } catch (e) {
      recordError('onReady', e);
    }
  }

  function waitForEditor(reason) {
    var tries = 0;
    (function poll() {
      tries++;
      var ready =
        !!(window.File && window.File.editor && document.getElementById(RICH_MENU_ID) && document.getElementById('write')) ||
        (!!document.getElementById(RICH_MENU_ID) && tries > 100 && !!window.File);
      if (ready) {
        onReady();
      } else if (tries < 600) {
        setTimeout(poll, 200);
      } else {
        recordError('waitForEditor', new Error('editor not ready after ' + tries + ' tries (' + reason + ')'));
      }
    })();
  }

  function boot(opts) {
    try {
      opts = opts || {};
      if (opts.base) BASE = opts.base;
      if (opts.version) VERSION = opts.version;
      initPaths();
      loadConfig(true);
      log('info', '[BOOT] starting version=' + VERSION + ' base=' + BASE + ' href=' + location.href);
      writeStatus({
        version: VERSION,
        booted: false,
        bootAt: new Date().toISOString(),
        typoraVersion: (navigator.userAgent.match(/Typora\/([\d.]+)/) || [])[1] || 'unknown',
      });
      if (config.enabled === false) {
        log('info', '[BOOT] disabled in config, not activating');
        return;
      }
      waitForEditor('boot');
    } catch (e) {
      recordError('boot', e);
    }
  }

  /* ===================================================================
   * 12. Public API (used by boot and by the dev verification harness)
   * =================================================================== */

  NS.boot = boot;
  NS.version = VERSION;
  NS.getStatus = function () {
    return JSON.parse(JSON.stringify(status));
  };
  NS.getConfig = function () {
    return loadConfig(true);
  };
  NS.getConfigPath = function () {
    return CONFIG_PATH;
  };
  NS.getLogPath = function () {
    return LOG_PATH;
  };
  NS.hidePanel = hidePanel;
  NS.translateSelection = function () {
    var snap = snapshotSelection();
    if (snap.charCount) translateSnapshot(snap);
    return snap;
  };
  NS.translateCurrentBlock = function () {
    var snap = snapshotCursorBlock();
    if (snap.charCount) translateSnapshot(snap);
    return snap;
  };
  NS._debug = {
    snapshotSelection: snapshotSelection,
    snapshotCursorBlock: snapshotCursorBlock,
    ensureMenuItems: ensureMenuItems,
    getService: getService,
    resetService: resetService,
    resolveDirection: resolveDirection,
  };

  // Mark the plugin as present even before Typora's editor is ready.
  window.__TY_TRANSLATE_UI_LOADED__ = VERSION;
})();