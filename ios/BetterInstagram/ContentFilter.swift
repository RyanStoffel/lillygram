import Foundation

enum ContentFilter {
    static let script = """
    (function() {
      let isTopFrame = true;
      try { isTopFrame = (window === window.top); } catch (e) {}

      // Favorites allowlist. Seeded from the native side via a preamble user
      // script (window.__biFavorites / window.__biFavoritesEnabled) and
      // updatable live through window.__biSetFavorites.
      let favSet = new Set();
      let favoritesOn = false;
      const dmThumbCache = {};

      const style = document.createElement('style');
      style.id = '__bi_filter_style';
      style.textContent = `
        a[href="/reels/"] { display: none !important; }
        a[href="/explore/"] { display: none !important; }
        svg[aria-label="Reels"] { display: none !important; }
        .__bi_hidden { display: none !important; }
        .__bi_fav_hidden { display: none !important; }
        .__bi_reel_hidden { display: none !important; }
        .__bi_lockedscroll { overflow: hidden !important; touch-action: none !important; overscroll-behavior: none !important; }
        html.__bi_noscroll, html.__bi_noscroll body { overflow: hidden !important; height: 100% !important; touch-action: none !important; }
        html.__bi_noscroll * { touch-action: none !important; }
        html.__bi_noscroll [role="dialog"]:not(:has(video)), html.__bi_noscroll [role="dialog"]:not(:has(video)) * { touch-action: auto !important; }
        a, [role="button"], [role="link"] { cursor: pointer; }
        #__bi_star_btn { position: absolute; left: 12px; top: 50%; transform: translateY(-50%); z-index: 3; background: none; border: 0; padding: 8px; display: flex; align-items: center; }
        @keyframes __bi_rot { to { transform: rotate(360deg); } }
      `;

      function biLog(msg) {
        if (!isTopFrame) return;
        try {
          if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.biLog) {
            window.webkit.messageHandlers.biLog.postMessage(String(msg));
          }
        } catch (e) {}
      }

      function ensureStyleInjected() {
        if (!document.getElementById('__bi_filter_style') && document.head) {
          document.head.appendChild(style);
        }
      }

      function hide(el) {
        if (el && !el.classList.contains('__bi_hidden')) {
          el.classList.add('__bi_hidden');
        }
      }

      function scanRoot() {
        return document.querySelector('main') || document.body || document;
      }

      // ---- route helpers -------------------------------------------------

      function isReelSectionPage() {
        return /^\\/reels\\/(audio|videos)\\//.test(location.pathname);
      }

      // A single shared reel/post permalink. Note /reels/<id>/ (plural) is the
      // format DM shares and share-sheet links actually use, alongside
      // /reel/<id>/ and /p/<id>/.
      function isMediaPermalink() {
        return /^\\/(reels?|p|tv)\\/[^/]+/.test(location.pathname) && !isReelSectionPage();
      }

      function isReelPermalink() {
        return /^\\/reels?\\/[^/]+/.test(location.pathname) && !isReelSectionPage();
      }

      // The reels viewer doesn't always change the URL (opened from a DM
      // thread it can be an overlay while the path stays /direct/t/...), so
      // lock on either a reel permalink or a near-fullscreen video. Home and
      // stories are excluded: feed videos never lock the feed, and stories
      // need their own gestures.
      function activeReelVideo() {
        if (location.pathname === '/' || /^\\/stories\\//.test(location.pathname)) return null;
        const videos = document.querySelectorAll('video');
        for (let i = 0; i < videos.length; i++) {
          const r = videos[i].getBoundingClientRect();
          if (r.width >= window.innerWidth * 0.85 && r.height >= window.innerHeight * 0.6) {
            return videos[i];
          }
        }
        return null;
      }

      function shouldLockScroll() {
        if (isReelPermalink() && document.querySelector('video')) return true;
        return !!activeReelVideo();
      }

      // The scrollable / scroll-snap ancestor the reels viewer paginates
      // with. Locking it directly kills swipe-to-next even when IG drives it
      // through its own scroll container rather than the page scroll.
      function scrollLockContainer(video) {
        let node = video && video.parentElement;
        let depth = 0;
        let best = null;
        while (node && node !== document.body && depth < 12) {
          const cs = getComputedStyle(node);
          if (cs.scrollSnapType && cs.scrollSnapType !== 'none') {
            best = node;
          } else if (node.scrollHeight > node.clientHeight + 10 &&
              (cs.overflowY === 'auto' || cs.overflowY === 'scroll')) {
            best = node;
          }
          node = node.parentElement;
          depth++;
        }
        return best;
      }

      // Reel-viewer hides are reversible (cleared when the lock releases) so
      // a reopened viewer isn't left with its videos hidden from last time.
      function reelHide(el) {
        if (el && !el.classList.contains('__bi_reel_hidden')) {
          el.classList.add('__bi_reel_hidden');
        }
      }

      // ---- favorites -----------------------------------------------------

      function setFavorites(list, enabled) {
        favSet = new Set((list || []).map(function(s) { return String(s).toLowerCase(); }));
        favoritesOn = !!enabled && favSet.size > 0;
        biLog('[favorites] enabled=' + favoritesOn + ' count=' + favSet.size);
        scheduleApply();
      }

      // ---- favorites feed --------------------------------------------------
      // We stay on the REAL home page (live stories tray, header, native story
      // navigation) with the home feed request left as variant=home, and swap
      // the edges in its response for real favorites edges we fetch ourselves
      // (see the edge-splice note by installXHRFilter). Home client + home
      // response shape + favorite edges = stories + favorites, both native.

      function onFavoritesVariant() {
        return location.pathname === '/' &&
          location.search.indexOf('variant=favorites') !== -1;
      }

      // ---- feed article filtering ----------------------------------------

      function isReelArticle(article) {
        if (article.querySelector('a[href^="/reel/"], a[href^="/reels/"]')) return true;
        if (article.querySelector('a[href*="instagram.com/reel"]')) return true;
        if (article.querySelector('svg[aria-label="Clip"], svg[aria-label="Reel"]')) return true;
        return false;
      }

      // The author of a feed post = the first single-segment profile link in the
      // article (post permalinks like /p/<code>/ have two segments and are
      // skipped; reserved words are ignored).
      function articleAuthor(article) {
        const links = article.querySelectorAll('a[href^="/"]');
        const reserved = { p: 1, reel: 1, reels: 1, explore: 1, direct: 1,
          stories: 1, accounts: 1, tv: 1 };
        for (let i = 0; i < links.length; i++) {
          const href = links[i].getAttribute('href') || '';
          const m = href.match(/^\\/([A-Za-z0-9._]+)\\/?$/);
          if (m) {
            const name = m[1].toLowerCase();
            if (!reserved[name]) return name;
          }
        }
        return null;
      }

      function filterArticle(article) {
        if (!article || article.classList.contains('__bi_hidden')) return;
        const labels = article.querySelectorAll('span, a');
        for (let i = 0; i < labels.length; i++) {
          const t = labels[i].textContent;
          if (t === 'Sponsored' || t === 'Ad') { hide(article); return; }
        }
        if (!isMediaPermalink() && isReelArticle(article)) { hide(article); return; }
        // The home page server-streams some algorithmic posts into its HTML that
        // never pass through our XHR splice. On the home feed, hide any post
        // whose author isn't a favorite (favSet = app picks, favAuthors =
        // harvested favorites). Unknown authors are left alone so a real
        // favorite is never hidden by a failed lookup.
        if (favoritesOn && location.pathname === '/' && !window.__biNativeFavMode) {
          const author = articleAuthor(article);
          if (author && !favSet.has(author) && !favAuthors.has(author)) {
            hide(article);
            return;
          }
        }
      }

      function hideSponsoredAndReels() {
        if (isMediaPermalink()) return;
        scanRoot().querySelectorAll('article').forEach(filterArticle);
        scanRoot().querySelectorAll('a[href^="/reel/"], a[href^="/reels/"]').forEach(function(a) {
          if (a.getAttribute('href') === '/reels/') return;
          if (!a.closest('article')) hide(a);
        });
      }

      function hideFeedNoise() {
        if (location.pathname !== '/') return;
        const unitLabels = ['Suggested for you', 'Suggested posts', 'Suggested reels', 'Reels'];
        scanRoot().querySelectorAll('span, h2, h3, div').forEach(function(el) {
          if (el.children.length > 0) return;
          const text = (el.textContent || '').trim();
          if (unitLabels.indexOf(text) === -1) return;
          const article = el.closest('article');
          if (article) { hide(article); return; }
          let node = el.parentElement;
          let depth = 0;
          let candidate = null;
          while (node && node !== document.body && depth < 8) {
            if (node.querySelector('article')) break;
            const h = node.offsetHeight;
            if (h >= window.innerHeight) break;
            if (h > 40) candidate = node;
            node = node.parentElement;
            depth++;
          }
          if (candidate) hide(candidate);
        });
      }

      // ---- data-layer feed filtering ---------------------------------------
      // Instagram interleaves reels/clips and suggestion units into the home
      // timeline server-side, so hiding DOM after the fact always races React.
      // Patching fetch at document start lets us drop those items from the
      // timeline responses (initial load AND every infinite-scroll page)
      // before React ever renders them. The DOM pass above stays as fallback
      // for anything the payload filter misses (e.g. streamed/deferred
      // responses that are not a single JSON document).

      // Favorites are now selected by the request rewrite (variant=favorites),
      // so this only strips reels/clips and ads from whichever feed loads.
      function feedMediaAllowed(media) {
        if (!media || typeof media !== 'object') return true;
        if ((media.product_type || '') === 'clips') return false;
        if (media.ad_id || media.injected) return false;
        return true;
      }

      function filterTimelineEdges(edges) {
        const kept = edges.filter(function(edge) {
          const node = edge && edge.node;
          if (!node || typeof node !== 'object') return true;
          if (node.media) return feedMediaAllowed(node.media);
          if (node.explore_story || node.clips || node.suggested_users) return false;
          return true;
        });
        return kept.length !== edges.length ? kept : null;
      }

      function filterRestFeedItems(items) {
        const kept = items.filter(function(item) {
          if (!item || typeof item !== 'object') return true;
          if (item.media_or_ad) return feedMediaAllowed(item.media_or_ad);
          if (item.end_of_feed_demarcator) return true;
          return !(item.clips || item.suggested_users || item.stories_netego || item.bloks_netego);
        });
        return kept.length !== items.length ? kept : null;
      }

      // Only touches timeline-shaped keys so single-post queries (the ones a
      // shared reel permalink needs to actually play) are never stripped.
      function filterFeedPayload(obj, depth) {
        if (!obj || typeof obj !== 'object' || depth > 12) return false;
        let changed = false;
        for (const key in obj) {
          const value = obj[key];
          if (!value || typeof value !== 'object') continue;
          if (key.indexOf('feed__timeline') !== -1 && Array.isArray(value.edges)) {
            const kept = filterTimelineEdges(value.edges);
            if (kept) { value.edges = kept; changed = true; }
          }
          if (key === 'feed_items' && Array.isArray(value)) {
            const kept = filterRestFeedItems(value);
            if (kept) { obj[key] = kept; changed = true; }
          }
          if (filterFeedPayload(value, depth + 1)) changed = true;
        }
        return changed;
      }

      // Instagram server-streams the home feed into the page HTML (inside
      // <script type="application/json" data-sjs> blocks) and renders the
      // INITIAL feed from that streamed data, NOT from the feed XHR. Its
      // bootloader parses those blocks with JSON.parse. So to make favorites
      // render we splice them in at parse time: hook JSON.parse at document
      // start and, for any parsed object carrying a feed__timeline connection,
      // replace its edges with the harvested favorites BEFORE Relay hydrates.
      // Edges are preloaded from native (window.__biFavEdgesPreload) so they're
      // available synchronously at document start; the XHR splice below still
      // covers infinite-scroll pages.
      function installSSRFeedSplice() {
        if (window.__biSSRPatched) return;
        window.__biSSRPatched = true;
        let ssrEdges = null;
        try {
          const pre = window.__biFavEdgesPreload;
          const obj = (typeof pre === 'string') ? JSON.parse(pre) : pre;
          ssrEdges = (obj && obj.edges) ? sanitizeFavEdges(obj.edges) : null;
        } catch (e) {}
        if (!ssrEdges || !ssrEdges.length) return;
        favEdges = ssrEdges;
        edgeAuthors(ssrEdges).split(',').forEach(function(a) {
          if (a && a !== '?') favAuthors.add(a.toLowerCase());
        });
        const origParse = JSON.parse;
        JSON.parse = function(text) {
          const result = origParse.apply(this, arguments);
          try {
            if (typeof text === 'string' && text.indexOf('feed__timeline') !== -1) {
              let did = false;
              (function walk(o, d) {
                if (!o || typeof o !== 'object' || d > 14) return;
                for (const k in o) {
                  const v = o[k];
                  if (!v || typeof v !== 'object') continue;
                  if (k.indexOf('feed__timeline') !== -1 && Array.isArray(v.edges)) {
                    v.edges = ssrEdges;
                    if (v.page_info) v.page_info.has_next_page = false;
                    did = true;
                  }
                  walk(v, d + 1);
                }
              })(result, 0);
              if (did && !window.__biSSRSpliced) {
                window.__biSSRSpliced = true;
                biLog('[favsplice] spliced favorites into SSR feed data');
              }
            }
          } catch (e) {}
          return result;
        };
        biLog('[favsplice] SSR feed splice armed (' + ssrEdges.length + ' edges)');
      }

      function installFetchFilter() {
        if (!isTopFrame || window.__biFetchPatched || !window.fetch) return;
        window.__biFetchPatched = true;
        const origFetch = window.fetch;
        window.fetch = function(input) {
          let url = '';
          try { url = (typeof input === 'string') ? input : ((input && input.url) || ''); } catch (e) {}
          const result = origFetch.apply(this, arguments);
          if (!/\\/graphql|\\/api\\/v1\\/feed\\//.test(url)) return result;
          return result.then(function(response) {
            return response.clone().text().then(function(text) {
              if (text.indexOf('feed__timeline') === -1 && text.indexOf('feed_items') === -1) return response;
              let payload;
              try { payload = JSON.parse(text); } catch (e) { return response; }
              const finish = function(changed, label) {
                if (!changed) return response;
                biLog('[fetch] ' + label + ' ' + url.slice(0, 80));
                try {
                  return new Response(JSON.stringify(payload), {
                    status: response.status,
                    statusText: response.statusText,
                    headers: response.headers
                  });
                } catch (e) { return response; }
              };
              // In favorites mode the request rewrite already made IG return
              // its favorites feed — leave the response completely untouched
              // so IG renders it natively (modifying/re-serializing it makes
              // IG's Relay renderer throw).
              if (favoritesOn) return response;
              return finish(filterFeedPayload(payload, 0), 'filtered feed page');
            }).catch(function() { return response; });
          });
        };
      }

      // IG's web client issues the timeline queries over XMLHttpRequest. For
      // the favorites feed we splice favorite edges into the home response;
      // otherwise we strip reels/ads. CRITICAL: IG reads responseText from its
      // OWN onreadystatechange handler, which can fire before a readystatechange
      // listener we add. So instead of rewriting the response in a listener
      // (too late — IG already read the original), we install LAZY GETTERS on
      // responseText/response at open() time. The rewrite is computed on first
      // access at readyState 4, so whoever reads first (IG or us) gets favorites.
      const nativeResponseText =
        Object.getOwnPropertyDescriptor(XMLHttpRequest.prototype, 'responseText').get;
      const nativeResponse =
        Object.getOwnPropertyDescriptor(XMLHttpRequest.prototype, 'response').get;

      function rewriteFeedText(text) {
        // Returns rewritten JSON string, or null if unchanged/not a feed.
        if (!text || (text.indexOf('feed__timeline') === -1 && text.indexOf('feed_items') === -1)) return null;
        let payload;
        try { payload = JSON.parse(text); } catch (e) { return null; }
        let changed;
        if (favoritesOn) {
          const before = extractTimelineEdges(payload);
          // One-time shape diff: the edge IG's live home query returns vs the
          // edge we're splicing in. Same query => must be identical shape; any
          // key the FAV edge is missing (or the HOME edge has) is why Relay
          // refuses to render the swap and hangs on the spinner.
          if (!window.__biEdgeDiffLogged && before && before.length && favEdges && favEdges.length) {
            window.__biEdgeDiffLogged = true;
            const sig = function(e) {
              const n = e && e.node;
              const m = n && n.media;
              return 'node{' + (n ? Object.keys(n).join(',') : '-') + '} media{' +
                (m ? Object.keys(m).join(',') : '-') + '}';
            };
            biLog('[edgediff] HOME ' + sig(before[0]));
            biLog('[edgediff] FAV  ' + sig(favEdges[0]));
          }
          changed = spliceFavoriteEdges(payload);
          if (changed) {
            biLog('[favsplice] swapped favorites into home response');
            // Tell native the favorites feed is ready so it can drop the splash.
            if (location.pathname === '/' && !window.__biFavReadyPosted) {
              window.__biFavReadyPosted = true;
              try { webkit.messageHandlers.biFavReady.postMessage(true); } catch (e) {}
            }
          } else {
            if (before && before.length) feedRenderedAlgorithmic = true;
            biLog('[favsplice] NO SWAP (favEdges=' + (favEdges ? favEdges.length : 0) +
              ' authors=' + (before ? edgeAuthors(before) : '?') + ')');
          }
        } else {
          changed = filterFeedPayload(payload, 0);
          if (changed) biLog('[xhr] stripped reels/ads from feed');
        }
        return changed ? JSON.stringify(payload) : null;
      }

      function installLazyRewrite(xhr) {
        let computed = false;
        let cachedText = null; // rewritten JSON string, or null if unchanged
        function compute() {
          if (computed || xhr.readyState !== 4) return;
          computed = true;
          // In native-favorites mode IG serves the favorites feed itself; never
          // rewrite a feed response or Relay throws and the feed spins.
          if (window.__biNativeFavMode) { cachedText = null; return; }
          let text = null;
          try {
            const rt = xhr.responseType;
            if (rt === '' || rt === 'text') text = nativeResponseText.call(xhr);
            else if (rt === 'json') {
              const o = nativeResponse.call(xhr);
              text = (o == null) ? null : JSON.stringify(o);
            } else return;
          } catch (e) { return; }
          cachedText = rewriteFeedText(text);
        }
        try {
          Object.defineProperty(xhr, 'responseText', {
            configurable: true,
            get: function() {
              if (xhr.readyState === 4) { compute(); if (cachedText !== null) return cachedText; }
              return nativeResponseText.call(xhr);
            }
          });
          Object.defineProperty(xhr, 'response', {
            configurable: true,
            get: function() {
              if (xhr.readyState === 4) {
                compute();
                if (cachedText !== null) {
                  return xhr.responseType === 'json' ? JSON.parse(cachedText) : cachedText;
                }
              }
              return nativeResponse.call(xhr);
            }
          });
        } catch (e) {}
      }

      // Diagnostic: log the friendly-name + variables of feed GraphQL
      // requests, so when the user selects Favorites we capture the exact
      // request signature that selects the favorites feed. That lets us
      // request it directly (deterministic) instead of DOM-clicking.
      function logFeedRequest(url, body) {
        try {
          if (!/\\/graphql/.test(url) || typeof body !== 'string') return;
          const fnMatch = body.match(/fb_api_req_friendly_name=([^&]+)/);
          const fn = fnMatch ? decodeURIComponent(fnMatch[1]) : '';
          if (!/feed|timeline/i.test(fn) && body.indexOf('feed_timeline') === -1) return;
          const varsMatch = body.match(/variables=([^&]+)/);
          const vars = varsMatch ? decodeURIComponent(varsMatch[1]) : '';
          const docMatch = body.match(/doc_id=([0-9]+)/);
          // Tag which feed this request is for (home vs the favorites variant)
          // so the two can be diffed. Log the full variables in chunks since
          // the difference (the favorites flag) may be deep in the JSON.
          const where = onFavoritesVariant() ? 'VARIANT' : (location.pathname === '/' ? 'HOME' : location.pathname);
          biLog('[req ' + where + '] ' + (fn || '?') + ' doc_id=' + (docMatch ? docMatch[1] : '?'));
          for (let i = 0; i < vars.length && i < 2400; i += 600) {
            biLog('[vars ' + where + ' ' + (i / 600) + '] ' + vars.slice(i, i + 600));
          }
        } catch (e) {}
      }

      // THE FIX: edge splice. Rewriting the home REQUEST to variant=favorites
      // returns favorites data but IG's home-mode client can't render it (it
      // spins). Instead we let IG's home request stay variant=home (so the
      // home client + stories tray render normally), and REPLACE the edges in
      // its RESPONSE with real favorites edges we fetch ourselves. Same query
      // (PolarisFeedTimelineRootV2Query) = identical edge shape, so IG renders
      // them under the home slot: real stories + favorites feed, both native.
      // We hold IG's feed request until the favorites edges are fetched, so
      // the swap always lands.

      let favEdges = null;
      let favEdgesPromise = null;
      // Authors of the harvested favorite posts — used (together with favSet) as
      // the DOM allowlist so the home page's server-streamed algorithmic posts
      // (which never pass through our XHR splice) get hidden.
      let favAuthors = new Set();

      function extractTimelineEdges(payload) {
        let found = null;
        (function walk(o, d) {
          if (!o || typeof o !== 'object' || d > 12 || found) return;
          for (const k in o) {
            const v = o[k];
            if (!v || typeof v !== 'object') continue;
            if (k.indexOf('feed__timeline') !== -1 && Array.isArray(v.edges)) { found = v.edges; return; }
            walk(v, d + 1);
          }
        })(payload, 0);
        return found;
      }

      // Diagnostic: pull the author usernames out of a set of timeline edges so
      // we can see whether a feed really is favorites-only. The media node holds
      // the author under a few possible shapes (user/owner) depending on query.
      function edgeAuthors(edges) {
        const names = [];
        (edges || []).slice(0, 40).forEach(function(e) {
          let u = null;
          (function dig(o, d) {
            if (u || !o || typeof o !== 'object' || d > 6) return;
            if (typeof o.username === 'string') { u = o.username; return; }
            for (const k in o) {
              const v = o[k];
              if (v && typeof v === 'object') dig(v, d + 1);
              if (u) return;
            }
          })(e && e.node, 0);
          names.push(u || '?');
        });
        return names.join(',');
      }

      // Invariant guard (see favorites-feed.md → Invariants). Enforces in code
      // the two mistakes that hang Relay on the infinite spinner: it keeps only
      // real post edges (node.media), strictly de-dupes by media id, and
      // PRESERVES the incoming order. It must NEVER sort/reorder — a Relay feed
      // connection requires edges in Instagram's original cursor order. For the
      // current streamed-only harvest (already unique + ordered) this is a
      // no-op; it exists so a future multi-source/density merge can't
      // reintroduce reordered or duplicate edges.
      function sanitizeFavEdges(edges) {
        if (!Array.isArray(edges)) return [];
        const seen = new Set();
        const out = [];
        for (let i = 0; i < edges.length; i++) {
          const edge = edges[i];
          const media = edge && edge.node && edge.node.media;
          // Keep ONLY real, renderable post media. Non-post nodes (ads,
          // suggested-user, netego, end-of-feed demarcators) AND media without
          // an image/carousel/video hang IG's Relay connection on the spinner
          // even though the swap logs success. Require real media content.
          if (!media) continue;
          if (!(media.image_versions2 || media.carousel_media || media.video_versions)) continue;
          // R2: no reels in the home feed. The favorites feed can stream a
          // favorite's reel; dropping it here (data layer) instead of letting
          // the DOM filter hide it post-render kills the render-then-hide
          // flicker/gap.
          if ((media.product_type || '') === 'clips') continue;
          const id = media.pk || media.id || media.code;
          if (id != null) {
            const key = String(id);
            if (seen.has(key)) continue;
            seen.add(key);
          }
          out.push(edge);
        }
        return out;
      }

      function spliceFavoriteEdges(payload) {
        if (!favEdges || !favEdges.length) return false;
        let changed = false;
        (function walk(o, d) {
          if (!o || typeof o !== 'object' || d > 12) return;
          for (const k in o) {
            const v = o[k];
            if (!v || typeof v !== 'object') continue;
            if (k.indexOf('feed__timeline') !== -1 && Array.isArray(v.edges)) {
              v.edges = favEdges;
              if (v.page_info) v.page_info.has_next_page = false;
              changed = true;
            }
            walk(v, d + 1);
          }
        })(payload, 0);
        return changed;
      }

      // The feed 'variant' of a root timeline query: 'home' (algorithmic — we
      // splice favorites into it) or 'favorites' (IG's home feed switcher is set
      // to Favorites, so IG serves the favorites feed NATIVELY and we must leave
      // it untouched). The switcher is persisted server-side, so the home page
      // can issue EITHER. Returns null for non-root feed queries.
      function feedVariant(body) {
        if (typeof body !== 'string' || body.indexOf('variant') === -1) return null;
        try {
          const params = new URLSearchParams(body);
          if ((params.get('fb_api_req_friendly_name') || '') !== 'PolarisFeedTimelineRootV2Query') return null;
          const vars = JSON.parse(params.get('variables') || '{}');
          return vars.variant || null;
        } catch (e) { return null; }
      }

      // fetch() rejects (TypeError) if handed forbidden request headers, so
      // only forward IG's X-* / content-type / accept headers (the ones that
      // actually matter: X-CSRFToken, X-FB-LSD, X-IG-App-ID, friendly name).
      function safeReplayHeaders(headers) {
        const out = { 'content-type': 'application/x-www-form-urlencoded' };
        if (!headers) return out;
        for (const k in headers) {
          const lk = k.toLowerCase();
          if (lk.indexOf('x-') === 0 || lk === 'accept') out[k] = headers[k];
        }
        return out;
      }

      // The favorites feed is NOT delivered by any XHR we can intercept, and a
      // plain fetch('/?variant=favorites') returns only the app shell (no feed
      // data). IG streams the favorites feed into the HTML ONLY on a real
      // top-level navigation. So the native side loads /?variant=favorites in a
      // hidden webview, extracts the streamed edges there, and pushes them here
      // via window.__biSetFavEdges. We just hold the home feed request until
      // those edges arrive, then splice them into the home response.

      let feedRenderedAlgorithmic = false;

      // Native entry point: receives the harvested favorites payload
      // ({markers, count, authors, edges}) as a JSON string.
      window.__biSetFavEdges = function(payload) {
        try {
          const obj = typeof payload === 'string' ? JSON.parse(payload) : payload;
          const rawEdges = obj && obj.edges;
          // One-time shape dump: for each harvested edge, log the node's top
          // keys and whether it carries renderable media. Tells us definitively
          // whether Relay is hanging on non-post / content-less edges.
          if (rawEdges && !window.__biFavShapeLogged) {
            window.__biFavShapeLogged = true;
            try {
              biLog('[favshape] ' + JSON.stringify((rawEdges || []).slice(0, 10).map(function(e) {
                const n = e && e.node;
                const m = n && n.media;
                return (n ? Object.keys(n).slice(0, 4).join('|') : 'no-node') + '=>' +
                  (m ? ('media(' + (m.image_versions2 ? 'i' : '-') + (m.carousel_media ? 'c' : '-') +
                    (m.video_versions ? 'v' : '-') + ' id=' + (m.pk || m.id || m.code || '?') + ')') : 'no-media');
              })));
            } catch (e) { biLog('[favshape] err ' + e); }
          }
          const edges = sanitizeFavEdges(rawEdges);
          if (edges.length) {
            favEdges = edges;
            edgeAuthors(edges).split(',').forEach(function(a) {
              if (a && a !== '?') favAuthors.add(a.toLowerCase());
            });
            const rawCount = rawEdges ? rawEdges.length : 0;
            biLog('[favsplice] received ' + edges.length + ' favorite edges from harvest' +
              (rawCount !== edges.length ? ' (sanitized from ' + rawCount + ')' : ''));
            biLog('[favsplice] fav authors=' + edgeAuthors(edges));
            scheduleApply();
            if (favEdgesResolve) { favEdgesResolve(); favEdgesResolve = null; }
            // The native side reloads the home tab once after the first harvest;
            // on that reload the edges are already cached and delivered at
            // didFinish, so the held feed request resolves and swaps reliably.
          } else {
            biLog('[favsplice] harvest delivered 0 edges (markers=' +
              JSON.stringify(obj && obj.markers) + ')');
            if (favEdgesResolve) { favEdgesResolve(); favEdgesResolve = null; }
          }
        } catch (e) { biLog('[favsplice] setFavEdges err ' + e); }
      };

      let favEdgesResolve = null;

      // Hold the home feed request until harvested favorites edges are ready
      // (or a timeout, so we never hang the feed if the harvest fails).
      function prefetchFavoriteEdges() {
        if (favEdges && favEdges.length) return Promise.resolve();
        if (favEdgesPromise) return favEdgesPromise;
        biLog('[favsplice] waiting for harvested favorite edges');
        favEdgesPromise = new Promise(function(resolve) {
          favEdgesResolve = resolve;
          setTimeout(function() {
            if (favEdgesResolve) {
              biLog('[favsplice] favorite edges wait timed out');
              favEdgesResolve = null;
              resolve();
            }
          }, 10000);
        });
        return favEdgesPromise;
      }

      function installXHRFilter() {
        if (!isTopFrame || window.__biXHRPatched || !window.XMLHttpRequest) return;
        window.__biXHRPatched = true;
        const origOpen = XMLHttpRequest.prototype.open;
        const origSend = XMLHttpRequest.prototype.send;
        const origSetHeader = XMLHttpRequest.prototype.setRequestHeader;
        XMLHttpRequest.prototype.setRequestHeader = function(k, v) {
          if (!this.__biHeaders) this.__biHeaders = {};
          this.__biHeaders[k] = v;
          return origSetHeader.apply(this, arguments);
        };
        XMLHttpRequest.prototype.open = function(method, url) {
          this.__biUrl = String(url || '');
          if (/\\/graphql|\\/api\\/v1\\/feed\\//.test(this.__biUrl)) {
            // Install lazy response getters now so the rewrite lands no matter
            // who reads the response first (IG's own handler often reads before
            // an added readystatechange listener would fire).
            installLazyRewrite(this);
          }
          return origOpen.apply(this, arguments);
        };
        XMLHttpRequest.prototype.send = function(body) {
          const xhr = this;
          // CAPTURE: log every feed request's signature so we can see the exact
          // request IG issues on the real /?variant=favorites route and replay
          // that verbatim (the home request's only feed field is variant=home,
          // and flipping it server-side does nothing).
          try { logFeedRequest(xhr.__biUrl || '', body); } catch (e) {}
          if (favoritesOn) {
            const variant = feedVariant(body);
            if (variant === 'favorites') {
              // IG's own client is already serving the favorites feed. Splicing
              // or re-serializing a native favorites response makes IG's Relay
              // renderer throw ('Script error.') and the feed hangs on the
              // spinner. Enter native-favorites mode: leave every feed response
              // untouched and stand the DOM author-filter down (every post is
              // already a favorite). See favorites-feed.md.
              if (!window.__biNativeFavMode) {
                window.__biNativeFavMode = true;
                biLog('[favsplice] native favorites feed detected; leaving IG feed untouched');
                scheduleApply();
              }
              return origSend.apply(this, arguments);
            }
            if (variant === 'home') {
              // Hold IG's home feed request until the favorites edges are ready,
              // so the lazy response getter can splice them into this response.
              biLog('[favsplice] holding home feed request for favorites');
              prefetchFavoriteEdges().then(function() {
                origSend.apply(xhr, [body]);
              });
              return;
            }
          }
          return origSend.apply(this, arguments);
        };
      }

      // ---- SPA routing guard -----------------------------------------------
      // WKNavigationDelegate never sees pushState navigation, so route
      // blocking has to be enforced here too. Also pins a reel permalink in
      // place: while viewing one reel, any SPA hop to a *different* reel
      // (swipe-to-next pagination) is swallowed. Back/forward (popstate) and
      // navigation to non-reel routes stay untouched so exiting works.

      function routeDecision(url) {
        if (url === undefined || url === null) return 'allow';
        let path = null;
        try { path = new URL(String(url), location.href).pathname; } catch (e) { return 'allow'; }
        if (/^\\/(reels|explore)\\/?$/.test(path)) return 'home';
        if (isReelPermalink() && /^\\/reels?\\/[^/]+/.test(path)) {
          const current = location.pathname.replace(/\\/+$/, '');
          const next = path.replace(/\\/+$/, '');
          if (next !== current) return 'block';
        }
        return 'allow';
      }

      function onRouteChange() {
        updateScrollLock();
        reportNavVisibility();
        scheduleApply();
      }

      function installHistoryHook() {
        if (!isTopFrame || window.__biHistoryPatched) return;
        window.__biHistoryPatched = true;
        ['pushState', 'replaceState'].forEach(function(name) {
          const original = history[name];
          history[name] = function(state, title, url) {
            const decision = routeDecision(url);
            if (decision === 'block') {
              biLog('[route] blocked ' + name + ' -> ' + url);
              return undefined;
            }
            if (decision === 'home') {
              biLog('[route] redirected ' + url + ' -> /');
              location.assign('/');
              return undefined;
            }
            const result = original.apply(this, arguments);
            onRouteChange();
            return result;
          };
        });
        window.addEventListener('popstate', function() { onRouteChange(); });
      }

      function guardLocation() {
        if (!isTopFrame) return;
        if (/^\\/(reels|explore)\\/?$/.test(location.pathname)) {
          location.replace('/');
        }
      }

      // ---- single-reel playback lock ---------------------------------------

      function lockToPrimaryReel() {
        const primary = activeReelVideo() ||
          (isReelPermalink() ? document.querySelector('video') : null);
        if (!primary) return;
        const container = scrollLockContainer(primary);
        const scope = container || (isReelPermalink() ? scanRoot() : null);
        if (scope) {
          scope.querySelectorAll('video').forEach(function(v) {
            if (v === primary) return;
            reelHide(v.closest('article') || v.parentElement);
          });
        }
        document.querySelectorAll('svg[aria-label="Next"], button[aria-label="Next"]').forEach(function(el) {
          reelHide(clickableFor(el) || el);
        });
      }

      function updateScrollLock() {
        const lock = shouldLockScroll();
        const html = document.documentElement;
        const has = html.classList.contains('__bi_noscroll');
        if (lock && !has) html.classList.add('__bi_noscroll');
        if (!lock && has) html.classList.remove('__bi_noscroll');
        if (lock) {
          const video = activeReelVideo() || document.querySelector('video');
          const container = video ? scrollLockContainer(video) : null;
          if (container && !container.classList.contains('__bi_lockedscroll')) {
            container.classList.add('__bi_lockedscroll');
          }
        } else {
          document.querySelectorAll('.__bi_lockedscroll').forEach(function(el) {
            el.classList.remove('__bi_lockedscroll');
          });
          document.querySelectorAll('.__bi_reel_hidden').forEach(function(el) {
            el.classList.remove('__bi_reel_hidden');
          });
        }
        if (isTopFrame && window.__biLastScrollLock !== lock) {
          window.__biLastScrollLock = lock;
          biLog('[scroll] lock=' + lock + ' path=' + location.pathname);
          if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.biScroll) {
            window.webkit.messageHandlers.biScroll.postMessage(lock);
          }
        }
      }

      // Comment sheets and text inputs stay scrollable/usable while the reel
      // itself refuses swipe gestures.
      function scrollExempt(target) {
        if (!target || !target.closest) return false;
        if (target.closest('textarea, input, [contenteditable="true"]')) return true;
        // Comment sheets etc. stay scrollable — but only dialogs that don't
        // contain the video, otherwise the reels viewer itself (which IG can
        // render as a dialog) would be exempt from the swipe lock.
        const dialog = target.closest('[role="dialog"]');
        return !!(dialog && !dialog.querySelector('video'));
      }

      function installGestureLocks() {
        if (window.__biGesturesPatched) return;
        window.__biGesturesPatched = true;
        document.addEventListener('touchmove', function(e) {
          if (!shouldLockScroll()) return;
          if (scrollExempt(e.target)) return;
          e.preventDefault();
        }, { passive: false, capture: true });
        window.addEventListener('wheel', function(e) {
          if (!shouldLockScroll()) return;
          if (scrollExempt(e.target)) return;
          e.preventDefault();
        }, { passive: false, capture: true });
        document.addEventListener('keydown', function(e) {
          if (!shouldLockScroll()) return;
          if (['ArrowDown', 'ArrowUp', 'PageDown', 'PageUp', ' '].indexOf(e.key) !== -1) {
            e.preventDefault();
            e.stopPropagation();
          }
        }, true);
      }

      function preventNativeFullscreen() {
        if (window.__biFullscreenPatched) return;
        window.__biFullscreenPatched = true;

        const mediaProto = window.HTMLMediaElement && HTMLMediaElement.prototype;
        if (mediaProto && mediaProto.webkitEnterFullscreen) {
          try {
            Object.defineProperty(mediaProto, 'webkitEnterFullscreen', {
              value: function() {},
              configurable: true
            });
          } catch (e) {}
        }
        ['requestFullscreen', 'webkitRequestFullscreen'].forEach(function(name) {
          if (mediaProto && mediaProto[name]) {
            try {
              Object.defineProperty(mediaProto, name, {
                value: function() { return Promise.resolve(); },
                configurable: true
              });
            } catch (e) {}
          }
          if (Element.prototype[name]) {
            try {
              Object.defineProperty(Element.prototype, name, {
                value: function() { return Promise.resolve(); },
                configurable: true
              });
            } catch (e) {}
          }
        });

        document.addEventListener('webkitbeginfullscreen', function(e) {
          const video = e.target;
          if (video && video.webkitExitFullscreen) {
            try { video.webkitExitFullscreen(); } catch (err) {}
          }
        }, true);

        if (mediaProto && mediaProto.play) {
          const originalPlay = mediaProto.play;
          mediaProto.play = function() {
            if (!this.hasAttribute('playsinline')) this.setAttribute('playsinline', '');
            if (!this.hasAttribute('webkit-playsinline')) this.setAttribute('webkit-playsinline', '');
            return originalPlay.apply(this, arguments);
          };
        }
      }

      function forcePlaysInline() {
        document.querySelectorAll('video').forEach(function(v) {
          if (!v.hasAttribute('playsinline')) v.setAttribute('playsinline', '');
          if (!v.hasAttribute('webkit-playsinline')) v.setAttribute('webkit-playsinline', '');
        });
      }

      function dismissAppNag() {
        const nagText = /open in the instagram app|open in app|get the app|use the app|switch to the app/i;
        document.querySelectorAll('span, a, button, div').forEach(function(el) {
          if (el.children.length > 0 || !nagText.test(el.textContent || '')) return;
          let node = el;
          for (let i = 0; i < 6 && node; i++) {
            const position = getComputedStyle(node).position;
            if (position === 'fixed' || position === 'sticky') {
              const closeButton = node.querySelector('button, [role="button"]');
              if (closeButton) closeButton.click();
              hide(node);
              return;
            }
            node = node.parentElement;
          }
        });
      }

      function getNavSeed() {
        return document.querySelector('a[href="/reels/"]') ||
          document.querySelector('a[href="/explore/"]') ||
          document.querySelector('svg[aria-label="Home"]') ||
          document.querySelector('a[href="/"]');
      }

      function getNavRow() {
        const seed = getNavSeed();
        if (!seed) return null;
        let node = seed.parentElement;
        let depth = 0;
        while (node && node !== document.body && depth < 10) {
          const clickables = node.querySelectorAll('a[href], [role="link"], [role="button"], [role="tab"]').length;
          const icons = node.querySelectorAll('svg[aria-label]').length;
          if (clickables >= 4 || icons >= 4) return node;
          node = node.parentElement;
          depth++;
        }
        return null;
      }

      function hideOriginalNav() {
        const row = getNavRow();
        if (!row) return;

        let node = row;
        let target = row;
        let depth = 0;
        while (node && node !== document.body && depth < 8) {
          const cs = getComputedStyle(node);
          if (cs.position === 'fixed' || cs.position === 'sticky') {
            target = node;
            break;
          }
          if (cs.backgroundColor !== 'rgba(0, 0, 0, 0)' && cs.backgroundColor !== 'transparent') {
            target = node;
          }
          node = node.parentElement;
          depth++;
        }
        hide(target);
      }

      function hideBottomBars() {
        if (/^\\/(direct\\/t\\/|stories\\/)/.test(location.pathname)) return;
        if (isMediaPermalink()) return;
        const vh = window.innerHeight;
        document.querySelectorAll('div, nav, footer').forEach(function(el) {
          if (el.classList.contains('__bi_hidden')) return;
          const rect = el.getBoundingClientRect();
          if (!(rect.height > 0 && rect.height < 120 && rect.bottom >= vh - 2 && rect.top > vh * 0.6)) return;
          if (el.querySelector('textarea, input, [contenteditable="true"], [role="textbox"]')) return;
          const cs = getComputedStyle(el);
          if (cs.position !== 'fixed' && cs.position !== 'sticky') return;
          hide(el);
        });
      }

      function fixSearchPage() {
        if (location.pathname.indexOf('/explore/search') !== 0) return;
        document.querySelectorAll('span, button, div, a').forEach(function(el) {
          if (el.children.length !== 0) return;
          if ((el.textContent || '').trim() !== 'Cancel') return;
          if (el.getBoundingClientRect().top > 120) return;
          hide(clickableFor(el) || el);
        });
        const input = document.querySelector('input[type="text"], input[placeholder]');
        if (input) {
          let node = input.parentElement;
          let depth = 0;
          while (node && depth < 4) {
            if (node.style.flexGrow !== '1') node.style.flexGrow = '1';
            if (node.style.maxWidth !== '100%') node.style.maxWidth = '100%';
            node = node.parentElement;
            depth++;
          }
        }
      }

      function fixDirectInbox() {
        if (!/^\\/direct\\/(inbox\\/?)?$/.test(location.pathname)) return;
        const back = document.querySelector('svg[aria-label="Back"]');
        if (back) hide(clickableFor(back));
      }

      // DM share cards render a tiny preview image scaled way up. When the
      // img carries a srcset, swap in its largest candidate.
      function fixDirectMediaQuality() {
        if (!/^\\/direct\\/t\\//.test(location.pathname)) return;
        const dpr = window.devicePixelRatio || 2;
        document.querySelectorAll('img[srcset]').forEach(function(img) {
          const rect = img.getBoundingClientRect();
          if (rect.width < 40 || !img.naturalWidth) return;
          if (img.naturalWidth >= rect.width * dpr * 0.75) return;
          let bestUrl = null;
          let bestW = 0;
          (img.getAttribute('srcset') || '').split(',').forEach(function(part) {
            const bits = part.trim().split(/\\s+/);
            const w = parseInt((bits[1] || '').replace('w', ''), 10) || 0;
            if (w > bestW) { bestW = w; bestUrl = bits[0]; }
          });
          if (bestUrl && bestW > img.naturalWidth && img.src !== bestUrl) {
            img.src = bestUrl;
            img.removeAttribute('srcset');
            img.removeAttribute('sizes');
          }
        });
      }

      // DM share cards often carry only a tiny thumbnail with no srcset, so
      // there is nothing local to upgrade to. For cards that link to a post
      // or reel, fetch the proper-size thumbnail from the oembed endpoint
      // (cached per shortcode) and swap it in.
      function upgradeDirectPreviews() {
        if (!isTopFrame || !/^\\/direct\\/t\\//.test(location.pathname)) return;
        document.querySelectorAll('a[href*="/reel/"], a[href*="/reels/"], a[href*="/p/"]').forEach(function(card) {
          const href = card.getAttribute('href') || '';
          const match = href.match(/\\/(reels?|p)\\/([A-Za-z0-9_-]+)/);
          if (!match) return;
          const code = match[2];
          let img = null;
          let bestWidth = 0;
          card.querySelectorAll('img').forEach(function(candidate) {
            const r = candidate.getBoundingClientRect();
            if (r.width > bestWidth) { bestWidth = r.width; img = candidate; }
          });
          if (!img || bestWidth < 80) return;
          if (img.dataset.biUpgraded) return;
          if (!img.naturalWidth || img.naturalWidth >= bestWidth * 1.5) return;
          img.dataset.biUpgraded = '1';
          const cached = dmThumbCache[code];
          if (cached) {
            img.src = cached;
            img.removeAttribute('srcset');
            img.removeAttribute('sizes');
            return;
          }
          fetch('/api/v1/oembed/?url=' + encodeURIComponent('https://www.instagram.com/p/' + code + '/'), {
            headers: { 'X-IG-App-ID': '936619743392459' },
            credentials: 'include'
          }).then(function(r) { return r.ok ? r.json() : null; })
            .then(function(payload) {
              if (!payload || !payload.thumbnail_url) return;
              dmThumbCache[code] = payload.thumbnail_url;
              img.src = payload.thumbnail_url;
              img.removeAttribute('srcset');
              img.removeAttribute('sizes');
              biLog('[dm] upgraded preview ' + code);
            }).catch(function() {});
        });
      }

      // Home header: center the Instagram logo and add a favorites star on
      // the left (plus/heart stay on the right where IG puts them). The star
      // opens the native favorites editor via the biFavEdit message.
      function fixHomeHeader() {
        if (location.pathname !== '/' || !isTopFrame) return;
        const logo = document.querySelector('svg[aria-label="Instagram"]');
        if (!logo) return;

        let header = logo.parentElement;
        let depth = 0;
        while (header && header !== document.body && depth < 12) {
          const r = header.getBoundingClientRect();
          if (r.width >= window.innerWidth * 0.9 && r.height > 0 && r.height < 150 &&
              !header.querySelector('article')) break;
          header = header.parentElement;
          depth++;
        }
        if (!header || header === document.body) return;
        if (getComputedStyle(header).position === 'static') header.style.position = 'relative';

        // The logo lives inside a small clickable control. IG sometimes renders
        // a feed-switcher CARET as a SEPARATE svg sibling next to the logo's box
        // (NOT inside it). Hide only that caret, then center the logo box exactly
        // as before (guarded so a shared icon row is never dragged along).
        const logoBox = logo.closest('a, [role="link"], [role="button"], button') || logo.parentElement;
        if (logoBox.querySelectorAll('svg').length === 1 && !logoBox.querySelector('article')) {
          if (logoBox.style.position !== 'absolute') {
            logoBox.style.position = 'absolute';
            logoBox.style.left = '50%';
            logoBox.style.top = '50%';
            logoBox.style.transform = 'translate(-50%, -50%)';
            logoBox.style.zIndex = '2';
          }
          // Caret sibling: a tiny (<44px) box right after the centered logo box.
          const sib = logoBox.nextElementSibling;
          if (sib && sib.querySelector && sib.querySelector('svg') &&
              !sib.querySelector('article') &&
              sib.getBoundingClientRect().width < 44) {
            sib.style.display = 'none';
          }
        }

        if (!document.getElementById('__bi_star_btn')) {
          const starButton = document.createElement('button');
          starButton.id = '__bi_star_btn';
          starButton.setAttribute('type', 'button');
          starButton.setAttribute('aria-label', 'Favorites');
          starButton.innerHTML = '<svg width="24" height="24" viewBox="0 0 24 24" fill="none" ' +
            'stroke="currentColor" stroke-width="1.8" stroke-linejoin="round" stroke-linecap="round">' +
            '<polygon points="12 2.6 15.09 8.86 22 9.87 17 14.74 18.18 21.62 12 18.37 5.82 21.62 7 14.74 2 9.87 8.91 8.86 12 2.6"></polygon></svg>';
          try { starButton.style.color = getComputedStyle(logo).color || 'inherit'; } catch (e) {}
          starButton.addEventListener('click', function(e) {
            e.preventDefault();
            e.stopPropagation();
            if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.biFavEdit) {
              window.webkit.messageHandlers.biFavEdit.postMessage(true);
            }
          });
          header.appendChild(starButton);
          if (!window.__biHeaderFixLogged) {
            window.__biHeaderFixLogged = true;
            biLog('[header] star injected depth=' + depth);
          }
        }
      }

      function removeReservedNavSpace() {
        const row = getNavRow();
        if (!row) return;
        let node = row.parentElement;
        let depth = 0;
        while (node && node !== document.body && depth < 10) {
          const computed = getComputedStyle(node);
          const paddingBottom = parseFloat(computed.paddingBottom) || 0;
          const marginBottom = parseFloat(computed.marginBottom) || 0;
          const height = node.offsetHeight;

          if (paddingBottom > 8 && node.style.paddingBottom !== '0px') {
            node.style.paddingBottom = '0px';
          }

          if (marginBottom < 0 && Math.abs(marginBottom) < height - 8) {
            const want = (-height) + 'px';
            if (node.style.marginBottom !== want) node.style.marginBottom = want;
          } else if (marginBottom > 8 && node.style.marginBottom !== '0px') {
            node.style.marginBottom = '0px';
          }

          node = node.parentElement;
          depth++;
        }
        if (document.documentElement.style.paddingBottom !== '0px') {
          document.documentElement.style.paddingBottom = '0px';
        }
        if (document.body.style.paddingBottom !== '0px') {
          document.body.style.paddingBottom = '0px';
        }
      }

      function computeNavVisible() {
        return !/^\\/(direct\\/t\\/|stories\\/)/.test(location.pathname);
      }

      function reportNavVisibility() {
        if (!isTopFrame) return;
        const visible = computeNavVisible();
        if (window.__biLastNavVisible !== visible) {
          window.__biLastNavVisible = visible;
          if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.biNav) {
            window.webkit.messageHandlers.biNav.postMessage(visible);
          }
        }
      }

      function findProfileAnchor(row) {
        const anchors = Array.from(row.querySelectorAll('a[href]'));
        return anchors.find(function(a) {
          const href = a.getAttribute('href') || '';
          return href !== '/' && href.indexOf('/direct') !== 0 && href !== '/reels/' && href !== '/explore/';
        });
      }

      function reportAvatar() {
        if (!isTopFrame) return;
        const row = getNavRow();
        if (!row) return;
        const profileAnchor = findProfileAnchor(row);
        const img = profileAnchor ? profileAnchor.querySelector('img') : row.querySelector('img');
        if (!img || !img.src) return;
        if (window.__biLastAvatarSrc !== img.src) {
          window.__biLastAvatarSrc = img.src;
          if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.biAvatar) {
            window.webkit.messageHandlers.biAvatar.postMessage(img.src);
          }
        }
      }

      function reportProfile() {
        if (!isTopFrame) return;
        if (window.__biLastProfileHref) return;
        const row = getNavRow();
        if (!row) return;
        let href = null;
        const anchor = findProfileAnchor(row);
        if (anchor) href = anchor.getAttribute('href');
        if (!href) {
          const img = row.querySelector('img[alt]');
          if (img) {
            const alt = img.getAttribute('alt') || '';
            const match = alt.match(/^(.+)'s profile picture$/);
            if (match) href = '/' + match[1] + '/';
          }
        }
        if (!href) return;
        window.__biLastProfileHref = href;
        biLog('[profile] ' + href);
        if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.biProfile) {
          window.webkit.messageHandlers.biProfile.postMessage(href);
        }
      }

      function reportFeedHealth() {
        if (location.pathname !== '/') return;
        const articles = document.querySelectorAll('article');
        if (articles.length === 0) return;
        let hidden = 0;
        const census = [];
        articles.forEach(function(a) {
          const h = a.classList.contains('__bi_hidden') || a.classList.contains('__bi_fav_hidden');
          if (h) hidden++;
          census.push((articleAuthor(a) || '?') + (h ? '(hid)' : '(shown)'));
        });
        // Log the author + shown/hidden state of every home article whenever it
        // changes. Tells us if the harvested favorites (frogkekw etc.) actually
        // rendered but got hidden by the DOM filter, vs never rendered at all.
        const line = articles.length + ' articles, ' + hidden + ' hidden: ' + census.join(',');
        if (window.__biFeedCensus !== line) {
          window.__biFeedCensus = line;
          biLog('[feed] ' + line);
        }
      }

      function isOpaqueColor(bg) {
        if (!bg || bg === 'transparent' || bg === 'rgba(0, 0, 0, 0)') return false;
        if (bg.indexOf('rgba(') === 0) {
          const parts = bg.slice(5, -1).split(',');
          if (parts.length === 4) {
            const alpha = parseFloat(parts[3]);
            if (!isNaN(alpha) && alpha < 0.9) return false;
          }
        }
        return true;
      }

      function currentPageBackground() {
        if (!document.body || !document.documentElement) return null;
        // The story viewer is full-screen black; IG's own body bg stays dark
        // grey, leaving the top safe area mismatched. Force pitch black there.
        if (/^\\/stories\\//.test(location.pathname)) return 'rgb(0, 0, 0)';
        const bodyBg = getComputedStyle(document.body).backgroundColor;
        if (isOpaqueColor(bodyBg)) return bodyBg;
        const htmlBg = getComputedStyle(document.documentElement).backgroundColor;
        if (isOpaqueColor(htmlBg)) return htmlBg;
        let node = document.body.firstElementChild;
        let depth = 0;
        while (node && depth < 6) {
          const bg = getComputedStyle(node).backgroundColor;
          if (isOpaqueColor(bg) && node.offsetHeight >= window.innerHeight * 0.8) return bg;
          node = node.firstElementChild;
          depth++;
        }
        const x = Math.floor(window.innerWidth / 2);
        const stack = document.elementsFromPoint(x, 1) || [];
        for (let i = 0; i < stack.length; i++) {
          const bg = getComputedStyle(stack[i]).backgroundColor;
          if (isOpaqueColor(bg)) return bg;
        }
        return null;
      }

      function reportBackgroundColor() {
        if (!isTopFrame) return;
        const bg = currentPageBackground();
        if (!bg) return;
        if (window.__biLastBg !== bg) {
          window.__biLastBg = bg;
          biLog('[bg] ' + bg);
          if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.biBg) {
            window.webkit.messageHandlers.biBg.postMessage(bg);
          }
        }
      }

      function goToPath(path) {
        if (location.pathname === path) return;
        window.history.pushState({}, '', path);
        window.dispatchEvent(new PopStateEvent('popstate'));
        setTimeout(function() {
          if (location.pathname !== path) {
            window.location.assign(path);
          }
        }, 300);
      }

      function clickableFor(el) {
        if (!el) return null;
        return el.closest('a[href], [role="link"], [role="button"], [role="tab"], button') || el.parentElement;
      }

      function navigate(kind) {
        const row = getNavRow();
        const scope = row || document;
        let target = null;
        if (kind === 'home') {
          target = scope.querySelector('a[href="/"]') ||
            clickableFor(scope.querySelector('svg[aria-label="Home"]'));
          if (target) { target.click(); return; }
          goToPath('/');
          return;
        }
        if (kind === 'search') {
          goToPath('/explore/search/');
          return;
        }
        if (kind === 'direct') {
          target = scope.querySelector('a[href^="/direct"]') ||
            clickableFor(scope.querySelector('svg[aria-label="Direct"]')) ||
            clickableFor(scope.querySelector('svg[aria-label="Messenger"]'));
          if (target) { target.click(); return; }
          goToPath('/direct/inbox/');
          return;
        }
        if (kind === 'profile') {
          if (window.__biLastProfileHref) {
            goToPath(window.__biLastProfileHref);
            return;
          }
          if (row) {
            target = findProfileAnchor(row);
            if (!target) target = clickableFor(row.querySelector('img'));
          }
          if (target) target.click();
        }
      }
      window.__biNavigate = navigate;

      let applyScheduled = false;
      let lastApply = 0;
      function apply() {
        applyScheduled = false;
        lastApply = Date.now();
        try {
          ensureStyleInjected();
          hideSponsoredAndReels();
          hideFeedNoise();
          lockToPrimaryReel();
          updateScrollLock();
          forcePlaysInline();
          dismissAppNag();
          hideOriginalNav();
          hideBottomBars();
          fixSearchPage();
          fixDirectInbox();
          fixDirectMediaQuality();
          upgradeDirectPreviews();
          fixHomeHeader();
          removeReservedNavSpace();
          reportNavVisibility();
          reportAvatar();
          reportProfile();
          reportFeedHealth();
          reportBackgroundColor();
        } catch (e) {
          biLog('[error] apply failed: ' + (e && e.message ? e.message : e));
        }
      }

      function scheduleApply() {
        if (applyScheduled) return;
        applyScheduled = true;
        const wait = Math.max(0, 300 - (Date.now() - lastApply));
        setTimeout(function() {
          requestAnimationFrame(apply);
        }, wait);
      }

      biLog('[boot] filter running on ' + location.pathname);
      if (isTopFrame && !window.__biErrHooked) {
        window.__biErrHooked = true;
        window.addEventListener('error', function(e) {
          const msg = e && e.message ? e.message : e;
          if (String(msg).indexOf('__bi') !== -1) return;
          biLog('[jserr] ' + msg + (e && e.filename ? ' @' + String(e.filename).slice(-40) : ''));
        });
        window.addEventListener('unhandledrejection', function(e) {
          const r = e && e.reason;
          biLog('[jsrej] ' + (r && r.message ? r.message : r));
        });
      }
      installSSRFeedSplice();
      installFetchFilter();
      installXHRFilter();
      installHistoryHook();
      installGestureLocks();
      preventNativeFullscreen();
      guardLocation();
      window.__biReapply = scheduleApply;
      window.__biSetFavorites = setFavorites;
      setFavorites(window.__biFavorites, window.__biFavoritesEnabled);

      const observer = new MutationObserver(function(mutations) {
        for (let i = 0; i < mutations.length; i++) {
          const added = mutations[i].addedNodes;
          for (let j = 0; j < added.length; j++) {
            const node = added[j];
            if (!node || node.nodeType !== 1) continue;
            if (node.tagName === 'ARTICLE') {
              filterArticle(node);
            } else if (node.querySelectorAll) {
              const articles = node.querySelectorAll('article');
              for (let k = 0; k < articles.length; k++) filterArticle(articles[k]);
            }
          }
        }
        scheduleApply();
      });

      function start() {
        if (document.body) {
          observer.observe(document.body, {
            childList: true,
            subtree: true,
            attributes: true,
            attributeFilter: ['class', 'style']
          });
          apply();
        } else {
          requestAnimationFrame(start);
        }
      }
      start();
    })();
    """

