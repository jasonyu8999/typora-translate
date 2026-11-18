/*!
 * typora-translate - translation engine (service.js)
 * ---------------------------------------------------------------------------
 * Self-contained, dependency-free translation engine for the Typora
 * "select text -> right click -> 翻译" plugin (Typora 1.12.4, Windows).
 *
 * Runs in BOTH of these environments:
 *   (a) Typora renderer: `require` may be undefined, but `window.reqnode`
 *       gives access to Node's https module.
 *   (b) Plain Node (tests / tooling): CommonJS `require('https')` works.
 *
 * Load contract (UMD):
 *   browser/Typora : <script src="service.js"> sets window.TyTranslateService
 *   Node           : module.exports === the same object
 *
 * Public API (small on purpose):
 *   var svc = TyTranslateService.createService({ log, config, appName });
 *   await svc.translate(text, { targetLang, sourceLang })  // NEVER throws
 *   await svc.lookupWord(word)                              // NEVER throws
 *   svc.detectLanguage(text) -> 'zh' | 'en' | 'other'
 *   svc.clearCache()
 *   svc.getStatus() -> { cacheSize, lastProvider, lastError }
 *
 * translate() result on success:
 *   { ok:true, text, provider, sourceLang, targetLang, cached, elapsedMs }
 * translate() result on failure:
 *   { ok:false, error, provider }
 *
 * Providers (tried in config.providers order, default ['bing','mymemory']):
 *   bing     - cn.bing.com web translator (no API key), token cached ~10 min
 *   mymemory - api.mymemory.translated.net (free fallback, rate limited)
 *   llm      - optional OpenAI-compatible chat/completions endpoint
 * lookupWord() uses dict.youdao.com (jsonapi + suggest fallback).
 *
 * No npm dependencies. No top-level DOM access. ES2018 compatible.
 * Never log secrets (LLM api key is never included in logs or errors).
 */
