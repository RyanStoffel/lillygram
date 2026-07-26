// Runtime initialization proof for ContentFilter.script.
//
// Injects the extracted userscript into a jsdom window at document-start
// (before the HTML is parsed, i.e. document.body === null, exactly as
// WKUserScriptInjectionTime.atDocumentStart does) and asserts that
// initialization runs to completion: setFavorites applies, the hook
// installers run, and the MutationObserver actually starts observing
// document.body and then delivers mutations.
//
// Usage: node runner.js <path-to-extracted.js>

const fs = require('fs');
const { JSDOM, VirtualConsole } = require('jsdom');

const scriptPath = process.argv[2] || 'filter.js';
const source = fs.readFileSync(scriptPath, 'utf8');

const logs = [];
const thrown = [];
const observeCalls = [];
let mutationBatches = 0;

const virtualConsole = new VirtualConsole();
virtualConsole.on('jsdomError', (e) => thrown.push('jsdomError: ' + e.message));

const dom = new JSDOM(
  `<!DOCTYPE html><html><head></head><body>
     <main>
       <article><a href="/algoaccount/">algoaccount</a></article>
       <article><a href="/favedaccount/">favedaccount</a></article>
     </main>
   </body></html>`,
  {
    url: 'https://www.instagram.com/',
    runScripts: 'outside-only',
    pretendToBeVisual: true,
    virtualConsole,
    beforeParse(window) {
      // --- native preamble (WebViewStore.installUserScripts) ---
      window.__biFavorites = ['favedaccount', 'someoneelse'];
      window.__biFavoritesEnabled = true;
      window.__biFavEdgesPreload = JSON.stringify({
        edges: [{ node: { media: { pk: '100', user: { username: 'favedaccount' }, image_versions2: { candidates: [{ url: 'https://example.com/a.jpg' }] } } } }]
      });

      // --- WKScriptMessageHandler shim ---
      const post = (name) => (body) => logs.push([name, body]);
      window.webkit = {
        messageHandlers: {
          biLog: { postMessage: post('biLog') },
          biNav: { postMessage: post('biNav') },
          biAvatar: { postMessage: post('biAvatar') },
          biProfile: { postMessage: post('biProfile') },
          biBg: { postMessage: post('biBg') },
          biPresentation: { postMessage: post('biPresentation') },
          biFavEdit: { postMessage: post('biFavEdit') },
          biFavReady: { postMessage: post('biFavReady') },
          biFeedStuck: { postMessage: post('biFeedStuck') },
        },
      };

      // --- gaps in jsdom that the real WKWebView provides ---
      if (!window.document.elementsFromPoint) {
        window.document.elementsFromPoint = () => [];
      }
      if (!window.document.elementFromPoint) {
        window.document.elementFromPoint = () => null;
      }
      window.devicePixelRatio = 3;

      // --- instrument MutationObserver so observer startup is observable ---
      const RealMO = window.MutationObserver;
      class ProbedMutationObserver extends RealMO {
        constructor(cb) {
          super(function (mutations, obs) {
            mutationBatches++;
            return cb.call(this, mutations, obs);
          });
        }
        observe(target, options) {
          observeCalls.push({
            target: target === window.document.body ? 'document.body' : String(target),
            options,
          });
          return super.observe(target, options);
        }
      }
      window.MutationObserver = ProbedMutationObserver;

      // --- run the userscript at document-start ---
      if (window.document.body !== null) {
        thrown.push('harness bug: body already exists, not a document-start injection');
      }
      try {
        window.eval(source);
      } catch (e) {
        thrown.push('THREW during initialization: ' + (e && e.stack ? e.stack : e));
      }
    },
  }
);

const { window } = dom;

function biLogs() {
  return logs.filter((l) => l[0] === 'biLog').map((l) => l[1]);
}

function has(pattern) {
  return biLogs().some((l) => (pattern instanceof RegExp ? pattern.test(l) : l.includes(pattern)));
}

const checks = [];
function check(name, ok, detail) {
  checks.push({ name, ok: !!ok, detail });
}