    static let reapplyCall = "window.__biReapply && window.__biReapply();"

    /// Self-contained extractor run (via callAsyncJavaScript) inside the hidden
    /// harvest webview after it navigates to /?variant=favorites. On a real
    /// navigation IG streams the favorites feed into the page HTML; this walks
    /// every <script> block, finds the xdt_api__v1__feed__timeline__connection
    /// edges, and returns them (plus diagnostics) as a JSON string.
    static let harvestScript = """
    const html = document.documentElement.outerHTML;
    function count(n) { return html.split(n).length - 1; }
    const markers = {
      conn: count('xdt_api__v1__feed__timeline__connection'),
      ft: count('feed__timeline'),
      relay: count('RelayPrefetchedStreamCache'),
      bbox: count('__bbox')
    };
    function tryParse(s) {
      try { return JSON.parse(s); } catch (e) {}
      let end = Math.max(s.lastIndexOf('}'), s.lastIndexOf(']'));
      let g = 0;
      while (end > 0 && g++ < 60) {
        try { return JSON.parse(s.slice(0, end + 1)); } catch (e) {}
        end = Math.max(s.lastIndexOf('}', end - 1), s.lastIndexOf(']', end - 1));
      }
      return null;
    }
    function findEdges(o, d) {
      if (!o || typeof o !== 'object' || d > 16) return null;
      for (const k in o) {
        const v = o[k];
        if (!v || typeof v !== 'object') continue;
        if (k.indexOf('feed__timeline') !== -1 && Array.isArray(v.edges)) return v.edges;
        const r = findEdges(v, d + 1);
        if (r) return r;
      }
      return null;
    }
    function authorOf(e) {
      let u = null;
      (function dig(o, d) {
        if (u || !o || typeof o !== 'object' || d > 6) return;
        if (typeof o.username === 'string') { u = o.username; return; }
        for (const k in o) { const v = o[k]; if (v && typeof v === 'object') dig(v, d + 1); if (u) return; }
      })(e && e.node, 0);
      return u || '?';
    }
    let found = null, scanned = 0;
    const re = /<script[^>]*>([\\s\\S]*?)<\\/script>/gi;
    let m;
    while (!found && (m = re.exec(html)) !== null) {
      const raw = m[1];
      if (raw.indexOf('feed__timeline') === -1) continue;
      scanned++;
      const start = raw.search(/[\\[{]/);
      if (start === -1) continue;
      const json = tryParse(raw.slice(start));
      if (json) found = findEdges(json, 0);
    }
    const edges = found || [];
    const authors = edges.slice(0, 20).map(authorOf);
    return JSON.stringify({ markers: markers, scanned: scanned, count: edges.length, authors: authors, edges: edges });
    """