(function () {
  'use strict';

  var VERSION = '1.0.0';

  var DESKTOP_UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 ' +
    '(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36 Edg/120.0.0.0';

  var MAX_RESPONSE_BYTES = 6 * 1024 * 1024;

  // =========================================================================
  // Section 1: tiny generic utilities (no dependencies)
  // =========================================================================

  function isPlainObject(v) {
    return !!v && typeof v === 'object' && !Array.isArray(v);
  }

  function cloneValue(v) {
    if (Array.isArray(v)) return v.slice();
    if (isPlainObject(v)) return deepMerge({}, v);
    return v;
  }

  // Recursive merge so users can override a single nested config key.
  function deepMerge(base, override) {
    var out = {};
    var k;
    for (k in base) {
      if (Object.prototype.hasOwnProperty.call(base, k)) out[k] = cloneValue(base[k]);
    }
    if (!isPlainObject(override)) return out;
    for (k in override) {
      if (!Object.prototype.hasOwnProperty.call(override, k)) continue;
      var ov = override[k];
      if (ov === undefined) continue;
      if (isPlainObject(ov) && isPlainObject(out[k])) out[k] = deepMerge(out[k], ov);
      else if (Array.isArray(ov)) out[k] = ov.slice();
      else out[k] = ov;
    }
    return out;
  }

  function errMsg(e) {
    if (!e) return 'unknown error';
    if (typeof e === 'string') return e;
    if (e.message) return String(e.message);
    try { return String(e); } catch (e2) { return 'unknown error'; }
  }

  function truncate(s, n) {
    s = String(s == null ? '' : s);
    return s.length > n ? s.slice(0, n) + '…' : s;
  }

  // UTF-8 byte length without Buffer (works in the Typora renderer too).
  function utf8ByteLength(str) {
    var n = 0;
    for (var i = 0; i < str.length; i++) {
      var c = str.charCodeAt(i);
      if (c < 0x80) n += 1;
      else if (c < 0x800) n += 2;
      else if (c >= 0xD800 && c <= 0xDBFF) { n += 4; i++; }
      else n += 3;
    }
    return n;
  }

  function parseJson(text) {
    if (typeof text !== 'string') return null;
    var s = text.replace(/^\uFEFF/, '').trim();
    if (!s) return null;
    try { return JSON.parse(s); } catch (e) { return null; }
  }

  function decodeHtmlEntities(s) {
    if (typeof s !== 'string') return '';
    return s
      .replace(/&(amp|lt|gt|quot|apos|nbsp);/gi, function (m, g) {
        switch (String(g).toLowerCase()) {
          case 'amp': return '&';
          case 'lt': return '<';
          case 'gt': return '>';
          case 'quot': return '"';
          case 'apos': return "'";
          case 'nbsp': return ' ';
          default: return m;
        }
      })
      .replace(/&#(\d+);/g, function (m, d) {
        var code = parseInt(d, 10);
        return code > 0 && code < 0x110000 ? String.fromCharCode(code) : m;
      })
      .replace(/&#x([0-9a-f]+);/gi, function (m, h) {
        var code = parseInt(h, 16);
        return code > 0 && code < 0x110000 ? String.fromCharCode(code) : m;
      });
  }

  function nowMs() { return Date.now(); }

  function uniqPush(arr, value) {
    if (value && arr.indexOf(value) < 0) arr.push(value);
  }

  // =========================================================================
  // Section 2: HTTP layer (Node https only - avoids browser CORS entirely)
  // =========================================================================

  var HTTP_TIMEOUT_MS = 12000; // hard cap for one HTTP request

  // In the Typora renderer `require` is usually undefined; window.reqnode is
  // the supported escape hatch and behaves like require.
  function getHttpsModule(state) {
    if (state.httpsModule) return state.httpsModule;
    var mod = null;
    try {
      if (typeof require === 'function') mod = require('https');
    } catch (e) {
      mod = null;
    }
    if (!mod) {
      try {
        var win = (typeof window !== 'undefined') ? window : null;
        if (win && typeof win.reqnode === 'function') mod = win.reqnode('https');
      } catch (e2) {
        mod = null;
      }
    }
    if (!mod || typeof mod.request !== 'function') {
      throw new Error('Node https module is unavailable (require/window.reqnode missing)');
    }
    state.httpsModule = mod;
    return mod;
  }

  // Split "https://host[:port]/path?query" into parts; deliberately not using
  // the WHATWG URL class so the same code path works everywhere.
  function splitUrl(urlStr) {
    var m = /^(https?):\/\/([^\/?#]+)([^#]*)$/i.exec(String(urlStr || ''));
    if (!m) throw new Error('invalid url: ' + truncate(urlStr, 120));
    return { protocol: m[1].toLowerCase(), host: m[2], path: m[3] || '/' };
  }

  function resolveRedirect(baseUrl, location) {
    location = String(location || '').trim();
    if (/^https?:\/\//i.test(location)) return location;
    var base = splitUrl(baseUrl);
    if (location.charAt(0) === '/') return base.protocol + '://' + base.host + location;
    return base.protocol + '://' + base.host + '/' + location;
  }

  /**
   * Perform one HTTPS request, following up to `maxRedirects` redirects.
   * Resolves with { statusCode, headers, body, finalUrl } for any status code;
   * rejects on transport errors / timeout / oversized response.
   *
   * options: { method, headers, body, timeoutMs, deadline, maxRedirects }
   */
  function httpRequest(state, urlStr, options) {
    options = options || {};
    var timeoutMs = Number(options.timeoutMs) > 0 ? Number(options.timeoutMs) : HTTP_TIMEOUT_MS;
    var deadline = Number(options.deadline) > 0 ? Number(options.deadline) : nowMs() + timeoutMs;
    var maxRedirects = options.maxRedirects == null ? 3 : Number(options.maxRedirects);

    return new Promise(function (resolve, reject) {
      var settled = false;
      function finish(fn, value) {
        if (settled) return;
        settled = true;
        fn(value);
      }

      function go(currentUrl, method, body, redirectsLeft) {
        var parts;
        try { parts = splitUrl(currentUrl); } catch (e) { return finish(reject, e); }
        if (parts.protocol !== 'https') {
          return finish(reject, new Error('only https:// is supported'));
        }

        var hostname = parts.host;
        var port = 443;
        var colon = hostname.lastIndexOf(':');
        if (colon > 0 && hostname.indexOf(']') < 0) {
          var parsedPort = parseInt(hostname.slice(colon + 1), 10);
          if (parsedPort > 0) { port = parsedPort; hostname = hostname.slice(0, colon); }
        }

        var remaining = deadline - nowMs();
        var thisTimeout = Math.min(timeoutMs, remaining);
        if (thisTimeout <= 0) return finish(reject, new Error('request deadline exceeded'));

        var headers = {};
        var given = options.headers || {};
        for (var hk in given) {
          if (!Object.prototype.hasOwnProperty.call(given, hk)) continue;
          if (given[hk] == null || given[hk] === '') continue;
          headers[hk] = given[hk];
        }
        if (body != null) headers['Content-Length'] = utf8ByteLength(body);

        var https;
        try { https = getHttpsModule(state); } catch (e) { return finish(reject, e); }

        var req;
        try {
          req = https.request({
            hostname: hostname,
            port: port,
            path: parts.path,
            method: method,
            headers: headers
          }, function (res) {
            var location = res.headers && res.headers.location;
            var isRedirect = res.statusCode === 301 || res.statusCode === 302 ||
              res.statusCode === 303 || res.statusCode === 307 || res.statusCode === 308;
            if (isRedirect && location && redirectsLeft > 0) {
              res.resume();
              var nextMethod = method;
              var nextBody = body;
              // 303 always switches to GET; 301/302 switch POST -> GET like browsers.
              if (res.statusCode === 303 ||
                  ((res.statusCode === 301 || res.statusCode === 302) && method === 'POST')) {
                nextMethod = 'GET';
                nextBody = null;
              }
              var nextUrl;
              try { nextUrl = resolveRedirect(currentUrl, location); } catch (e) { return finish(reject, e); }
              return go(nextUrl, nextMethod, nextBody, redirectsLeft - 1);
            }

            res.setEncoding('utf8');
            var chunks = [];
            var total = 0;
            res.on('data', function (d) {
              total += d.length;
              if (total > MAX_RESPONSE_BYTES) {
                req.destroy(new Error('response too large'));
                return;
              }
              chunks.push(d);
            });
            res.on('end', function () {
              finish(resolve, {
                statusCode: res.statusCode,
                headers: res.headers || {},
                body: chunks.join(''),
                finalUrl: currentUrl
              });
            });
            res.on('error', function (e) { finish(reject, e); });
          });
        } catch (e) {
          return finish(reject, e);
        }

        req.on('error', function (e) { finish(reject, e); });
        req.setTimeout(thisTimeout, function () {
          req.destroy(new Error('request timeout after ' + thisTimeout + 'ms'));
        });
        if (body != null) req.write(body);
        req.end();
      }

      try {
        go(urlStr, String(options.method || 'GET').toUpperCase(),
           options.body != null ? String(options.body) : null, maxRedirects);
      } catch (e) {
        finish(reject, e);
      }
    });
  }

  function cookiesFromHeaders(headers) {
    if (!headers) return '';
    var raw = headers['set-cookie'];
    if (!raw) return '';
    if (Array.isArray(raw)) {
      return raw.map(function (c) { return String(c).split(';')[0].trim(); })
        .filter(function (c) { return !!c; }).join('; ');
    }
    return String(raw).split(';')[0].trim();
  }

  // =========================================================================
  // Section 3: language detection / normalization
  // =========================================================================

  var RE_HAN = /[\u3400-\u4DBF\u4E00-\u9FFF\uF900-\uFAFF]/;
  var RE_LATIN = /[A-Za-z\u00C0-\u024F]/;

  function detectLanguageHeuristic(text) {
    if (typeof text !== 'string' || !text) return 'other';
    var han = 0, latin = 0, i, c;
    for (i = 0; i < text.length; i++) {
      c = text.charCodeAt(i);
      if ((c >= 0x3400 && c <= 0x4DBF) || (c >= 0x4E00 && c <= 0x9FFF) || (c >= 0xF900 && c <= 0xFAFF)) {
        han++;
      } else if ((c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) || (c >= 0xC0 && c <= 0x24F)) {
        latin++;
      }
    }
    if (han > 0 && han >= latin * 0.5) return 'zh';
    if (latin > 0) return 'en';
    if (han > 0) return 'zh';
    return 'other';
  }

  function normalizeSourceLangOption(sourceLang) {
    if (sourceLang == null) return 'auto';
    var raw = String(sourceLang).trim().toLowerCase().replace(/_/g, '-');
    if (!raw || raw === 'auto' || raw === 'auto-detect' || raw === 'autodetect') return 'auto';
    if (raw.indexOf('zh') === 0) return 'zh';
    if (raw.indexOf('en') === 0) return 'en';
    return raw;
  }

  // Canonical internal target codes: 'zh-Hans' | 'zh-Hant' | 'en' | <code>.
  function normalizeTargetLang(targetLang) {
    var raw = (typeof targetLang === 'string' && targetLang.trim()) ? targetLang.trim() : 'zh-Hans';
    var v = raw.toLowerCase().replace(/_/g, '-');
    if (v === 'zh' || v === 'zh-hans' || v === 'zh-cn' || v === 'zh-sg' || v.indexOf('zh-hans') === 0) return 'zh-Hans';
    if (v.indexOf('zh-hant') === 0 || v === 'zh-tw' || v === 'zh-hk' || v === 'zh-mo') return 'zh-Hant';
    if (v === 'en' || v.indexOf('en-') === 0) return 'en';
    return v;
  }

  function bingTargetCode(canonical) {
    if (canonical === 'zh-Hans') return 'zh-Hans';
    if (canonical === 'zh-Hant') return 'zh-Hant';
    return canonical;
  }

  function bingSourceCode(canonicalSource) {
    if (canonicalSource === 'zh') return 'zh-Hans';
    return canonicalSource;
  }

  function mymemoryLangCode(canonical) {
    if (canonical === 'zh') return 'zh-CN';
    if (canonical === 'zh-Hans') return 'zh-CN';
    if (canonical === 'zh-Hant') return 'zh-TW';
    return canonical;
  }

  function normalizeDetectedLang(raw) {
    if (!raw) return '';
    var v = String(raw).trim().toLowerCase();
    if (!v) return '';
    if (v.indexOf('zh') === 0) return 'zh';
    if (v === 'en' || v.indexOf('en-') === 0) return 'en';
    return v;
  }

  function resolveResultSource(sourceOption, detectedRaw, fullText) {
    if (sourceOption !== 'auto') return sourceOption;
    var norm = normalizeDetectedLang(detectedRaw);
    if (norm) return norm;
    var guess = detectLanguageHeuristic(fullText);
    return guess; // 'zh' | 'en' | 'other'
  }

  function targetDisplayName(canonical) {
    if (canonical === 'zh-Hans') return 'Simplified Chinese';
    if (canonical === 'zh-Hant') return 'Traditional Chinese';
    if (canonical === 'en') return 'English';
    return canonical;
  }

  function isCjkTarget(canonical) {
    return canonical === 'zh-Hans' || canonical === 'zh-Hant' || /^(ja|ko)/.test(canonical);
  }

  // =========================================================================
  // Section 4: text chunking (sentence/newline aware, lossless content)
  // =========================================================================

  var RE_WS = /\s/;
  var RE_CJK_PUNCT_AFTER = /[。！？；：，、）》」』】“”‘’]/;

  function isHighSurrogate(code) { return code >= 0xD800 && code <= 0xDBFF; }

  // Find a break index in (minPos, maxPos]; returns -1 when no boundary found.
  function findBreakPos(text, minPos, maxPos) {
    for (var j = maxPos; j > minPos; j--) {
      var ch = text.charAt(j - 1);
      if (ch === '\n') return j;
      if (ch === '.' || ch === '!' || ch === '?' || ch === ';' || ch === ':' ||
          ch === '。' || ch === '！' || ch === '？' || ch === '；' || ch === '：') {
        var next = text.charAt(j);
        if (!next || RE_WS.test(next) || RE_CJK_PUNCT_AFTER.test(next) || RE_HAN.test(next)) return j;
        continue;
      }
      if (ch === ' ') return j;
    }
    return -1;
  }

  /**
   * Split text into chunks of <= maxLen characters, preferring sentence /
   * newline / whitespace boundaries. Returns [{ text, sep, breakType }] where
   * `sep` is the whitespace that followed the chunk in the source text and
   * `breakType` is 'newline' | 'space' | 'punct' | 'hard'. Concatenating
   * chunk.text + chunk.sep reproduces the original text exactly.
   */
  function chunkText(text, maxLen) {
    maxLen = Number(maxLen) > 0 ? Math.floor(Number(maxLen)) : 900;
    if (maxLen < 40) maxLen = 40;
    var out = [];
    var n = text.length;
    var i = 0;
    var safety = 0;
    while (i < n && safety++ < 100000) {
      var remaining = n - i;
      if (remaining <= maxLen) {
        out.push(makeChunk(text, i, n, n, maxLen));
        break;
      }
      var end = i + maxLen;
      var minBreak = i + Math.floor(maxLen * 0.5);
      var b = findBreakPos(text, minBreak, end);
      if (b <= i) b = end;
      // Never split a surrogate pair.
      if (b > i + 1 && isHighSurrogate(text.charCodeAt(b - 1))) b--;
      var j = b;
      while (j < n && RE_WS.test(text.charAt(j))) j++;
      var chunk = makeChunk(text, i, b, j, maxLen);
      out.push(chunk);
      i = j;
    }
    return out;
  }

  function makeChunk(text, start, contentEnd, sepEnd, maxLen) {
    var content = text.slice(start, contentEnd);
    var sep = text.slice(contentEnd, sepEnd);
    var last = contentEnd > 0 ? text.charAt(contentEnd - 1) : '';
    var breakType = 'punct';
    if (last === '\n' || last === '\r') breakType = 'newline';
    else if (last === ' ' || last === '\t') breakType = 'space';
    else if (!last) breakType = 'hard';
    // Guard against pathological content (e.g. no boundary at all).
    if (content.length > maxLen + 1) content = content.slice(0, maxLen);
    return { text: content, sep: sep, breakType: breakType };
  }

  // Re-join translated chunks. CJK targets do not need spaces between
  // sentences; alphabetic targets get a space (or preserved newlines).
  function joinChunkTranslations(chunks, parts, targetCanonical) {
    var out = '';
    var cjk = isCjkTarget(targetCanonical);
    for (var i = 0; i < parts.length; i++) {
      if (i > 0) {
        var prev = chunks[i - 1];
        var sep = prev.sep || '';
        if (sep.indexOf('\n') >= 0) {
          out += sep.replace(/[^\r\n]/g, '');
        } else if (prev.breakType === 'newline') {
          out += '\n';
        } else if (cjk) {
          out += '';
        } else {
          out += ' ';
        }
      }
      out += parts[i];
    }
    return out;
  }

  // =========================================================================
  // Section 5: in-memory LRU cache (size 100 by default)
  // =========================================================================

  function LruCache(maxSize) {
    this.max = Number(maxSize) > 0 ? Math.floor(Number(maxSize)) : 100;
    this.map = new Map();
  }
  LruCache.prototype.get = function (key) {
    if (!this.map.has(key)) return undefined;
    var value = this.map.get(key);
    this.map.delete(key);
    this.map.set(key, value);
    return value;
  };
  LruCache.prototype.set = function (key, value) {
    if (this.map.has(key)) this.map.delete(key);
    this.map.set(key, value);
    while (this.map.size > this.max) {
      var first = this.map.keys().next();
      if (first.done) break;
      this.map.delete(first.value);
    }
  };
  LruCache.prototype.clear = function () { this.map.clear(); };
  LruCache.prototype.size = function () { return this.map.size; };

  function cacheKey(provider, sourceLang, targetLang, text) {
    return provider + '|' + sourceLang + '|' + targetLang + '|' + text;
  }

  function cacheSourceCandidates(sourceOption, text) {
    var list = [];
    if (sourceOption !== 'auto') {
      uniqPush(list, sourceOption);
      return list;
    }
    var guess = detectLanguageHeuristic(text);
    if (guess === 'zh') uniqPush(list, 'zh');
    else if (guess === 'en') uniqPush(list, 'en');
    uniqPush(list, 'auto');
    uniqPush(list, 'en');
    uniqPush(list, 'zh');
    uniqPush(list, 'other');
    return list;
  }

  function findCachedEntry(cache, text, providerNames, sourceOption, targetCanonical) {
    var srcs = cacheSourceCandidates(sourceOption, text);
    for (var p = 0; p < providerNames.length; p++) {
      for (var s = 0; s < srcs.length; s++) {
        var hit = cache.get(cacheKey(providerNames[p], srcs[s], targetCanonical, text));
        if (hit) return hit;
      }
    }
    return null;
  }

  // =========================================================================
  // Section 6: Bing web translator provider
  // =========================================================================

  var BING_PAGE_HEADERS = {
    'User-Agent': DESKTOP_UA,
    'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,image/webp,*/*;q=0.8',
    'Accept-Language': 'en-US,en;q=0.9,zh-CN;q=0.8,zh;q=0.7'
  };

  function extractBingParams(html) {
    if (typeof html !== 'string' || !html) return null;
    var igM = /IG:"([^"]+)"/.exec(html) || /IG\s*:\s*"([^"]+)"/.exec(html);
    var iidM = /data-iid="([^"]+)"/.exec(html);
    var abuseM = /params_AbusePreventionHelper\s*=\s*\[([^\]]+)\]/.exec(html);
    if (!igM || !iidM || !abuseM) return null;

    var parts = null;
    try { parts = JSON.parse('[' + abuseM[1] + ']'); } catch (e) { parts = null; }
    if (!parts || parts.length < 2) {
      var m2 = /\[\s*([0-9]+)\s*,\s*"([^"]+)"\s*,\s*([0-9]+)\s*\]/.exec(abuseM[1]);
      if (!m2) return null;
      parts = [Number(m2[1]), m2[2], Number(m2[3])];
    }
    return {
      ig: igM[1],
      iid: iidM[1],
      key: String(parts[0]),
      token: String(parts[1]),
      expiryMs: Number(parts[2]) || 0
    };
  }

  function bingTokenIsValid(state) {
    var t = state.bingToken;
    return !!(t && t.token && t.expiresAt && t.expiresAt - 5000 > nowMs());
  }

  async function getBingToken(ctx, force) {
    var state = ctx.state;
    if (!force && bingTokenIsValid(state)) return state.bingToken;

    var cfg = ctx.config.bing || {};
    var hosts = [];
    uniqPush(hosts, cfg.host || 'cn.bing.com');
    uniqPush(hosts, cfg.fallbackHost || 'www.bing.com');

    var errors = [];
    for (var i = 0; i < hosts.length; i++) {
      var host = hosts[i];
      if (!host) continue;
      try {
        var page = await httpRequest(state, 'https://' + host + '/translator', {
          method: 'GET',
          headers: BING_PAGE_HEADERS,
          timeoutMs: ctx.config.timeoutMs,
          deadline: ctx.deadline
        });
        if (page.statusCode !== 200) {
          throw new Error('page HTTP ' + page.statusCode);
        }
        var params = extractBingParams(page.body);
        if (!params) throw new Error('IG/IID/token params not found in page');

        var finalHost = splitUrl(page.finalUrl).host || host;
        var ttl = Number(cfg.tokenTtlMs) > 0 ? Number(cfg.tokenTtlMs) : 600000;
        if (params.expiryMs > 0) ttl = Math.min(ttl, params.expiryMs);
        if (ttl < 30000) ttl = 30000; // never cache a token for less than 30s

        var token = {
          ig: params.ig,
          iid: params.iid,
          key: params.key,
          token: params.token,
          host: finalHost,
          cookie: cookiesFromHeaders(page.headers),
          expiresAt: nowMs() + ttl
        };
        state.bingToken = token;
        ctx.log('debug', 'bing token acquired', { host: finalHost, ttlMs: ttl, tokenChars: params.token.length });
        return token;
      } catch (e) {
        errors.push(host + ': ' + errMsg(e));
      }
    }
    state.bingToken = null;
    throw new Error('bing token unavailable (' + errors.join('; ') + ')');
  }

  function bingPostHeaders(token) {
    var headers = {
      'User-Agent': DESKTOP_UA,
      'Accept': '*/*',
      'Accept-Language': 'en-US,en;q=0.9,zh-CN;q=0.8',
      'Content-Type': 'application/x-www-form-urlencoded',
      'Referer': 'https://' + token.host + '/translator',
      'Origin': 'https://' + token.host
    };
    if (token.cookie) headers['Cookie'] = token.cookie;
    return headers;
  }

  // Translate a single <=900 char chunk. Throws Error with .bingTokenError=true
  // when the token/IG looks stale so the caller can refresh and retry once.
  async function bingTranslateChunk(ctx, token, fromLang, toLang, text) {
    var body = 'fromLang=' + encodeURIComponent(fromLang) +
      '&to=' + encodeURIComponent(toLang) +
      '&text=' + encodeURIComponent(text) +
      '&token=' + encodeURIComponent(token.token) +
      '&key=' + encodeURIComponent(token.key);
    var url = 'https://' + token.host + '/ttranslatev3?isVertical=1' +
      '&IG=' + encodeURIComponent(token.ig) +
      '&IID=' + encodeURIComponent(token.iid) +
      '&ref=TThis&tryFetchingGenderDebiasedTranslations=true';

    var page = await httpRequest(ctx.state, url, {
      method: 'POST',
      headers: bingPostHeaders(token),
      body: body,
      timeoutMs: ctx.config.timeoutMs,
      deadline: ctx.deadline
    });

    if (page.statusCode === 401 || page.statusCode === 403) {
      var authErr = new Error('bing HTTP ' + page.statusCode + ' (token rejected)');
      authErr.bingTokenError = true;
      throw authErr;
    }
    if (page.statusCode !== 200) {
      throw new Error('bing HTTP ' + page.statusCode);
    }

    var data = parseJson(page.body);
    if (!data) {
      var jsonErr = new Error('bing returned non-JSON response');
      jsonErr.bingTokenError = true; // usually a stale IG/token challenge
      throw jsonErr;
    }
    if (!Array.isArray(data)) {
      if (data && typeof data === 'object' && data.statusCode != null) {
        var apiErr = new Error('bing API status ' + data.statusCode +
          (data.errorMessage ? ': ' + truncate(String(data.errorMessage), 120) : ''));
        apiErr.bingTokenError = true;
        throw apiErr;
      }
      throw new Error('bing unexpected response shape');
    }
    var first = data[0];
    var translation = first && first.translations && first.translations[0];
    if (!translation || typeof translation.text !== 'string') {
      throw new Error('bing response missing translations[0].text');
    }
    var outText = translation.text;
    if (!outText) throw new Error('bing returned an empty translation');
    var detected = '';
    if (first.detectedLanguage && first.detectedLanguage.language) {
      detected = String(first.detectedLanguage.language);
    }
    return { text: outText, detected: detected };
  }

  // One chunk, handling the auto-detect -> heuristic fallback per contract.
  async function bingTranslateOne(ctx, token, chunkTextValue, sourceOption, toLang) {
    if (sourceOption === 'auto') {
      try {
        return await bingTranslateChunk(ctx, token, 'auto-detect', toLang, chunkTextValue);
      } catch (e) {
        if (e && e.bingTokenError) throw e;
        var guess = detectLanguageHeuristic(chunkTextValue) === 'zh' ? 'zh-Hans' : 'en';
        var explicitResult = await bingTranslateChunk(ctx, token, guess, toLang, chunkTextValue);
        if (!explicitResult.detected) explicitResult.detected = guess;
        return explicitResult;
      }
    }
    return await bingTranslateChunk(ctx, token, bingSourceCode(sourceOption), toLang, chunkTextValue);
  }

  // Run chunks with bounded concurrency, preserving index order.
  async function poolMap(items, concurrency, worker) {
    var results = new Array(items.length);
    var nextIndex = 0;
    var limit = Math.max(1, Math.min(Number(concurrency) || 1, items.length || 1));
    async function runner() {
      while (true) {
        var index = nextIndex++;
        if (index >= items.length) return;
        try {
          results[index] = { ok: true, value: await worker(items[index], index) };
        } catch (e) {
          results[index] = { ok: false, error: e };
        }
      }
    }
    var runners = [];
    for (var k = 0; k < limit; k++) runners.push(runner());
    await Promise.all(runners);
    return results;
  }

  function isBingTokenError(e) {
    return !!(e && e.bingTokenError);
  }

  async function bingTranslatePass(ctx, token, chunks, sourceOption, toLang) {
    var concurrency = Number(ctx.config.bing && ctx.config.bing.concurrency) || 2;
    return await poolMap(chunks, concurrency, function (chunk) {
      return bingTranslateOne(ctx, token, chunk.text, sourceOption, toLang);
    });
  }

  async function bingProvider(ctx, text, sourceOption, targetCanonical) {
    var cfg = ctx.config.bing || {};
    var chunkSize = Number(cfg.chunkSize) > 0 ? Number(cfg.chunkSize) : 900;
    var toLang = bingTargetCode(targetCanonical);
    var chunks = chunkText(text, chunkSize);
    if (!chunks.length) throw new Error('bing: nothing to translate');

    var token = await getBingToken(ctx, false);
    var outcomes = await bingTranslatePass(ctx, token, chunks, sourceOption, toLang);

    var failed = [];
    for (var i = 0; i < outcomes.length; i++) {
      if (!outcomes[i].ok) failed.push(i);
    }
    if (failed.length) {
      var needsTokenRefresh = false;
      for (var f = 0; f < failed.length; f++) {
        if (isBingTokenError(outcomes[failed[f]].error)) needsTokenRefresh = true;
      }
      if (needsTokenRefresh) {
        ctx.log('debug', 'bing token rejected, refreshing once', { failedChunks: failed.length });
        ctx.state.bingToken = null;
        token = await getBingToken(ctx, true);
      }
      var retryChunks = failed.map(function (idx) { return chunks[idx]; });
      var retryOutcomes = await bingTranslatePass(ctx, token, retryChunks, sourceOption, toLang);
      var stillFailed = [];
      for (var r = 0; r < retryOutcomes.length; r++) {
        var originalIndex = failed[r];
        if (retryOutcomes[r].ok) outcomes[originalIndex] = retryOutcomes[r];
        else stillFailed.push(retryOutcomes[r].error);
      }
      if (stillFailed.length) throw stillFailed[0];
    }

    var parts = [];
    var detected = '';
    for (var c = 0; c < chunks.length; c++) {
      if (!outcomes[c] || !outcomes[c].ok) {
        throw (outcomes[c] && outcomes[c].error) || new Error('bing chunk missing');
      }
      parts.push(outcomes[c].value.text);
      if (!detected && outcomes[c].value.detected) detected = outcomes[c].value.detected;
    }

    return {
      text: joinChunkTranslations(chunks, parts, targetCanonical),
      provider: 'bing',
      sourceLang: resolveResultSource(sourceOption, detected, text)
    };
  }

  // =========================================================================
  // Section 7: MyMemory provider (fallback; free API, rate limited)
  // =========================================================================

  async function mymemoryTranslateChunk(ctx, textValue, sourceCanonical, targetCanonical) {
    var cfg = ctx.config.mymemory || {};
    var host = cfg.host || 'api.mymemory.translated.net';
    var langpair = mymemoryLangCode(sourceCanonical) + '|' + mymemoryLangCode(targetCanonical);
    var url = 'https://' + host + '/get?q=' + encodeURIComponent(textValue) +
      '&langpair=' + encodeURIComponent(langpair);
    if (cfg.email) url += '&de=' + encodeURIComponent(String(cfg.email));

    var page = await httpRequest(ctx.state, url, {
      method: 'GET',
      headers: {
        'User-Agent': DESKTOP_UA,
        'Accept': 'application/json, text/plain, */*',
        'Referer': 'https://mymemory.translated.net/'
      },
      timeoutMs: ctx.config.timeoutMs,
      deadline: ctx.deadline
    });
    if (page.statusCode !== 200) throw new Error('mymemory HTTP ' + page.statusCode);

    var data = parseJson(page.body);
    if (!data || typeof data !== 'object') throw new Error('mymemory returned non-JSON response');
    if (data.quotaFinished) throw new Error('mymemory daily quota finished');

    var status = data.responseStatus == null ? 200 : Number(data.responseStatus);
    var details = data.responseDetails ? String(data.responseDetails) : '';
    if (status !== 200) {
      throw new Error('mymemory status ' + status + (details ? ': ' + truncate(details, 120) : ''));
    }
    var translated = data.responseData && data.responseData.translatedText;
    if (typeof translated !== 'string' || !translated) {
      throw new Error('mymemory empty translation');
    }
    if (/MYMEMORY WARNING|QUERY LENGTH LIMIT|INVALID LANGUAGE PAIR|PLEASE SELECT TWO DISTINCT|TOO MANY REQUESTS/i.test(translated)) {
      throw new Error('mymemory: ' + truncate(translated, 140));
    }
    return decodeHtmlEntities(translated);
  }

  async function mymemoryProvider(ctx, text, sourceOption, targetCanonical) {
    var cfg = ctx.config.mymemory || {};
    var chunkSize = Number(cfg.chunkSize) > 0 ? Number(cfg.chunkSize) : 450;

    var sourceCanonical;
    if (sourceOption !== 'auto') {
      sourceCanonical = sourceOption;
    } else {
      var guess = detectLanguageHeuristic(text);
      sourceCanonical = guess === 'zh' ? 'zh' : 'en';
    }

    var chunks = chunkText(text, chunkSize);
    if (!chunks.length) throw new Error('mymemory: nothing to translate');

    // MyMemory needs an explicit source language; concurrency stays gentle.
    var outcomes = await poolMap(chunks, 2, function (chunk) {
      return mymemoryTranslateChunk(ctx, chunk.text, sourceCanonical, targetCanonical);
    });
    var parts = [];
    for (var i = 0; i < outcomes.length; i++) {
      if (!outcomes[i].ok) throw outcomes[i].error || new Error('mymemory chunk failed');
      parts.push(outcomes[i].value);
    }
    return {
      text: joinChunkTranslations(chunks, parts, targetCanonical),
      provider: 'mymemory',
      sourceLang: resolveResultSource(sourceOption, sourceCanonical, text)
    };
  }

  // =========================================================================
  // Section 8: optional LLM provider (OpenAI-compatible chat/completions)
  // =========================================================================

  function llmIsEnabled(config) {
    var llm = config.llm || {};
    return !!(llm.enabled && llm.apiKey && llm.baseUrl);
  }

  async function llmTranslateChunk(ctx, textValue, targetCanonical) {
    var cfg = ctx.config.llm || {};
    var url = String(cfg.baseUrl).replace(/\/+$/, '') + '/chat/completions';
    var systemPrompt = 'You are a professional translator. Translate the text the user sends into ' +
      targetDisplayName(targetCanonical) + '. Preserve all Markdown formatting exactly ' +
      '(headings, lists, emphasis, links, code spans and code blocks). ' +
      'Do not add explanations, notes or quotation marks. Return only the translated text.';

    var payload = {
      model: cfg.model || 'gpt-4o-mini',
      messages: [
        { role: 'system', content: systemPrompt },
        { role: 'user', content: textValue }
      ],
      stream: false
    };
    if (cfg.temperature != null) payload.temperature = Number(cfg.temperature);

    var page = await httpRequest(ctx.state, url, {
      method: 'POST',
      headers: {
        'User-Agent': DESKTOP_UA,
        'Accept': 'application/json',
        'Content-Type': 'application/json',
        'Authorization': 'Bearer ' + cfg.apiKey
      },
      body: JSON.stringify(payload),
      timeoutMs: Number(cfg.timeoutMs) > 0 ? Number(cfg.timeoutMs) : 60000,
      deadline: ctx.deadline
    });
    if (page.statusCode !== 200) {
      throw new Error('llm HTTP ' + page.statusCode);
    }
    var data = parseJson(page.body);
    if (!data || !data.choices || !data.choices[0] || !data.choices[0].message) {
      throw new Error('llm response missing choices[0].message');
    }
    var content = data.choices[0].message.content;
    if (typeof content !== 'string' || !content.trim()) throw new Error('llm returned an empty translation');
    return content.trim();
  }

  async function llmProvider(ctx, text, sourceOption, targetCanonical) {
    if (!llmIsEnabled(ctx.config)) throw new Error('llm provider is not configured/enabled');
    var cfg = ctx.config.llm || {};
    var chunkSize = Number(cfg.chunkSize) > 0 ? Number(cfg.chunkSize) : 3000;
    var chunks = chunkText(text, chunkSize);
    if (!chunks.length) throw new Error('llm: nothing to translate');

    var outcomes = await poolMap(chunks, 1, function (chunk) {
      return llmTranslateChunk(ctx, chunk.text, targetCanonical);
    });
    var parts = [];
    for (var i = 0; i < outcomes.length; i++) {
      if (!outcomes[i].ok) throw outcomes[i].error || new Error('llm chunk failed');
      parts.push(outcomes[i].value);
    }
    var resolved = sourceOption;
    if (resolved === 'auto') resolved = resolveResultSource('auto', '', text);
    return {
      text: joinChunkTranslations(chunks, parts, targetCanonical),
      provider: 'llm',
      sourceLang: resolved
    };
  }

  // =========================================================================
  // Section 9: Youdao dictionary lookup (lookupWord)
  // =========================================================================

  var YOUDAO_HEADERS = {
    'User-Agent': DESKTOP_UA,
    'Accept': 'application/json, text/plain, */*',
    'Referer': 'https://dict.youdao.com/'
  };

  function stripMarkup(text) {
    return String(text || '')
      .replace(/<[^>]*>/g, '')
      .replace(/\s+/g, ' ')
      .trim();
  }

  // Youdao trs nodes look like: [{tr:[{l:{i:["int. 你好..."]}}]}]
  function parseYoudaoTrs(trsNodes, translations, seen) {
    if (!Array.isArray(trsNodes)) return;
    for (var i = 0; i < trsNodes.length; i++) {
      var node = trsNodes[i];
      if (!node || !Array.isArray(node.tr)) continue;
      for (var j = 0; j < node.tr.length; j++) {
        var tr = node.tr[j];
        var l = tr && tr.l;
        if (!l || l.i == null) continue;
        var lines = Array.isArray(l.i) ? l.i : [l.i];
        for (var k = 0; k < lines.length; k++) {
          addDictionaryDef(translations, seen, lines[k]);
        }
      }
    }
  }

  function addDictionaryDef(translations, seen, raw) {
    if (typeof raw !== 'string') return;
    var line = stripMarkup(decodeHtmlEntities(raw));
    if (!line) return;
    var pos = '';
    var m = /^([a-zA-Z]+\.)\s*/.exec(line);
    if (m) {
      pos = m[1];
      line = line.slice(m[0].length).trim();
    }
    if (!line) return;
    var key = pos + '|' + line;
    if (seen[key]) return;
    seen[key] = true;
    translations.push({ pos: pos, def: line });
  }

  function parseYoudaoJsonapi(data, word) {
    if (!data || typeof data !== 'object') return null;
    var phoneticUk = '';
    var phoneticUs = '';
    var translations = [];
    var seen = {};

    // Primary dictionary section: ec.word is an ARRAY of entries.
    if (data.ec && Array.isArray(data.ec.word)) {
      for (var i = 0; i < data.ec.word.length && i < 5; i++) {
        var entry = data.ec.word[i];
        if (!entry || typeof entry !== 'object') continue;
        if (!phoneticUk && typeof entry.ukphone === 'string') phoneticUk = entry.ukphone;
        if (!phoneticUs && typeof entry.usphone === 'string') phoneticUs = entry.usphone;
        parseYoudaoTrs(entry.trs, translations, seen);
      }
    }

    // Phonetic fallback from the lightweight "simple" block.
    if ((!phoneticUk || !phoneticUs) && data.simple && Array.isArray(data.simple.word) && data.simple.word[0]) {
      var sw = data.simple.word[0];
      if (!phoneticUk && typeof sw.ukphone === 'string') phoneticUk = sw.ukphone;
      if (!phoneticUs && typeof sw.usphone === 'string') phoneticUs = sw.usphone;
    }

    // English-English section fallback (when present).
    if (!translations.length && data.ee && data.ee.word) {
      var eeWord = Array.isArray(data.ee.word) ? data.ee.word[0] : data.ee.word;
      if (eeWord && typeof eeWord === 'object') {
        if (!phoneticUk && typeof eeWord.ukphone === 'string') phoneticUk = eeWord.ukphone;
        if (!phoneticUs && typeof eeWord.usphone === 'string') phoneticUs = eeWord.usphone;
        parseYoudaoTrs(eeWord.trs, translations, seen);
      }
    }

    // Web-translation fallback so we can still return useful defs.
    if (!translations.length && data.web_trans && Array.isArray(data.web_trans['web-translation'])) {
      var web = data.web_trans['web-translation'];
      var target = null;
      var wanted = String(word || '').toLowerCase();
      for (var w = 0; w < web.length; w++) {
        if (web[w] && typeof web[w].key === 'string' && web[w].key.toLowerCase() === wanted) {
          target = web[w];
          break;
        }
      }
      if (!target) target = web[0];
      if (target && Array.isArray(target.trans)) {
        for (var t = 0; t < target.trans.length; t++) {
          var val = target.trans[t] && target.trans[t].value;
          if (typeof val === 'string' && val.trim()) {
            addDictionaryDef(translations, seen, val);
          }
        }
      }
    }

    // Cap the list so the UI stays small.
    if (translations.length > 10) translations = translations.slice(0, 10);

    var phonetic = phoneticUk || phoneticUs || '';
    if (!translations.length && !phonetic) return null;
    return {
      phonetic: phonetic,
      phonetics: { uk: phoneticUk, us: phoneticUs },
      translations: translations
    };
  }

  // Lightweight fallback endpoint: dict.youdao.com/suggest?le=en&q=word
  function parseYoudaoSuggest(data, word) {
    if (!data || !data.data || !Array.isArray(data.data.entries)) return null;
    var wanted = String(word || '').toLowerCase();
    var chosen = null;
    for (var i = 0; i < data.data.entries.length; i++) {
      var entry = data.data.entries[i];
      if (entry && typeof entry.entry === 'string' && entry.entry.toLowerCase() === wanted) {
        chosen = entry;
        break;
      }
    }
    if (!chosen) return null;
    var explain = stripMarkup(decodeHtmlEntities(chosen.explain || ''));
    if (!explain) return null;

    var translations = [];
    var seen = {};
    var pos = '';
    var segments = explain.split(/[；;]/);
    for (var s = 0; s < segments.length; s++) {
      var seg = segments[s].trim();
      if (!seg) continue;
      var m = /^([a-zA-Z]+\.)\s*/.exec(seg);
      if (m) { pos = m[1]; seg = seg.slice(m[0].length).trim(); }
      if (!seg) continue;
      var key = pos + '|' + seg;
      if (seen[key]) continue;
      seen[key] = true;
      translations.push({ pos: pos, def: seg });
      if (translations.length >= 10) break;
    }
    if (!translations.length) return null;
    return { phonetic: '', phonetics: { uk: '', us: '' }, translations: translations };
  }

  async function youdaoLookup(ctx, word) {
    var cfg = ctx.config.youdao || {};
    var host = cfg.host || 'dict.youdao.com';
    var firstError = null;

    // 1) Full dictionary entry.
    try {
      var page = await httpRequest(ctx.state, 'https://' + host + '/jsonapi?q=' +
        encodeURIComponent(word) + '&dict=ec', {
        method: 'GET',
        headers: YOUDAO_HEADERS,
        timeoutMs: ctx.config.timeoutMs,
        deadline: ctx.deadline
      });
      if (page.statusCode !== 200) throw new Error('HTTP ' + page.statusCode);
      var parsed = parseYoudaoJsonapi(parseJson(page.body), word);
      if (parsed) return parsed;
      firstError = new Error('no dictionary entry found');
    } catch (e) {
      firstError = e;
    }

    // 2) Suggest endpoint fallback (still graceful on failure).
    try {
      var le = RE_HAN.test(word) ? 'zh' : 'en';
      var suggest = await httpRequest(ctx.state, 'https://' + host + '/suggest?num=5&ver=3.0&doctype=json&cache=false&le=' +
        le + '&q=' + encodeURIComponent(word), {
        method: 'GET',
        headers: YOUDAO_HEADERS,
        timeoutMs: ctx.config.timeoutMs,
        deadline: ctx.deadline
      });
      if (suggest.statusCode === 200) {
        var suggestParsed = parseYoudaoSuggest(parseJson(suggest.body), word);
        if (suggestParsed) return suggestParsed;
      }
    } catch (e2) {
      if (!firstError) firstError = e2;
    }

    throw new Error('youdao: ' + errMsg(firstError || 'no entry'));
  }

  // =========================================================================
  // Section 10: service factory / public API
  // =========================================================================

  var DEFAULT_CONFIG = {
    providers: ['bing', 'mymemory'],
    timeoutMs: HTTP_TIMEOUT_MS,       // hard cap per HTTP request
    totalTimeoutMs: 30000,            // hard cap for one translate()/lookupWord()
    cacheSize: 100,
    maxCacheTextLength: 100000,
    maxTextLength: 100000,
    bing: {
      host: 'cn.bing.com',
      fallbackHost: 'www.bing.com',
      tokenTtlMs: 600000,             // cache the token ~10 minutes
      chunkSize: 900,
      concurrency: 2
    },
    mymemory: {
      host: 'api.mymemory.translated.net',
      chunkSize: 450,
      email: ''
    },
    youdao: {
      host: 'dict.youdao.com'
    },
    llm: {
      enabled: false,
      baseUrl: '',
      apiKey: '',
      model: '',
      chunkSize: 3000,
      temperature: null,
      timeoutMs: 60000
    }
  };

  var TRANSLATE_PROVIDERS = {
    bing: bingProvider,
    mymemory: mymemoryProvider,
    llm: llmProvider
  };

  function normalizeProviders(list) {
    if (!Array.isArray(list)) return DEFAULT_CONFIG.providers.slice();
    var out = [];
    for (var i = 0; i < list.length; i++) {
      if (typeof list[i] !== 'string') continue;
      var name = list[i].trim().toLowerCase();
      if (name) out.push(name);
    }
    return out.length ? out : DEFAULT_CONFIG.providers.slice();
  }

  function makeFailure(error, provider) {
    return { ok: false, error: errMsg(error), provider: provider || '' };
  }

  /**
   * Create a translation service instance.
   * options: { log: function(level,msg,extra){}, config: {...}, appName: '...' }
   */
  function createService(options) {
    options = options || {};
    var config = deepMerge(DEFAULT_CONFIG, options.config || {});
    var userLog = typeof options.log === 'function' ? options.log : null;
    var appName = options.appName ? String(options.appName) : 'typora-translate';
    var state = {
      httpsModule: null,
      bingToken: null,
      lastProvider: null,
      lastError: null
    };
    var cache = new LruCache(config.cacheSize);

    function log(level, msg, extra) {
      if (!userLog) return;
      try {
        userLog(level, '[' + appName + '] ' + msg, extra);
      } catch (e) {
        /* user logger must never break translation */
      }
    }

    function makeCtx(deadline) {
      return { config: config, state: state, log: log, deadline: deadline };
    }

    function deadlineFrom(startedAt) {
      var total = Number(config.totalTimeoutMs);
      if (!(total > 0)) total = 30000;
      return startedAt + total;
    }

    function rememberProvider(name) {
      state.lastProvider = name;
      state.lastError = null;
    }

    async function translate(text, opts) {
      var startedAt = nowMs();
      try {
        opts = opts || {};
        if (typeof text !== 'string') return makeFailure('text must be a string', '');
        if (!text.trim()) return makeFailure('empty text', '');
        var maxText = Number(config.maxTextLength) > 0 ? Number(config.maxTextLength) : 100000;
        if (text.length > maxText) {
          return makeFailure('text too long (max ' + maxText + ' chars)', '');
        }

        var target = normalizeTargetLang(opts.targetLang);
        var sourceOption = normalizeSourceLangOption(opts.sourceLang);
        var providers = normalizeProviders(config.providers);

        // Same-language no-op (explicit source only; auto must go to network).
        if (sourceOption !== 'auto' && sourceOption === target) {
          rememberProvider('none');
          return {
            ok: true,
            text: text,
            provider: 'none',
            sourceLang: sourceOption,
            targetLang: target,
            cached: false,
            elapsedMs: nowMs() - startedAt
          };
        }

        // LRU cache lookup: key = provider|src|tgt|text.
        var cachedEntry = findCachedEntry(cache, text, providers, sourceOption, target);
        if (cachedEntry) {
          rememberProvider(cachedEntry.provider);
          log('debug', 'cache hit', { provider: cachedEntry.provider, chars: text.length });
          return {
            ok: true,
            text: cachedEntry.text,
            provider: cachedEntry.provider,
            sourceLang: cachedEntry.sourceLang,
            targetLang: target,
            cached: true,
            elapsedMs: nowMs() - startedAt
          };
        }

        var ctx = makeCtx(deadlineFrom(startedAt));
        var errors = [];
        var lastTried = '';
        for (var i = 0; i < providers.length; i++) {
          var name = providers[i];
          var impl = TRANSLATE_PROVIDERS[name];
          lastTried = name;
          if (!impl) {
            errors.push(name + ': unknown provider');
            continue;
          }
          try {
            var result = await impl(ctx, text, sourceOption, target);
            if (!result || typeof result.text !== 'string' || !result.text) {
              throw new Error('provider returned an empty translation');
            }
            var sourceLang = result.sourceLang || (sourceOption === 'auto' ? 'auto' : sourceOption);
            var entry = {
              text: result.text,
              provider: name,
              sourceLang: sourceLang,
              targetLang: target,
              ts: nowMs()
            };
            var cacheLimit = Number(config.maxCacheTextLength) > 0 ? Number(config.maxCacheTextLength) : 100000;
            if (text.length <= cacheLimit) {
              cache.set(cacheKey(name, sourceLang, target, text), entry);
            }
            rememberProvider(name);
            var elapsed = nowMs() - startedAt;
            log('info', 'translated', {
              provider: name,
              sourceLang: sourceLang,
              targetLang: target,
              chars: text.length,
              elapsedMs: elapsed
            });
            return {
              ok: true,
              text: entry.text,
              provider: name,
              sourceLang: sourceLang,
              targetLang: target,
              cached: false,
              elapsedMs: elapsed
            };
          } catch (e) {
            var msg = errMsg(e);
            errors.push(name + ': ' + msg);
            log('warn', 'provider failed', { provider: name, error: truncate(msg, 200) });
            if (isBingTokenError(e)) state.bingToken = null;
          }
        }

        var fullError = 'all providers failed: ' + errors.join('; ');
        state.lastError = fullError;
        log('error', 'translate failed', { error: truncate(fullError, 300) });
        return makeFailure(fullError, lastTried);
      } catch (e) {
        var fatal = errMsg(e);
        state.lastError = fatal;
        log('error', 'translate crashed (caught)', { error: truncate(fatal, 200) });
        return makeFailure(fatal, '');
      }
    }

    async function lookupWord(word) {
      try {
        if (typeof word !== 'string') return makeFailure('word must be a string', 'youdao');
        var trimmed = word.trim();
        if (!trimmed) return makeFailure('empty word', 'youdao');
        if (trimmed.length > 200) return makeFailure('word too long (max 200 chars)', 'youdao');

        var startedAt = nowMs();
        var ctx = makeCtx(deadlineFrom(startedAt));
        var entry = await youdaoLookup(ctx, trimmed);
        log('debug', 'lookupWord ok', { word: truncate(trimmed, 40), defs: entry.translations.length });
        return {
          ok: true,
          word: trimmed,
          phonetic: entry.phonetic || '',
          phonetics: entry.phonetics || { uk: '', us: '' },
          translations: entry.translations || [],
          provider: 'youdao'
        };
      } catch (e) {
        var msg = errMsg(e);
        state.lastError = msg;
        log('warn', 'lookupWord failed', { error: truncate(msg, 200) });
        return makeFailure(msg, 'youdao');
      }
    }

    function detectLanguage(text) {
      return detectLanguageHeuristic(text);
    }

    function clearCache() {
      cache.clear();
      log('debug', 'cache cleared');
    }

    function getStatus() {
      return {
        cacheSize: cache.size(),
        lastProvider: state.lastProvider,
        lastError: state.lastError
      };
    }

    return {
      translate: translate,
      lookupWord: lookupWord,
      detectLanguage: detectLanguage,
      clearCache: clearCache,
      getStatus: getStatus
    };
  }

  // =========================================================================
  // Section 11: UMD-style export
  // =========================================================================

  var api = {
    version: VERSION,
    createService: createService,
    detectLanguage: detectLanguageHeuristic
  };

  if (typeof window !== 'undefined' && window) {
    window.TyTranslateService = api;
  }
  if (typeof module === 'object' && module && module.exports) {
    module.exports = api;
  } else if (typeof globalThis !== 'undefined' && globalThis && !globalThis.TyTranslateService) {
    // Non-window, non-CommonJS host (rare): still expose the service.
    globalThis.TyTranslateService = api;
  }
})();