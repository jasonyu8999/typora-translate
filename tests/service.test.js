#!/usr/bin/env node
/**
 * typora-translate / service.test.js
 * ---------------------------------------------------------------------------
 * Integration tests for src/plugin/service.js, executed against the LIVE
 * network from this machine (Bing web translator + MyMemory + Youdao).
 *
 * Run with Node.js 16+ (the script has zero third-party dependencies):
 *   node typora-translate/tests/service.test.js
 *
 * Prints one PASS/FAIL line per assertion, a short summary, and exits with
 * code 1 if anything failed.
 */
'use strict';

const fs = require('fs');
const path = require('path');
const vm = require('vm');

const ROOT = path.join(__dirname, '..');
const SERVICE_PATH = path.join(ROOT, 'src', 'plugin', 'service.js');
const FIXTURES = path.join(__dirname, 'fixtures');

const TyTranslateService = require(SERVICE_PATH);

// ---------------------------------------------------------------------------
// tiny test harness
// ---------------------------------------------------------------------------
let passed = 0;
let failed = 0;
const failedNames = [];

function check(name, condition, detail) {
  if (condition) {
    passed++;
    console.log('PASS  ' + name);
  } else {
    failed++;
    failedNames.push(name);
    console.log('FAIL  ' + name + (detail ? '  [' + detail + ']' : ''));
  }
}

function note(message) {
  console.log('      note: ' + message);
}

function countCjk(text) {
  const m = String(text || '').match(/[\u4e00-\u9fff]/g);
  return m ? m.length : 0;
}

function countLatin(text) {
  const m = String(text || '').match(/[A-Za-z]/g);
  return m ? m.length : 0;
}

function readFixture(name) {
  return fs.readFileSync(path.join(FIXTURES, name), 'utf8');
}

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

async function expectNoThrow(name, fn) {
  let result;
  let threw = null;
  try {
    result = await fn();
  } catch (e) {
    threw = e;
  }
  check(name, !threw && result && result.ok === false,
    threw ? 'threw ' + threw.message : 'result=' + JSON.stringify(result).slice(0, 160));
}