    /// Run (via callAsyncJavaScript, args: harvestJson, usernames) in the hidden
    /// harvest webview after harvestScript. Densifies the ~3 streamed favorites
    /// edges by fetching each favorite's own recent profile media and APPENDING
    /// it. Invariants: streamed edges stay first and untouched (never sorted);
    /// every appended edge is a deep clone of a real harvested edge with only
    /// its media replaced by the real api/v1 media object (missing keys
    /// null-filled from the template); de-duped against everything already
    /// present; clips (reels) and old posts skipped. Any failure returns the
    /// original harvest JSON unchanged (fail-safe).
    static let densityScript = """
    const APP_ID = '936619743392459';
    const WINDOW_DAYS = 30;
    const PER_USER = 12;
    const MAX_TOTAL = 50;
    let data;
    try { data = JSON.parse(harvestJson); } catch (e) { return harvestJson; }
    const edges = data.edges || [];
    let template = null;
    for (const e of edges) {
      if (e && e.node && e.node.media) { template = e; break; }
    }
    if (!template) { return harvestJson; }
    const seen = new Set();
    const ids = {};
    edges.forEach(function(e) {
      try {
        const m = e.node.media;
        const id = m.pk || m.id || m.code;
        if (id != null) seen.add(String(id));
        const u = m.user;
        if (u && u.username && (u.pk || u.id)) {
          ids[String(u.username).toLowerCase()] = String(u.pk || u.id);
        }
      } catch (err) {}
    });
    for (const name of (usernames || [])) {
      const key = String(name).toLowerCase();
      if (ids[key]) continue;
      try {
        const r = await fetch('/api/v1/users/web_profile_info/?username=' + encodeURIComponent(key), {
          credentials: 'include', headers: { 'X-IG-App-ID': APP_ID }
        });
        if (!r.ok) continue;
        const j = await r.json();
        const id = j && j.data && j.data.user && j.data.user.id;
        if (id) ids[key] = String(id);
      } catch (err) {}
    }
    const cutoff = (Date.now() / 1000) - WINDOW_DAYS * 86400;
    const appended = [];
    const idList = [];
    for (const k in ids) { if (idList.indexOf(ids[k]) === -1) idList.push(ids[k]); }
    const stats = [];
    for (const uid of idList) {
      if (edges.length + appended.length >= MAX_TOTAL) break;
      let items = [];
      try {
        const r = await fetch('/api/v1/feed/user/' + uid + '/?count=' + PER_USER, {
          credentials: 'include', headers: { 'X-IG-App-ID': APP_ID }
        });
        if (!r.ok) { stats.push(uid + ':' + r.status); continue; }
        const j = await r.json();
        items = j.items || [];
      } catch (err) { stats.push(uid + ':err'); continue; }
      let kept = 0;
      for (const item of items) {
        if (!item) continue;
        if (kept >= PER_USER) break;
        if ((item.product_type || '') === 'clips') continue;
        if (item.taken_at && item.taken_at < cutoff) continue;
        if (!(item.image_versions2 || item.carousel_media || item.video_versions)) continue;
        const mid = item.pk || item.id || item.code;
        if (mid == null || seen.has(String(mid))) continue;
        seen.add(String(mid));
        const edge = JSON.parse(JSON.stringify(template));
        const tmedia = edge.node.media;
        for (const k in tmedia) { if (!(k in item)) item[k] = null; }
        edge.node.media = item;
        if ('cursor' in edge) edge.cursor = 'bi-' + String(mid);
        appended.push(edge);
        kept++;
        if (edges.length + appended.length >= MAX_TOTAL) break;
      }
      stats.push(uid + ':ok' + kept);
    }
    data.edges = edges.concat(appended);
    data.count = data.edges.length;
    data.appended = appended.length;
    data.fetch = stats.join(' ');
    return JSON.stringify(data);
    """