// Give scheduleApply()'s 300ms throttle + rAF, and start()'s rAF retry loop,
// time to run.
setTimeout(() => {
  // Prove the observer is live by mutating the DOM after initialization.
  const injected = window.document.createElement('article');
  injected.innerHTML = '<a href="/lateaccount/">lateaccount</a>';
  window.document.querySelector('main').appendChild(injected);

  setTimeout(() => {
    check('script did not throw during initialization', thrown.length === 0, thrown.join('\n'));
    check('reached [boot] log', has('[boot] filter running on /'));
    check(
      'setFavorites() completed (favorites applied)',
      has(/\[favorites\] enabled=true count=2/),
      biLogs().filter((l) => l.startsWith('[favorites]')).join(' | ')
    );
    check('window.__biSetFavorites installed', typeof window.__biSetFavorites === 'function');
    check('window.__biReapply installed', typeof window.__biReapply === 'function');
    check('window.__biSetFavEdges installed', typeof window.__biSetFavEdges === 'function');
    check('XHR hook installed', window.__biXHRPatched === true);
    check('history hook installed', window.__biHistoryPatched === true || has('[boot]'));
    check(
      'MutationObserver.observe() called on document.body',
      observeCalls.some((c) => c.target === 'document.body' && c.options && c.options.subtree),
      JSON.stringify(observeCalls)
    );
    check('exactly one observer started (no duplicate handlers)', observeCalls.length === 1,
      'observe() calls: ' + observeCalls.length);
    check('observer delivered mutations after init', mutationBatches > 0,
      'batches: ' + mutationBatches);
    check('apply() ran without error', !has('[error] apply failed'),
      biLogs().filter((l) => l.startsWith('[error]')).join(' | '));

    const presentations = () => logs.filter((l) => l[0] === 'biPresentation');
    const lastPresentation = () => {
      const p = presentations();
      return p.length ? p[p.length - 1][1] : null;
    };
    const navigate = (path) => {
      const before = presentations().length;
      window.history.pushState({}, '', path);
      return presentations().length - before;
    };

    // --- SSR splice biFavReady post check ---
    // Simulating Instagram's bootloader parsing streamed SSR JSON containing feed__timeline
    window.JSON.parse(JSON.stringify({ data: { feed__timeline: { edges: [] } } }));
    check('SSR feed splice posts biFavReady',
      logs.some((l) => l[0] === 'biFavReady'),
      'logs: ' + JSON.stringify(logs.filter((l) => l[0] === 'biFavReady')));

    // Native live-update path (WebViewStore.applyFavoritesSelection).
    let liveUpdateOk = true;
    let liveUpdateErr = '';
    try {
      window.__biSetFavorites(['a', 'b', 'c'], true);
    } catch (e) {
      liveUpdateOk = false;
      liveUpdateErr = String(e);
    }
    check('live __biSetFavorites() re-entry works', liveUpdateOk && has(/count=3/), liveUpdateErr);

    // --- fail-closed path: harvest returns nothing ---
    check('biFeedStuck not posted while healthy',
      !logs.some((l) => l[0] === 'biFeedStuck'));
    window.__biSetFavEdges(JSON.stringify({ count: 0, markers: {}, edges: [] }));
    check('empty harvest posts biFeedStuck (fails closed)',
      logs.some((l) => l[0] === 'biFeedStuck'));
    check('degraded flag set', window.__biFeedDegraded === true);

    setTimeout(() => {
      const unknown = window.document.createElement('article');
      unknown.innerHTML = '<div>no author link at all</div>';
      window.document.querySelector('main').appendChild(unknown);
      window.__biReapply();
      setTimeout(() => {
        check('degraded state hides unknown-author articles',
          unknown.classList.contains('__bi_hidden'),
          'classes: ' + unknown.className);

        // --- immersive HOLDS through the close animation (regression guard) --
        // The path front-run flips immersive on instantly, but isImmersiveSurface
        // must STILL run the geometry detectors so activeStorySurface latches.
        // Otherwise immersive would flip back to false the instant the route
        // reverts to the feed — mid-close-animation — reintroducing the base-color
        // flash the geometry "hold through close" was built to prevent. jsdom has
        // no layout, so we stub a fullscreen <video> as the story surface and
        // drive the observer to warm the cache, then assert immersive survives
        // the route back to the feed while the surface is still onscreen.
        navigate('/'); // feed baseline (immersive=false)
        let storyFullscreen = false;
        const storyVideo = window.document.createElement('video');
        storyVideo.getBoundingClientRect = () => storyFullscreen
          ? { width: window.innerWidth, height: window.innerHeight, top: 0, left: 0,
              right: window.innerWidth, bottom: window.innerHeight, x: 0, y: 0 }
          : { width: 8, height: 8, top: 0, left: 0, right: 8, bottom: 8, x: 0, y: 0 };
        window.document.body.appendChild(storyVideo); // outside <main>/<article>

        navigate('/stories/someuser/999/'); // pre-route geometry captured small
        storyFullscreen = true;
        storyVideo.classList.add('bi-probe'); // class mutation -> observer warms cache

        setTimeout(() => {
          const warmed = lastPresentation();
          const newPosts = navigate('/'); // close: surface still fullscreen+connected
          check('immersive holds through close animation (geometry cache latched)',
            lastPresentation() && lastPresentation().immersive === true && newPosts === 0,
            'warmed=' + JSON.stringify(warmed) +
              ' afterClose=' + JSON.stringify(lastPresentation()) + ' newPosts=' + newPosts);
          // cleanup so the run ends on a clean, non-immersive feed state.
          storyFullscreen = false;
          storyVideo.remove();
          navigate('/');
          setTimeout(report, 100);
        }, 150);
      }, 700);
    }, 50);
  }, 600);
}, 800);

function report() {
    let failed = 0;
    for (const c of checks) {
      if (!c.ok) failed++;
      console.log((c.ok ? 'PASS  ' : 'FAIL  ') + c.name + (c.detail && !c.ok ? '\n        ' + c.detail : ''));
    }
    console.log('\n--- biLog output ---');
    biLogs().forEach((l) => console.log('  ' + l));
    console.log('\n' + (failed === 0 ? 'ALL CHECKS PASSED' : failed + ' CHECK(S) FAILED'));
    dom.window.close();
    process.exit(failed === 0 ? 0 : 1);
}