// ---------------------------------------------------------------------------
// tests
// ---------------------------------------------------------------------------
async function main() {
  const startedAt = Date.now();

  console.log('== typora-translate service.test.js (live network) ==');

  // ---- 1. module / API shape ------------------------------------------------
  check('module exports createService + version',
    typeof TyTranslateService.createService === 'function' &&
    typeof TyTranslateService.version === 'string');

  let svc;
  let createThrew = false;
  try {
    svc = TyTranslateService.createService({ log: function () {}, appName: 'typora-translate' });
  } catch (e) {
    createThrew = true;
  }
  check('createService({log, appName}) works', !createThrew && !!svc);
  check('service API shape',
    svc && ['translate', 'lookupWord', 'detectLanguage', 'clearCache', 'getStatus']
      .every(function (k) { return typeof svc[k] === 'function'; }));

  // ---- 2. detectLanguage ----------------------------------------------------
  check('detectLanguage("The experiment yielded significant results.") === en',
    svc.detectLanguage('The experiment yielded significant results.') === 'en');
  check('detectLanguage("实验结果表明该方法具有显著优势。") === zh',
    svc.detectLanguage('实验结果表明该方法具有显著优势。') === 'zh');
  check('detectLanguage("12345 --- !!!") === other',
    svc.detectLanguage('12345 --- !!!') === 'other');

  // ---- 3. translate en -> zh (live) ----------------------------------------
  const sentence = 'The results of this experiment are statistically significant.';
  const r1 = await svc.translate(sentence, { targetLang: 'zh-Hans', sourceLang: 'auto' });
  check('translate en->zh returns ok:true', !!(r1 && r1.ok === true), r1 && r1.error);
  check('translate en->zh result contains CJK chars', r1 && r1.ok && countCjk(r1.text) >= 4,
    r1 && r1.ok ? 'text=' + JSON.stringify(r1.text) : 'no result');
  check('translate en->zh provider is bing or mymemory',
    r1 && r1.ok && (r1.provider === 'bing' || r1.provider === 'mymemory'),
    r1 && ('provider=' + r1.provider));
  check('translate en->zh sourceLang === en', r1 && r1.sourceLang === 'en',
    r1 && 'sourceLang=' + r1.sourceLang);
  check('translate en->zh targetLang canonical zh-Hans', r1 && r1.targetLang === 'zh-Hans',
    r1 && 'targetLang=' + r1.targetLang);
  check('translate en->zh cached === false', r1 && r1.cached === false);
  check('translate en->zh elapsedMs is a number', r1 && typeof r1.elapsedMs === 'number' && r1.elapsedMs >= 0);
  if (r1 && r1.ok) note('provider=' + r1.provider + ' elapsed=' + r1.elapsedMs + 'ms text=' + JSON.stringify(r1.text));

  // ---- 4. cache hit (including zh-CN alias canonicalisation) ---------------
  const r2 = await svc.translate(sentence, { targetLang: 'zh-CN' });
  check('cache hit cached === true', r2 && r2.ok && r2.cached === true,
    r2 && JSON.stringify({ ok: r2.ok, cached: r2.cached, provider: r2.provider }));
  check('cache hit returns identical text', r2 && r2.ok && r1 && r2.text === r1.text);
  check('cache hit normalises zh-CN target to zh-Hans', r2 && r2.targetLang === 'zh-Hans',
    r2 && 'targetLang=' + r2.targetLang);

  // ---- 5. translate zh -> en (live) ---------------------------------------
  const zhText = readFixture('short-academic-zh.txt');
  const r3 = await svc.translate(zhText, { targetLang: 'en' });
  check('translate zh->en returns ok:true', !!(r3 && r3.ok === true), r3 && r3.error);
  check('translate zh->en output has Latin words', r3 && r3.ok && countLatin(r3.text) > 20,
    r3 && r3.ok ? 'text=' + JSON.stringify(r3.text).slice(0, 120) : 'no result');
  check('translate zh->en output has no CJK left', r3 && r3.ok && countCjk(r3.text) === 0,
    r3 && r3.ok ? 'cjk=' + countCjk(r3.text) : 'no result');
  check('translate zh->en sourceLang === zh', r3 && r3.sourceLang === 'zh',
    r3 && 'sourceLang=' + r3.sourceLang);
  if (r3 && r3.ok) note('provider=' + r3.provider + ' elapsed=' + r3.elapsedMs + 'ms');

  // ---- 6. long fixture: chunking (>1500 chars) -----------------------------
  const longText = readFixture('long-en.md');
  check('long fixture is >1500 chars', longText.length > 1500, 'len=' + longText.length);
  const r4 = await svc.translate(longText, { targetLang: 'zh-Hans' });
  check('long translate returns ok:true', !!(r4 && r4.ok === true), r4 && r4.error);
  check('long translate output has many CJK chars', r4 && r4.ok && countCjk(r4.text) > 100,
    r4 && r4.ok ? 'cjk=' + countCjk(r4.text) : 'no result');
  check('long translate respects total timeout (<25s)', r4 && r4.ok && r4.elapsedMs < 25000,
    r4 && ('elapsed=' + r4.elapsedMs + 'ms'));
  check('long translate provider is live', r4 && r4.ok &&
    (r4.provider === 'bing' || r4.provider === 'mymemory'), r4 && ('provider=' + r4.provider));
  if (r4 && r4.ok) {
    note('long: out=' + r4.text.length + ' chars, cjk=' + countCjk(r4.text) +
      ', provider=' + r4.provider + ', elapsed=' + r4.elapsedMs + 'ms');
  }

  // ---- 7. lookupWord('hello') (live) --------------------------------------
  const words = readFixture('words.txt').split(/\r?\n/).filter(Boolean);
  const lookupWordValue = words[0] || 'hello';
  const w1 = await svc.lookupWord(lookupWordValue);
  check('lookupWord("' + lookupWordValue + '") ok:true', !!(w1 && w1.ok === true), w1 && w1.error);
  check('lookupWord provider youdao', w1 && w1.provider === 'youdao', w1 && ('provider=' + w1.provider));
  check('lookupWord has phonetic or translations',
    w1 && w1.ok && (!!w1.phonetic || (Array.isArray(w1.translations) && w1.translations.length > 0)),
    w1 && JSON.stringify(w1).slice(0, 200));
  check('lookupWord translations have pos/def strings',
    w1 && w1.ok && Array.isArray(w1.translations) &&
    w1.translations.length > 0 &&
    w1.translations.every(function (t) {
      return t && typeof t.pos === 'string' && typeof t.def === 'string' && t.def.length > 0;
    }),
    w1 && JSON.stringify(w1.translations || []).slice(0, 160));
  if (w1 && w1.ok) {
    note('hello: phonetic=' + JSON.stringify(w1.phonetic) +
      ' defs=' + (w1.translations || []).length +
      ' first=' + JSON.stringify((w1.translations || [])[0] || null));
  }

  // ---- 8. lookupWord junk word degrades gracefully ------------------------
  const w2 = await svc.lookupWord('zzquuxnotaword');
  check('lookupWord(junk) returns ok:false without throwing', !!(w2 && w2.ok === false),
    w2 && JSON.stringify(w2).slice(0, 160));

  // ---- 9. bad input never throws -----------------------------------------
  await expectNoThrow('translate("") -> ok:false', function () { return svc.translate(''); });
  await expectNoThrow('translate(null) -> ok:false', function () { return svc.translate(null); });
  await expectNoThrow('translate(123) -> ok:false', function () { return svc.translate(123); });
  await expectNoThrow('translate("   ") -> ok:false', function () { return svc.translate('   '); });
  await expectNoThrow('translate(undefined) -> ok:false', function () { return svc.translate(undefined); });
  await expectNoThrow('translate(oversized string) -> ok:false', function () {
    return svc.translate(new Array(200000).join('a'));
  });
  await expectNoThrow('lookupWord("") -> ok:false', function () { return svc.lookupWord(''); });
  await expectNoThrow('lookupWord(null) -> ok:false', function () { return svc.lookupWord(null); });

  // ---- 10. misconfiguration fails fast and does not hang ------------------
  const bogusSvc = TyTranslateService.createService({ config: { providers: ['bogus'] } });
  const bogusStart = Date.now();
  const rb = await bogusSvc.translate('Hello world');
  const bogusElapsed = Date.now() - bogusStart;
  check('unknown provider -> ok:false', rb && rb.ok === false);
  check('unknown provider fails fast (<2s)', bogusElapsed < 2000, 'elapsed=' + bogusElapsed + 'ms');

  const llmOffSvc = TyTranslateService.createService({ config: { providers: ['llm'] } });
  const rl = await llmOffSvc.translate('Hello world');
  check('disabled llm provider -> ok:false mentioning llm',
    rl && rl.ok === false && /llm/i.test(rl.error), rl && rl.error);

  // ---- 11. bing unreachable -> mymemory fallback must still return ok:true
  const fallbackSvc = TyTranslateService.createService({
    config: {
      providers: ['bing', 'mymemory'],
      bing: { host: 'invalid.invalid', fallbackHost: 'invalid.invalid' }
    }
  });
  const fallbackStart = Date.now();
  let rf = await fallbackSvc.translate('Machine translation has improved a lot in recent years.');
  if (!rf.ok) {
    // MyMemory can transiently rate-limit; one retry keeps the suite stable.
    await sleep(1500);
    rf = await fallbackSvc.translate('Machine translation has improved a lot in recent years.');
  }
  const fallbackElapsed = Date.now() - fallbackStart;
  check('bing failure -> mymemory fallback returns ok:true', !!(rf && rf.ok === true),
    rf && JSON.stringify(rf).slice(0, 200));
  check('fallback provider is mymemory', rf && rf.ok && rf.provider === 'mymemory',
    rf && ('provider=' + rf.provider));
  check('fallback output contains CJK', rf && rf.ok && countCjk(rf.text) >= 4,
    rf && rf.ok ? 'text=' + JSON.stringify(rf.text) : 'no result');
  note('fallback elapsed=' + fallbackElapsed + 'ms text=' + (rf && rf.ok ? JSON.stringify(rf.text) : 'n/a'));

  // ---- 12. status / cache -------------------------------------------------
  const status = svc.getStatus();
  check('getStatus returns {cacheSize,lastProvider,lastError}',
    status && typeof status.cacheSize === 'number' &&
    Object.prototype.hasOwnProperty.call(status, 'lastProvider') &&
    Object.prototype.hasOwnProperty.call(status, 'lastError'),
    JSON.stringify(status));
  check('getStatus cacheSize > 0 after translations', status && status.cacheSize > 0,
    'cacheSize=' + (status && status.cacheSize));
  svc.clearCache();
  check('clearCache empties the cache', svc.getStatus().cacheSize === 0);

  // ---- 13. youdao unreachable degrades gracefully ------------------------
  const youdaoSvc = TyTranslateService.createService({ config: { youdao: { host: 'invalid.invalid' } } });
  const w3 = await youdaoSvc.lookupWord('hello');
  check('lookupWord with unreachable youdao -> ok:false', w3 && w3.ok === false,
    w3 && JSON.stringify(w3).slice(0, 160));

  // ---- 14. Typora renderer contract: window.reqnode, NO require ----------
  const source = fs.readFileSync(SERVICE_PATH, 'utf8');
  const fakeWindow = {
    reqnode: function (name) { return require(name); }
  };
  const sandbox = {
    window: fakeWindow,
    console: console,
    setTimeout: setTimeout,
    clearTimeout: clearTimeout
  };
  vm.createContext(sandbox);
  vm.runInContext(source, sandbox, { filename: 'service.js (reqnode sandbox)' });
  const rendererApi = fakeWindow.TyTranslateService;
  check('UMD attaches window.TyTranslateService (reqnode sandbox, no require)',
    rendererApi && typeof rendererApi.createService === 'function' &&
    typeof rendererApi.detectLanguage === 'function');

  const rendererSvc = rendererApi.createService({ appName: 'renderer-test' });
  const rendererResult = await rendererSvc.translate('Hello from the Typora renderer sandbox.');
  check('renderer path (window.reqnode) translates via live network',
    rendererResult && rendererResult.ok === true && countCjk(rendererResult.text) >= 2,
    rendererResult && (rendererResult.error || JSON.stringify(rendererResult.text)));
  if (rendererResult && rendererResult.ok) {
    note('renderer provider=' + rendererResult.provider + ' text=' + JSON.stringify(rendererResult.text));
  }

  // ---- 15. optional llm provider: enabled but unreachable -> falls back ---
  const llmLogs = [];
  const llmSvc = TyTranslateService.createService({
    log: function (level, msg, extra) {
      llmLogs.push(String(msg) + ' ' + JSON.stringify(extra || {}));
    },
    config: {
      providers: ['llm', 'bing'],
      llm: {
        enabled: true,
        baseUrl: 'https://invalid.invalid/v1',
        apiKey: 'sk-test-not-real',
        model: 'test-model'
      }
    }
  });
  const rllm = await llmSvc.translate('Please verify the optional provider fallback path.');
  check('enabled but unreachable llm falls back to bing',
    rllm && rllm.ok === true && rllm.provider === 'bing',
    rllm && (rllm.error || 'provider=' + rllm.provider));
  const keyLeaked = llmLogs.some(function (m) { return m.indexOf('sk-test-not-real') >= 0; }) ||
    (rllm && String(rllm.error || '').indexOf('sk-test-not-real') >= 0);
  check('llm api key never appears in logs or errors', !keyLeaked);

  // ---- summary ------------------------------------------------------------
  const elapsed = Date.now() - startedAt;
  console.log('----------------------------------------');
  console.log(passed + ' passed, ' + failed + ' failed in ' + elapsed + 'ms');
  if (failed) {
    console.log('FAILED: ' + failedNames.join(' | '));
  }
  process.exitCode = failed ? 1 : 0;
}

main().catch(function (e) {
  console.error('TEST HARNESS ERROR: ' + (e && e.stack ? e.stack : e));
  process.exitCode = 1;
});