    /// Injected at document-start into the hidden harvest webview. Captures the
    /// favorites feed edges + page_info from every feed XHR into
    /// window.__biHarvestEdges / window.__biHarvestPageInfo, and records the
    /// pagination request (url/body/headers) so the harvest script can replay it
    /// with advancing cursors to page deep server-side.
    static let harvestCollectorScript = """
    (function() {
      if (window.__biHarvestPatched) return;
      window.__biHarvestPatched = true;
      window.__biHarvestEdges = [];
      window.__biHarvestPageInfo = null;
      window.__biHarvestPagReq = null;
      const seen = new Set();
      function collect(text) {
        if (!text || text.indexOf('feed__timeline') === -1) return;
        let p; try { p = JSON.parse(text); } catch (e) { return; }
        (function walk(o, d) {
          if (!o || typeof o !== 'object' || d > 16) return;
          for (const k in o) {
            const v = o[k];
            if (!v || typeof v !== 'object') continue;
            if (k.indexOf('feed__timeline') !== -1 && Array.isArray(v.edges)) {
              v.edges.forEach(function(e) {
                let id = null; try { id = e.node.media.pk || e.node.media.code || e.node.media.id; } catch (_) {}
                if (id != null && seen.has(id)) return;
                if (id != null) seen.add(id);
                window.__biHarvestEdges.push(e);
              });
              if (v.page_info) window.__biHarvestPageInfo = v.page_info;
            }
            walk(v, d + 1);
          }
        })(p, 0);
      }
      const oOpen = XMLHttpRequest.prototype.open;
      const oSend = XMLHttpRequest.prototype.send;
      const oSet = XMLHttpRequest.prototype.setRequestHeader;
      XMLHttpRequest.prototype.setRequestHeader = function(k, v) {
        if (!this.__biH) this.__biH = {};
        this.__biH[k] = v;
        return oSet.apply(this, arguments);
      };
      XMLHttpRequest.prototype.open = function(method, url) {
        this.__biU = String(url || '');
        return oOpen.apply(this, arguments);
      };
      XMLHttpRequest.prototype.send = function(body) {
        const x = this;
        if (/graphql|\\/api\\/v1\\/feed\\//.test(x.__biU || '')) {
          if (typeof body === 'string' && body.indexOf('PolarisFeedRootPaginationCachedQuery') !== -1) {
            window.__biHarvestPagReq = { url: x.__biU, body: String(body), headers: x.__biH || {} };
          }
          x.addEventListener('load', function() {
            try { collect(x.responseText); } catch (e) {}
          });
        }
        return oSend.apply(this, arguments);
      };
    })();
    """
}
