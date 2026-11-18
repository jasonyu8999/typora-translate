/*
 * Typora Translate — loader (injected into Typora's resources/window.html)
 *
 * Responsibilities, kept deliberately tiny and defensive:
 *   1. resolve the plugin base URL from our own <script> tag,
 *   2. load styles.css,
 *   3. load service.js (translation engine) and ui.js (Typora integration),
 *   4. hand control to ui.js via window.TyporaTranslate.boot().
 *
 * Any failure here is recorded on window.__TY_TRANSLATE_LOAD_ERROR__ and must
 * never break Typora itself.
 */
(function () {
  'use strict';

  var VERSION = '1.0.0';
  if (window.__TY_TRANSLATE_BOOTSTRAPPED__) return;
  window.__TY_TRANSLATE_BOOTSTRAPPED__ = true;

  var base = './plugin/typora-translate/';
  try {
    if (document.currentScript && document.currentScript.src) {
      base = document.currentScript.src.replace(/[^/]+$/, '');
    }
  } catch (e) {}

  window.__TY_TRANSLATE_BASE__ = base;
  window.__TY_TRANSLATE_VERSION__ = VERSION;

  function fail(reason) {
    window.__TY_TRANSLATE_LOAD_ERROR__ = String(reason);
    try {
      console.error('[typora-translate] ' + reason);
    } catch (e) {}
  }

  function loadStyle(href) {
    try {
      var link = document.createElement('link');
      link.id = 'typora-translate-style';
      link.rel = 'stylesheet';
      link.type = 'text/css';
      link.charset = 'utf-8';
      link.href = href;
      (document.head || document.documentElement).appendChild(link);
    } catch (e) {
      fail('style load: ' + (e && e.message));
    }
  }

  function loadScript(src, done) {
    var finished = false;
    var watchdog = null;
    function finish(err) {
      if (finished) return;
      finished = true;
      if (watchdog) clearTimeout(watchdog);
      done(err);
    }
    try {
      var s = document.createElement('script');
      s.charset = 'utf-8';
      s.src = src;
      s.async = false;
      s.onload = function () {
        finish(null);
      };
      s.onerror = function () {
        finish(new Error('failed to load ' + src));
      };
      (document.head || document.documentElement).appendChild(s);
      // never leave the plugin half-loaded if a script hangs
      watchdog = setTimeout(function () {
        finish(new Error('timeout loading ' + src));
      }, 20000);
    } catch (e) {
      finish(e);
    }
  }

  function bootUi() {
    var api = window.TyporaTranslate;
    if (!api || typeof api.boot !== 'function') {
      return fail('ui.js loaded but window.TyporaTranslate.boot() is missing');
    }
    try {
      api.boot({
        base: base,
        version: VERSION,
        service: window.TyTranslateService || null,
      });
    } catch (e) {
      fail('boot threw: ' + (e && e.stack ? e.stack : e));
    }
  }

  loadStyle(base + 'styles.css');
  // service.js is optional at load time (ui reports a clear error if absent),
  // so ui.js is always loaded after it regardless of success.
  loadScript(base + 'service.js', function (svcErr) {
    if (svcErr) fail('service.js: ' + svcErr.message);
    loadScript(base + 'ui.js', function (uiErr) {
      if (uiErr) return fail('ui.js: ' + uiErr.message);
      bootUi();
    });
  });
})();