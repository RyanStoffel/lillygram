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
      const preRouteViewerGeometry = new WeakMap();
      let activeStorySurface = null;
      let activeReelSurface = null;
      window.__biVersion = 'device-polish-v2';
      const documentID = Math.round((window.performance && window.performance.timeOrigin) || Date.now()) + '-' +
        Math.random().toString(36).slice(2, 8);

      const style = document.createElement('style');
      style.id = '__bi_filter_style';
      style.textContent = `
        @media (prefers-color-scheme: dark) {
          html, body { background-color: rgb(12, 16, 20) !important; }
          section[role="dialog"], div[role="dialog"], section[role="region"] { background-color: rgb(12, 16, 20) !important; }
        }
        @media (prefers-color-scheme: light) {
          html, body { background-color: rgb(255, 255, 255) !important; }
          section[role="dialog"], div[role="dialog"], section[role="region"] { background-color: rgb(255, 255, 255) !important; }
        }
        a[href="/reels/"] { display: none !important; }
        a[href="/explore/"] { display: none !important; }
        svg[aria-label="Reels"] { display: none !important; }
        .__bi_hidden { display: none !important; }
        .__bi_fav_hidden { display: none !important; }
        .__bi_reel_hidden { display: none !important; }
        .__bi_lockedscroll { overflow: hidden !important; touch-action: none !important; overscroll-behavior: none !important; }
        html.__bi_noscroll, html.__bi_noscroll body { overflow: hidden !important; height: 100% !important; touch-action: none !important; }
        html.__bi_noscroll * { touch-action: none !important; }
        html.__bi_noscroll [role="dialog"]:not(:has(video)) { touch-action: pan-y !important; -webkit-overflow-scrolling: touch; }
        html.__bi_noscroll [role="dialog"]:not(:has(video)) * { touch-action: auto !important; }
        a, [role="button"], [role="link"] { cursor: pointer; }
        a, button, [role="button"], [role="link"], input, select, textarea { touch-action: manipulation; -webkit-tap-highlight-color: transparent; }
        #__bi_star_btn { position: absolute; left: 12px; top: 50%; transform: translateY(-50%); z-index: 3; background: none; border: 0; padding: 8px; display: flex; align-items: center; }
        @keyframes __bi_rot { to { transform: rotate(360deg); } }
      `;

      function postLog(msg) {
        try {
          if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.biLog) {
            window.webkit.messageHandlers.biLog.postMessage(String(msg));
          }
        } catch (e) {}
      }

      function biLog(msg) {
        if (!isTopFrame) return;
        postLog(msg);
      }

      // biFavReady tells native it's safe to drop the launch/resave splash.
      // Posting it as soon as favorites DATA has been spliced into a parsed
      // response (window.__biFavDataReady) is not enough on its own — that
      // only proves Relay/React WILL render favorites once it runs, not that
      // THIS document has actually styled itself yet: the hide-CSS
      // (ensureStyleInjected) and the header restyle (fixHomeHeader) only run
      // inside apply(), on document.body's own independent timer (see
      // start() below), with no ordering relationship to when the streamed
      // feed data happens to parse. Gating on window.__biFirstApplyDone too
      // (set at the end of apply()) means the splash can only drop once this
      // document has actually run its own DOM-filter pass — closing the
      // "reload flashes Instagram's raw nav" gap. See
      // docs/research-2026-07-27-coldstart-reload-flash.md.
      window.__biFavDataReady = false;
      window.__biFirstApplyDone = false;

      function maybePostFavReady() {
        if (!isTopFrame || window.__biFavReadyPosted) return;
        if (!window.__biFavDataReady || !window.__biFirstApplyDone) return;
        window.__biFavReadyPosted = true;
        try { webkit.messageHandlers.biFavReady.postMessage(true); } catch (e) {}
      }

      function markFavDataReady() {
        window.__biFavDataReady = true;
        maybePostFavReady();
        // Bounded safety net: apply()'s first pass normally follows within a
        // fraction of a second of document.body existing (see start()), so
        // this should never actually fire. But apply() stalling or throwing
        // for a reason unrelated to favorites (a DOM-filter bug, a slow
        // device) must never be able to permanently withhold biFavReady once
        // the data itself is genuinely ready — that would trade the cold-start
        // flash for an occasional hard hang, which is worse. If apply() still
        // hasn't completed 1.5s after data became ready, post anyway.
        if (!window.__biFavReadyPosted) {
          setTimeout(function() {
            if (window.__biFavDataReady && !window.__biFirstApplyDone) {
              biLog('[favsplice] apply() did not complete within 1.5s of data-ready; posting biFavReady anyway');
              window.__biFirstApplyDone = true;
            }
            maybePostFavReady();
          }, 1500);
        }
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

      const diagnosticNodeIDs = new WeakMap();
      let diagnosticNodeSequence = 0;
      function diagnosticNodeID(node) {
        if (!node) return 0;
        if (!diagnosticNodeIDs.has(node)) diagnosticNodeIDs.set(node, ++diagnosticNodeSequence);
        return diagnosticNodeIDs.get(node);
      }

      function shortAncestry(node, limit) {
        const values = [];
        for (let depth = 0; node && node !== document.body && depth < (limit || 4); depth++) {
          values.push(node.tagName + '#' + diagnosticNodeID(node) +
            (node.getAttribute && node.getAttribute('role') ? '[role=' + node.getAttribute('role') + ']' : ''));
          node = node.parentElement;
        }
        return values.join('>');
      }

      // ---- route helpers -------------------------------------------------

      function diagnosticPath(path) {
        path = String(path || '/');
        if (/^\\/direct\\/t\\//.test(path)) return '/direct/t/<id>/';
        if (/^\\/stories\\//.test(path)) return '/stories/<id>/';
        if (/^\\/(reels?|p|tv)\\//.test(path)) return '/' + path.split('/')[1] + '/<id>/';
        if (/^\\/[A-Za-z0-9._]+\\/?$/.test(path) && path !== '/') return '/<profile>/';
        return path;
      }

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

      function visibleViewerElement(el, minWidth, minHeight) {
        if (!el || !el.isConnected) return false;
        const r = el.getBoundingClientRect();
        if (r.width < window.innerWidth * minWidth || r.height < window.innerHeight * minHeight) return false;
        if (r.bottom <= 0 || r.top >= window.innerHeight) return false;
        const cs = getComputedStyle(el);
        return cs.display !== 'none' && cs.visibility !== 'hidden' && parseFloat(cs.opacity || '1') > 0.01;
      }

      function becameViewerSized(el, minWidth, minHeight) {
        const before = preRouteViewerGeometry.get(el);
        return !before || before.width < minWidth || before.height < minHeight;
      }

      function rememberPreRouteViewerGeometry(url) {
        if (url === undefined || url === null) return;
        let nextPath = null;
        try { nextPath = new URL(String(url), location.href).pathname; } catch (e) { return; }
        if (nextPath === location.pathname) return;
        document.querySelectorAll('img, video, canvas, [role="dialog"]').forEach(function(el) {
          const r = el.getBoundingClientRect();
          preRouteViewerGeometry.set(el, {
            width: r.width / Math.max(window.innerWidth, 1),
            height: r.height / Math.max(window.innerHeight, 1)
          });
        });
      }

      function storyViewerSurface() {
        if (visibleViewerElement(activeStorySurface, 0.55, 0.45)) return activeStorySurface;
        activeStorySurface = null;
        if (!/^\\/stories\\//.test(location.pathname)) return null;
        const candidates = document.querySelectorAll('[role="dialog"], video, canvas, img');
        for (let i = 0; i < candidates.length; i++) {
          const candidate = candidates[i];
          if (candidate.closest && candidate.closest('article')) continue;
          if (!visibleViewerElement(candidate, 0.55, 0.45)) continue;
          if (!becameViewerSized(candidate, 0.55, 0.45)) continue;
          activeStorySurface = candidate;
          return candidate;
        }
        return null;
      }

      function reelViewerSurface() {
        if (visibleViewerElement(activeReelSurface, 0.85, 0.6)) return activeReelSurface;
        activeReelSurface = null;
        const candidate = activeReelVideo();
        if (!candidate || !becameViewerSized(candidate, 0.85, 0.6)) return null;
        activeReelSurface = candidate;
        return candidate;
      }

      // The reels viewer doesn't always change the URL (opened from a DM
      // thread it can be an overlay while the path stays /direct/t/...), so
      // lock on either a reel permalink or a near-fullscreen video. Home and
      // stories are excluded: feed videos never lock the feed, and stories
      // need their own gestures.
      //
      // The geometry check alone is probabilistic: it can misfire on some
      // other fullscreen video (an IGTV /tv/ page, a profile-grid post modal)
      // or miss a real one on a markup change. `dmOverlaySignal()` is a
      // secondary, more structural corroboration: the DM reel overlay stays
      // on a /direct/ route and renders inside a dialog layer over the
      // thread (see the comment above and the [role="dialog"] use elsewhere
      // in this file). It is a failure guard, not a gate: if it can't
      // confirm, we still lock. R2 only requires that a real DM reel never
      // chains — a false positive (locking some other fullscreen video) is
      // low-cost, but a false negative would let chaining slip through.
      function dmOverlaySignal(video) {
        if (/^\\/direct\\//.test(location.pathname)) return true;
        try {
          return !!video.closest('[role="dialog"]');
        } catch (e) {
          return false;
        }
      }

      function activeReelVideo() {
        if (location.pathname === '/' || /^\\/stories\\//.test(location.pathname)) return null;
        const videos = document.querySelectorAll('video');
        for (let i = 0; i < videos.length; i++) {
          const video = videos[i];
          const r = video.getBoundingClientRect();
          const geometryMatch = r.width >= window.innerWidth * 0.85 && r.height >= window.innerHeight * 0.6;
          if (!geometryMatch) continue;
          if (!dmOverlaySignal(video)) {
            biLog('[reel-lock] geometry match without route/dialog corroboration at ' + location.pathname + ' - locking anyway');
          }
          return video;
        }
        return null;
      }

      function shouldLockScroll() {
        if (isReelPermalink() && document.querySelector('video')) return true;
        return !!activeReelVideo();
      }

      function isImmersiveSurface(lock) {
        return !!(storyViewerSurface() || reelViewerSurface());
      }

      function postPresentation(lock, immersive, reason) {
        if (!isTopFrame) return;
        const key = (lock ? '1' : '0') + (immersive ? '1' : '0');
        if (window.__biLastPresentation === key) return;
        window.__biLastPresentation = key;
        biLog('[present] lock=' + lock + ' immersive=' + immersive + ' reason=' + reason + ' path=' + location.pathname);
        if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.biPresentation) {
          window.webkit.messageHandlers.biPresentation.postMessage({ locked: lock, immersive: immersive });
        }
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
          // Once the splice is known to have failed there is no trustworthy
          // allowlist left, so "leave unknown authors alone" stops being the
          // safe default and becomes an R1 hole. Fail closed instead.
          if (!author && window.__biFeedDegraded) {
            hide(article);
            return;
          }
        }
      }

      function hideSponsoredAndReels() {
        if (isMediaPermalink()) return;
        scanRoot().querySelectorAll('article').forEach(filterArticle);
        // Bare (non-article) reel links are feed/explore chrome to strip —
        // except inside a DM thread, where a friend's shared reel is R2's one
        // named exception and must stay tappable. DM messages aren't wrapped
        // in <article>, so without this guard the share card's own link was
        // being hidden by the same rule meant for loose feed/explore reel
        // promos, which also broke its hit-testing (not just its visibility).
        if (!/^\\/direct\\//.test(location.pathname)) {
          scanRoot().querySelectorAll('a[href^="/reel/"], a[href^="/reels/"]').forEach(function(a) {
            if (a.getAttribute('href') === '/reels/') return;
            if (!a.closest('article')) hide(a);
          });
        }
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

      // ---- search result filtering (R3) -----------------------------------
      // Instagram's search endpoints ("topsearch" blended search, and the
      // Explore search-results calls the search screen makes as you type) can
      // return posts, hashtags, places, and AI/"about this" summary blocks
      // alongside account (`users`) results in the SAME response. Unlike the
      // home feed, search results are never server-streamed into the initial
      // page HTML (they only exist after the user types a query), so there is
      // no document-start JSON.parse block to hook the way
      // installSSRFeedSplice() does for the feed. The equivalent choke point
      // here is the network-response layer this file already patches for the
      // same "rewrite the data before React renders it" reason
      // (installFetchFilter / installXHRFilter below): stripping non-account
      // keys there means Instagram's own search UI only ever sees accounts,
      // so there is no post/hashtag/AI flash to hide after the fact (R4).
      //
      // ASSUMPTION - verify on device via the [search] biLog line: the exact
      // key names below (hashtags/places/clips/sections/etc.) are inferred
      // from the known topsearch shape (see blocking-and-selectors.md) and
      // Instagram's general search/Explore conventions, not captured live
      // from a real search response in this sandbox. If a real response uses
      // different key names for its non-account content, this needs a
      // follow-up capture + key update.
      function looksLikeSearchPayload(obj) {
        return !!obj && typeof obj === 'object' && Array.isArray(obj.users);
      }

      // 'sections' is Instagram's generic Explore/search results container: an
      // array of typed blocks (accounts, media grid, hashtags, ...). Keep only
      // sections that look account-shaped; unrecognized shapes are left alone
      // (fail open) so an account section we don't recognize is never hidden -
      // same "unknown is left alone" philosophy as articleAuthor() above.
      function filterSearchSections(sections) {
        if (!Array.isArray(sections)) return null;
        let changed = false;
        const kept = sections.filter(function(section) {
          if (!section || typeof section !== 'object') return true;
          const type = String(
            section.feed_type || section.type ||
            (section.layout_content && section.layout_content.type) || ''
          ).toLowerCase();
          if (!type) return true;
          if (type.indexOf('user') !== -1 || type.indexOf('account') !== -1) return true;
          if (type.indexOf('media') !== -1 || type.indexOf('hashtag') !== -1 ||
              type.indexOf('place') !== -1 || type.indexOf('clip') !== -1 ||
              type.indexOf('ai') !== -1) {
            changed = true;
            return false;
          }
          return true;
        });
        return changed ? kept : null;
      }

      // Non-account result keys topsearch/Explore-search can carry alongside
      // `users`. Emptied rather than deleted so Instagram's own rendering code
      // (which may assume the key exists) never trips over a missing field -
      // an empty array/null renders as "no results" for that section, never a
      // flash of content.
      const SEARCH_STRIP_KEYS = [
        'hashtags', 'places', 'clips', 'medias', 'media_grid', 'reels',
        'top_results', 'keyword_results', 'explore_grid',
        'ai_agent_response', 'about_this_account'
      ];

      function stripNonAccountSearchKeys(payload) {
        let changed = false;
        SEARCH_STRIP_KEYS.forEach(function(key) {
          const value = payload[key];
          if (value == null) return;
          if (Array.isArray(value)) {
            if (value.length) { payload[key] = []; changed = true; }
          } else {
            payload[key] = null;
            changed = true;
          }
        });
        if (Array.isArray(payload.sections)) {
          const kept = filterSearchSections(payload.sections);
          if (kept) { payload.sections = kept; changed = true; }
        }
        return changed;
      }

      // Entry point used by both the fetch and XHR intercepts below. Only
      // touches payloads that carry a `users` array (see
      // looksLikeSearchPayload) - a plain feed/profile response never has one
      // at the top level, so this cannot misfire on unrelated data.
      function filterSearchPayload(payload) {
        if (!looksLikeSearchPayload(payload)) return false;
        return stripNonAccountSearchKeys(payload);
      }

      // Cheap text-level pre-check so fetch/XHR bodies that are obviously not
      // search responses (the vast majority of traffic) skip the JSON.parse
      // cost entirely (P5: no main-thread jank from injected JS).
      function looksLikeSearchText(text) {
        return typeof text === 'string' &&
          text.indexOf('"users"') !== -1 &&
          (text.indexOf('"hashtags"') !== -1 || text.indexOf('"places"') !== -1 ||
           text.indexOf('"clips"') !== -1 || text.indexOf('"sections"') !== -1 ||
           text.indexOf('"rank_token"') !== -1);
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
        // Main document only: the streamed feed blocks only ever exist in the
        // top document, and a subframe's JSON.parse is a different realm that
        // can never see them.
        if (!isTopFrame || window.__biSSRPatched) return;
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
                markFavDataReady();
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
          try {
            const init = arguments[1];
            logFeedRequest(url, init && init.body);
          } catch (e) {}
          const result = origFetch.apply(this, arguments);
          if (!/\\/graphql|\\/api\\/v1\\/feed\\/|\\/api\\/v1\\/web\\/search\\/|\\/api\\/v1\\/fbsearch\\//.test(url)) return result;
          return result.then(function(response) {
            return response.clone().text().then(function(text) {
              const isFeedLike = text.indexOf('feed__timeline') !== -1 || text.indexOf('feed_items') !== -1;
              const isSearchLike = looksLikeSearchText(text);
              if (!isFeedLike && !isSearchLike) return response;
              let payload;
              try { payload = JSON.parse(text); } catch (e) { return response; }
              const labels = [];
              let changed = false;
              // R3: strip non-account search results (posts/hashtags/places/
              // AI blocks) before Instagram's own code renders them. This is
              // unrelated to the home feed splice below and runs regardless
              // of favoritesOn.
              if (isSearchLike && filterSearchPayload(payload)) {
                changed = true;
                labels.push('filtered search results to accounts-only');
              }
              // In favorites mode the request rewrite already made IG return
              // its favorites feed — leave the feed response completely
              // untouched so IG renders it natively (modifying/re-serializing
              // it makes IG's Relay renderer throw).
              if (isFeedLike && !favoritesOn && filterFeedPayload(payload, 0)) {
                changed = true;
                labels.push('filtered feed page');
              }
              if (!changed) return response;
              biLog('[fetch] ' + labels.join(', ') + ' ' + url.slice(0, 80));
              try {
                return new Response(JSON.stringify(payload), {
                  status: response.status,
                  statusText: response.statusText,
                  headers: response.headers
                });
              } catch (e) { return response; }
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
        // Returns rewritten JSON string, or null if unchanged (not a feed or
        // search response we care about, or nothing needed rewriting).
        if (!text) return null;
        const isFeedLike = text.indexOf('feed__timeline') !== -1 || text.indexOf('feed_items') !== -1;
        const isSearchLike = looksLikeSearchText(text);
        if (!isFeedLike && !isSearchLike) return null;
        let payload;
        try { payload = JSON.parse(text); } catch (e) { return null; }
        let changed = false;
        // R3: strip non-account search results before Instagram's search UI
        // renders them. Independent of favoritesOn / native-favorites mode -
        // unrelated to the feed connection those affect.
        if (isSearchLike && filterSearchPayload(payload)) {
          changed = true;
          biLog('[search] filtered search results to accounts-only (xhr)');
        }
        if (isFeedLike && window.__biNativeFavMode) {
          if (location.pathname === '/') markFavDataReady();
        }
        // In native-favorites mode IG serves the favorites feed itself; never
        // rewrite a feed response there or Relay throws and the feed spins
        // (see favorites-feed.md).
        if (isFeedLike && !window.__biNativeFavMode) {
          if (favoritesOn) {
            const before = extractTimelineEdges(payload);
            const feedChanged = spliceFavoriteEdges(payload);
            if (feedChanged) {
              changed = true;
              biLog('[favsplice] swapped favorites into home response');
              // Tell native the favorites feed is ready (once this document
              // has also styled itself — see markFavDataReady) so it can drop
              // the splash.
              if (location.pathname === '/') markFavDataReady();
            } else {
              if (before && before.length) feedRenderedAlgorithmic = true;
              biLog('[favsplice] NO SWAP (favEdges=' + (favEdges ? favEdges.length : 0) +
                ' authors=' + (before ? edgeAuthors(before) : '?') + ')');
            }
          } else {
            const feedChanged = filterFeedPayload(payload, 0);
            if (feedChanged) { changed = true; biLog('[xhr] stripped reels/ads from feed'); }
          }
        }
        return changed ? JSON.stringify(payload) : null;
      }

      function installLazyRewrite(xhr) {
        let computed = false;
        let cachedText = null; // rewritten JSON string, or null if unchanged
        function compute() {
          if (computed || xhr.readyState !== 4) return;
          computed = true;
          // Native-favorites-mode's "never touch a feed response" guard now
          // lives inside rewriteFeedText() itself, since a search response on
          // the same XHR filter must still be filtered (R3) even when the
          // home feed is in that mode.
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

      // R1 fails CLOSED. If the harvest never delivers usable favorite edges,
      // the held home request is released anyway (holding it forever would
      // just be a permanent spinner) and Instagram renders its algorithmic
      // feed. That must never be presented as a successful favorites feed, so
      // tell native, which blocks the home surface with the degraded/retry
      // screen instead of dropping the splash onto it.
      function reportFeedDegraded(reason) {
        if (!isTopFrame || window.__biFeedDegraded) return;
        window.__biFeedDegraded = true;
        biLog('[favsplice] DEGRADED (' + reason + ') - failing closed');
        scheduleApply();
        try {
          if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.biFeedStuck) {
            window.webkit.messageHandlers.biFeedStuck.postMessage(true);
          }
        } catch (e) {}
      }

      // Native entry point: receives the harvested favorites payload
      // ({markers, count, authors, edges}) as a JSON string.
      window.__biSetFavEdges = function(payload) {
        try {
          const obj = typeof payload === 'string' ? JSON.parse(payload) : payload;
          const rawEdges = obj && obj.edges;
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
            if (favoritesOn) reportFeedDegraded('harvest delivered 0 edges');
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
              // The request still goes out — a held-forever request is just a
              // permanent spinner — but native is told first, so the feed it
              // renders is covered by the degraded screen, never presented as
              // the favorites feed (R1).
              reportFeedDegraded('harvest edges never arrived');
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
          if (/\\/graphql|\\/api\\/v1\\/feed\\/|\\/api\\/v1\\/web\\/search\\/|\\/api\\/v1\\/fbsearch\\//.test(this.__biUrl)) {
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

      let feedDiagnostic = null;
      function articleDiagnosticID(article) {
        if (!article || !article.querySelector) return '?';
        const media = article.querySelector('a[href^="/p/"], a[href^="/reel/"], a[href^="/reels/"]');
        return (media && diagnosticPath(media.getAttribute('href'))) || ('node:' + diagnosticNodeID(article));
      }

      function beginFeedDiagnostic(reason) {
        if (!isTopFrame || location.pathname !== '/') return;
        if (feedDiagnostic && feedDiagnostic.timer) clearTimeout(feedDiagnostic.timer);
        feedDiagnostic = { reason: reason, added: 0, removed: 0, reused: 0, markerRemoved: 0, ids: [], timer: null };
        feedDiagnostic.timer = setTimeout(function() {
          if (!feedDiagnostic) return;
          const value = feedDiagnostic;
          feedDiagnostic = null;
          biLog('[feed-remount] reason=' + value.reason + ' added=' + value.added +
            ' removed=' + value.removed + ' reused=' + value.reused +
            ' markerRemoved=' + value.markerRemoved + ' ids=' + JSON.stringify(value.ids.slice(0, 8)));
        }, 1800);
      }

      function noteFeedArticles(nodes, kind) {
        if (!feedDiagnostic || !nodes) return;
        for (let i = 0; i < nodes.length; i++) {
          const node = nodes[i];
          if (!node || node.nodeType !== 1) continue;
          const articles = [];
          if (node.tagName === 'ARTICLE') articles.push(node);
          if (node.querySelectorAll) node.querySelectorAll('article').forEach(function(article) { articles.push(article); });
          feedDiagnostic[kind] += articles.length;
          articles.forEach(function(article) {
            if (feedDiagnostic.ids.length < 8) feedDiagnostic.ids.push(kind + ':' + articleDiagnosticID(article));
          });
        }
      }

      let lastRoutePath = location.pathname;
      function onRouteChange() {
        const oldPath = lastRoutePath;
        const newPath = location.pathname;
        lastRoutePath = newPath;
        if (oldPath !== newPath) biLog('[route] ' + diagnosticPath(oldPath) + ' -> ' +
          diagnosticPath(newPath) + ' doc=' + documentID);
        updateScrollLock();
        reportNavVisibility();
        reportBackgroundColor();
        if (newPath === '/') {
          beginFeedDiagnostic('route-return:' + oldPath);
          requestAnimationFrame(apply);
        } else {
          scheduleApply();
        }
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
            rememberPreRouteViewerGeometry(url);
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

      // A reel opened from a DM share card is presented in an overlay that
      // Instagram slides in from the right. The trusted activation records a
      // pending token before Instagram handles it; the observer then hides the
      // mounted surface before paint, waits out the slide, and reveals our pop.
      // The overlay is not always [role="dialog"], so retain the near-fullscreen
      // fixed/absolute and scroll-container fallbacks.
      function reelOverlayContainer(video) {
        const byRole = video.closest('[role="dialog"]');
        if (byRole) return byRole;
        const byScroll = scrollLockContainer(video);
        if (byScroll) return byScroll;
        let node = video.parentElement;
        let depth = 0;
        while (node && node !== document.body && depth < 10) {
          const cs = getComputedStyle(node);
          if ((cs.position === 'fixed' || cs.position === 'absolute')) {
            const r = node.getBoundingClientRect();
            if (r.width >= window.innerWidth * 0.9 && r.height >= window.innerHeight * 0.6) return node;
          }
          node = node.parentElement;
          depth++;
        }
        return null;
      }

      function reduceMotionRequested() {
        return !!(window.matchMedia && window.matchMedia('(prefers-reduced-motion: reduce)').matches);
      }

      let dmReelPending = null;
      try {
        const storedPending = Number(sessionStorage.getItem('__biDMReelPendingUntil') || 0);
        if (!reduceMotionRequested() && storedPending > Date.now()) {
          dmReelPending = { until: storedPending, source: 'previous-document' };
        } else {
          sessionStorage.removeItem('__biDMReelPendingUntil');
        }
      } catch (e) {}

      function markDMReelPending(source) {
        if (reduceMotionRequested()) return;
        const until = Date.now() + 900;
        dmReelPending = { until: until, source: source };
        try { sessionStorage.setItem('__biDMReelPendingUntil', String(until)); } catch (e) {}
        biLog('[dm-pop] pending source=' + source + ' path=' + diagnosticPath(location.pathname));
      }

      function dmReelPendingActive() {
        if (reduceMotionRequested() || !dmReelPending || dmReelPending.until <= Date.now()) {
          dmReelPending = null;
          try { sessionStorage.removeItem('__biDMReelPendingUntil'); } catch (e) {}
          return false;
        }
        return true;
      }

      function dmPopAncestorCapture(surface, video) {
        const values = [];
        let node = video || surface;
        for (let depth = 0; node && node !== document.body && depth < 8; depth++) {
          const cs = getComputedStyle(node);
          const r = node.getBoundingClientRect();
          let animations = [];
          try {
            if (node.getAnimations) animations = node.getAnimations({ subtree: false }).map(function(animation) {
              return animation.animationName || animation.playState || 'animation';
            }).slice(0, 4);
          } catch (e) {}
          values.push({ tag: node.tagName, role: node.getAttribute && (node.getAttribute('role') || ''),
            rect: [Math.round(r.left), Math.round(r.top), Math.round(r.width), Math.round(r.height)],
            inlineTransform: node.style && node.style.transform || '', transform: cs.transform,
            transition: cs.transition, animation: cs.animationName, animations: animations });
          node = node.parentElement;
        }
        return values;
      }

      function revealDMReelSurface(surface, reason) {
        if (!surface || surface.dataset.biPopRevealed === '1') return;
        surface.dataset.biPopRevealed = '1';
        biLog('[dm-pop] reveal reason=' + reason + ' role=' +
          (surface.getAttribute('role') || surface.tagName));
        try {
          surface.style.setProperty('visibility', 'visible', 'important');
          surface.style.setProperty('transition', 'none', 'important');
          surface.style.setProperty('transform', 'scale(0.88)', 'important');
          surface.style.setProperty('opacity', '0', 'important');
        } catch (e) {}
        requestAnimationFrame(function() {
          try {
            surface.style.setProperty(
              'transition',
              'transform 0.22s cubic-bezier(0.2,0.8,0.2,1), opacity 0.22s ease-out',
              'important'
            );
            surface.style.setProperty('transform', 'scale(1)', 'important');
            surface.style.setProperty('opacity', '1', 'important');
          } catch (e) {}
          setTimeout(function() {
            try {
              surface.style.removeProperty('visibility');
              surface.style.removeProperty('transition');
              surface.style.removeProperty('transform');
              surface.style.removeProperty('opacity');
            } catch (e) {}
          }, 260);
        });
      }

      function gateDMReelSurface(surface, video) {
        if (!surface || surface.dataset.biPopGated === '1' || !dmReelPendingActive()) return;
        surface.dataset.biPopGated = '1';
        surface.dataset.biPopped = '1';
        try {
          surface.style.setProperty('visibility', 'hidden', 'important');
          surface.style.setProperty('opacity', '0', 'important');
        } catch (e) {}
        let capture = [];
        try { capture = dmPopAncestorCapture(surface, video); } catch (e) {
          capture = [{ error: String(e) }];
        }
        biLog('[dm-pop] ancestors=' + JSON.stringify(capture));
        biLog('[dm] reel pop applied role=' + (surface.getAttribute('role') || surface.tagName));
        dmReelPending = null;
        try { sessionStorage.removeItem('__biDMReelPendingUntil'); } catch (e) {}
        const started = Date.now();
        let stableFrames = 0;
        let lastGeometry = '';
        let finished = false;
        function reveal(reason) {
          if (finished) return;
          finished = true;
          revealDMReelSurface(surface, reason);
        }
        function waitForRest() {
          if (finished || !surface.isConnected) { reveal('detached'); return; }
          const currentVideo = video && video.isConnected ? video : surface.querySelector('video');
          const r = surface.getBoundingClientRect();
          const cs = getComputedStyle(surface);
          const geometry = [Math.round(r.left), Math.round(r.top), Math.round(r.width), Math.round(r.height),
            cs.transform, cs.transition].join('|');
          stableFrames = geometry === lastGeometry ? stableFrames + 1 : 0;
          lastGeometry = geometry;
          const fullEnough = !!currentVideo && r.width >= window.innerWidth * 0.8 &&
            r.height >= window.innerHeight * 0.55;
          if (fullEnough && stableFrames >= 2) { reveal('settled'); return; }
          if (Date.now() - started >= 340) { reveal('timeout'); return; }
          requestAnimationFrame(waitForRest);
        }
        requestAnimationFrame(waitForRest);
        setTimeout(function() { reveal('hard-timeout'); }, 400);
      }

      function gatePendingDMReel(root) {
        if (!dmReelPendingActive() || !root || root.nodeType !== 1) return;
        let video = root.matches && root.matches('video') ? root :
          (root.querySelector ? root.querySelector('video') : null);
        let surface = null;
        if (video) surface = reelOverlayContainer(video) || video;
        if (!surface && root.matches && root.matches('[role="dialog"]')) surface = root;
        if (!surface && root.getBoundingClientRect) {
          const cs = getComputedStyle(root);
          const r = root.getBoundingClientRect();
          if ((cs.position === 'fixed' || cs.position === 'absolute') &&
              r.width >= window.innerWidth * 0.8 && r.height >= window.innerHeight * 0.55) surface = root;
        }
        if (surface) gateDMReelSurface(surface, video);
      }

      function maybeAnimateReelEntry(video) {
        if (!video || !dmReelPendingActive()) return;
        gateDMReelSurface(reelOverlayContainer(video) || video, video);
      }

      function updateScrollLock() {
        const lock = shouldLockScroll();
        const immersive = isImmersiveSurface(lock);
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
          maybeAnimateReelEntry(video);
        } else {
          document.querySelectorAll('.__bi_lockedscroll').forEach(function(el) {
            el.classList.remove('__bi_lockedscroll');
          });
          document.querySelectorAll('.__bi_reel_hidden').forEach(function(el) {
            el.classList.remove('__bi_reel_hidden');
          });
        }
        postPresentation(lock, immersive, 'dom');
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

      // Mark the visual layers over each DM share-card anchor as clickable.
      // This helps WebKit's tap classification, but the capture-phase routing
      // below is the reliable path because the visual card and link are siblings.
      function fixDMShareCardCursor() {
        if (!/^\\/direct\\//.test(location.pathname)) return;
        document.querySelectorAll(
          'a[href*="/reel/"], a[href*="/reels/"], a[href*="/p/"]'
        ).forEach(function(a) {
          const r = a.getBoundingClientRect();
          if (r.width <= 0 || r.height <= 0) return;
          const cx = r.left + r.width / 2;
          const cy = r.top + r.height / 2;
          let node = document.elementFromPoint(cx, cy);
          for (let i = 0; i < 4 && node; i++) {
            if (node.style && node.style.cursor !== 'pointer') {
              node.style.cursor = 'pointer';
            }
            node = node.parentElement;
          }
          if (a.style.cursor !== 'pointer') a.style.cursor = 'pointer';
        });
      }

      function reelURLForAnchor(anchor) {
        if (!anchor) return null;
        try {
          const url = new URL(anchor.getAttribute('href') || '', location.href);
          if (url.hostname !== 'instagram.com' && !url.hostname.endsWith('.instagram.com')) return null;
          if (!/^\\/reels?\\/[A-Za-z0-9_-]+\\/?$/.test(url.pathname)) return null;
          return url;
        } catch (e) {
          return null;
        }
      }

      function reelURLInCard(node) {
        const urls = {};
        const anchors = [];
        if (node.matches && node.matches('a[href]')) anchors.push(node);
        node.querySelectorAll('a[href]').forEach(function(anchor) { anchors.push(anchor); });
        anchors.forEach(function(anchor) {
          const url = reelURLForAnchor(anchor);
          if (url) urls[url.pathname] = url;
        });
        const paths = Object.keys(urls);
        return paths.length === 1 ? urls[paths[0]] : null;
      }

      function reelURLNearDMTarget(target, x, y) {
        if (!/^\\/direct\\/t\\//.test(location.pathname) || !(target instanceof Element)) return null;
        const anchor = target.closest('a[href]');
        if (anchor) return reelURLForAnchor(anchor);
        if (target.closest('input, textarea, select, [contenteditable="true"]')) return null;
        let node = target;
        for (let depth = 0; node && node !== document.body && depth < 16; depth++) {
          const rect = node.getBoundingClientRect();
          if (rect.height > 0 && rect.height <= window.innerHeight * 0.9) {
            const url = reelURLInCard(node);
            if (url) return url;
          }
          node = node.parentElement;
        }
        if (typeof x !== 'number' || typeof y !== 'number') return null;
        let nearest = null;
        let nearestDistance = Infinity;
        document.querySelectorAll('a[href*="/reel/"], a[href*="/reels/"]').forEach(function(candidate) {
          const url = reelURLForAnchor(candidate);
          if (!url) return;
          const rect = candidate.getBoundingClientRect();
          if (rect.width <= 0 || rect.height <= 0 || rect.bottom < 0 || rect.top > window.innerHeight) return;
          const dx = Math.max(rect.left - x, 0, x - rect.right);
          const dy = Math.max(rect.top - y, 0, y - rect.bottom);
          const distance = Math.sqrt(dx * dx + dy * dy);
          if (distance < nearestDistance) {
            nearest = url;
            nearestDistance = distance;
          }
        });
        if (nearestDistance <= Math.min(220, window.innerWidth * 0.55)) return nearest;
        return null;
      }

      function isDMShareCardTap(target) {
        if (!(target instanceof Element)) return false;
        let node = target;
        for (let depth = 0; node && node !== document.body && depth < 10; depth++) {
          const rect = node.getBoundingClientRect();
          if (rect.height > window.innerHeight * 0.75) break;
          const images = node.matches('img') ? [node] : node.querySelectorAll('img');
          for (let i = 0; i < images.length; i++) {
            const imageRect = images[i].getBoundingClientRect();
            if (imageRect.width >= 100 && imageRect.height >= 100) return true;
          }
          node = node.parentElement;
        }
        return false;
      }

      // The visible DM card and its permalink are siblings, so Instagram's
      // delegated handler receives the first trusted click on a plain div but
      // does not navigate. Resolve the link through their smallest common
      // container and navigate synchronously before Instagram consumes it.
      function installDMReelClickRouting() {
        if (window.__biDMReelClickPatched) return;
        window.__biDMReelClickPatched = true;
        let touch = null;
        let misses = 0;
        document.addEventListener('touchstart', function(e) {
          touch = null;
          if (!/^\\/direct\\/t\\//.test(location.pathname) || e.touches.length !== 1) return;
          const point = e.touches[0];
          touch = { id: point.identifier, x: point.clientX, y: point.clientY, target: e.target };
        }, { capture: true, passive: true });
        document.addEventListener('touchmove', function(e) {
          if (!touch) return;
          for (let i = 0; i < e.touches.length; i++) {
            const point = e.touches[i];
            if (point.identifier !== touch.id) continue;
            if (Math.abs(point.clientX - touch.x) > 12 || Math.abs(point.clientY - touch.y) > 12) touch = null;
            break;
          }
        }, { capture: true, passive: true });
        document.addEventListener('touchend', function(e) {
          const tap = touch;
          touch = null;
          if (!tap) return;
          let point = null;
          for (let i = 0; i < e.changedTouches.length; i++) {
            if (e.changedTouches[i].identifier === tap.id) { point = e.changedTouches[i]; break; }
          }
          if (!point || Math.abs(point.clientX - tap.x) > 12 || Math.abs(point.clientY - tap.y) > 12) return;
          const url = reelURLNearDMTarget(tap.target, point.clientX, point.clientY);
          if (!url) {
            if (isDMShareCardTap(tap.target)) {
              markDMReelPending('url-less-touch');
              const path = location.pathname;
              setTimeout(function() {
                if (location.pathname !== path || shouldLockScroll()) return;
                const current = document.elementFromPoint(point.clientX, point.clientY);
                if (!current || !current.click || current.closest('input, textarea, select, [contenteditable="true"]')) return;
                biLog('[dm] activating URL-less card after first touch target=' + current.tagName);
                current.click();
              }, 120);
              return;
            }
            if (misses < 3) {
              misses++;
              biLog('[dm] tap miss target=' + (tap.target.tagName || '?') +
                ' reelAnchors=' + document.querySelectorAll('a[href*="/reel/"], a[href*="/reels/"]').length);
            }
            return;
          }
          markDMReelPending('permalink-touch');
          e.preventDefault();
          e.stopImmediatePropagation();
          biLog('[dm] routing first touch to ' + url.href);
          window.location.assign(url.href);
        }, { capture: true, passive: false });
        document.addEventListener('touchcancel', function() { touch = null; }, { capture: true, passive: true });
        document.addEventListener('click', function(e) {
          if (!e.isTrusted || e.button !== 0 || e.metaKey || e.ctrlKey || e.shiftKey || e.altKey) return;
          const url = reelURLNearDMTarget(e.target, e.clientX, e.clientY);
          if (!url) return;
          markDMReelPending('permalink-click');
          e.preventDefault();
          e.stopImmediatePropagation();
          biLog('[dm] routing first click to ' + url.href);
          window.location.assign(url.href);
        }, true);
      }

      // Fullscreen only has to be suppressed inside the locked reel
      // presentation (R2): the system player is its own scroll surface, so
      // handing a locked reel to it would restore swipe-to-next outside the
      // DOM lock. Everywhere else — stories, feed video, a post's own player —
      // fullscreen is legitimate and must keep working. The prototype patches
      // still have to be installed once at document start (before Instagram
      // captures its own references), so they delegate to the originals and
      // only suppress while the lock is actually active.
      function preventNativeFullscreen() {
        if (window.__biFullscreenPatched) return;
        window.__biFullscreenPatched = true;

        function reelLocked() {
          try { return shouldLockScroll(); } catch (e) { return false; }
        }

        const mediaProto = window.HTMLMediaElement && HTMLMediaElement.prototype;
        if (mediaProto && mediaProto.webkitEnterFullscreen) {
          const origEnter = mediaProto.webkitEnterFullscreen;
          try {
            Object.defineProperty(mediaProto, 'webkitEnterFullscreen', {
              value: function() {
                if (reelLocked()) return;
                return origEnter.apply(this, arguments);
              },
              configurable: true
            });
          } catch (e) {}
        }
        ['requestFullscreen', 'webkitRequestFullscreen'].forEach(function(name) {
          [mediaProto, Element.prototype].forEach(function(proto) {
            if (!proto || !proto[name]) return;
            const orig = proto[name];
            try {
              Object.defineProperty(proto, name, {
                value: function() {
                  if (reelLocked()) return Promise.resolve();
                  return orig.apply(this, arguments);
                },
                configurable: true
              });
            } catch (e) {}
          });
        });

        document.addEventListener('webkitbeginfullscreen', function(e) {
          if (!reelLocked()) return;
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
        hideNonAccountSearchResults();
      }

      // R3 backstop only - NOT the primary mechanism. filterSearchPayload()
      // (see the "search result filtering" section above) strips non-account
      // results at the data layer before Instagram renders them; this DOM
      // pass exists only to catch a response shape that intercept didn't
      // recognize. Hides post/hashtag/place result links and any lingering
      // "Tags"/"Places"/"Top" result-type tab controls without touching the
      // search input or account rows.
      function hideNonAccountSearchResults() {
        scanRoot().querySelectorAll(
          'a[href^="/p/"], a[href^="/reel/"], a[href^="/reels/"], ' +
          'a[href^="/explore/tags/"], a[href^="/explore/locations/"]'
        ).forEach(function(a) {
          hide(clickableFor(a) || a);
        });
        ['Tags', 'Places', 'Top'].forEach(function(label) {
          scanRoot().querySelectorAll('span, div, button, a').forEach(function(el) {
            if (el.children.length !== 0) return;
            if ((el.textContent || '').trim() !== label) return;
            hide(clickableFor(el) || el);
          });
        });
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
        const dpr = window.devicePixelRatio || 2;
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
          fetch('/api/v1/oembed/?url=' + encodeURIComponent('https://www.instagram.com/p/' + code + '/') +
            '&maxwidth=1080', {
            headers: { 'X-IG-App-ID': '936619743392459' },
            credentials: 'include'
          }).then(function(r) { return r.ok ? r.json() : null; })
            .then(function(payload) {
              if (!payload || !payload.thumbnail_url) return;
              dmThumbCache[code] = payload.thumbnail_url;
              img.src = payload.thumbnail_url;
              img.removeAttribute('srcset');
              img.removeAttribute('sizes');
              biLog('[dm] upgraded preview ' + code + ' oembedWH=' +
                (payload.thumbnail_width || '?') + 'x' + (payload.thumbnail_height || '?') +
                ' displayW=' + Math.round(bestWidth) + ' dpr=' + dpr);
            }).catch(function() {});
        });
      }

      // DM headers: Instagram lays a leading control (back button on a
      // thread; nothing on the inbox) and a trailing icon cluster (call/
      // video/info on a thread; the compose/edit icon on the inbox) out with
      // flex space-between, so an unequal-width side visibly drags the
      // title off center. Absolutely center the title instead of fighting
      // the flex math (same technique as the home logo below). One shared
      // helper does the actual centering once a title element is found.
      function centerDMHeaderTitle(title) {
        if (!title) return;
        let header = title.parentElement;
        let depth = 0;
        while (header && header !== document.body && depth < 10) {
          const r = header.getBoundingClientRect();
          if (r.width >= window.innerWidth * 0.9 && r.height > 0 && r.height < 120) break;
          header = header.parentElement;
          depth++;
        }
        if (!header || header === document.body) return;
        if (getComputedStyle(header).position === 'static') header.style.position = 'relative';
        title.dataset.biDmCentered = '1';
        title.style.position = 'absolute';
        title.style.left = '50%';
        title.style.top = '50%';
        title.style.transform = 'translate(-50%, -50%)';
        title.style.zIndex = '2';
        title.style.pointerEvents = 'auto';
        title.style.maxWidth = '55%';
        title.style.textAlign = 'center';
      }

      // Thread route (/direct/t/<id>/): the name/avatar control is the
      // header's own clickable child with real text that isn't the back
      // button and isn't an icon-only control (call/video/info have an svg
      // and no text). Left tappable — unlike the decorative home logo, this
      // opens thread details.
      function fixDMThreadHeader() {
        const back = document.querySelector('svg[aria-label="Back"]');
        if (!back) return;
        const header = back.closest('header') || (function() {
          let node = back.parentElement, depth = 0;
          while (node && node !== document.body && depth < 12) {
            const r = node.getBoundingClientRect();
            if (r.width >= window.innerWidth * 0.9 && r.height > 0 && r.height < 120 &&
                !node.querySelector('article')) return node;
            node = node.parentElement;
            depth++;
          }
          return null;
        })();
        if (!header) return;
        const backControl = clickableFor(back) || back.parentElement;
        let title = null;
        const controls = header.querySelectorAll(':scope > *, :scope > * > *');
        for (let i = 0; i < controls.length; i++) {
          const el = controls[i];
          if (el === backControl || (backControl && backControl.contains(el))) continue;
          if (el.contains(back)) continue;
          const text = (el.textContent || '').trim();
          if (!text) continue;
          if (el.querySelectorAll('svg').length > 1) continue;
          if (!title || text.length > (title.textContent || '').trim().length) title = el;
        }
        centerDMHeaderTitle(title);
      }

      // Inbox route (/direct/ or /direct/inbox/): the title is the signed-in
      // username (Instagram's own account-switcher control, no href). There is
      // no reliable anchor icon here (no back button), so find it by matching
      // text against the username we already resolved from the nav row
      // (window.__biLastProfileHref, set independently per-webview by
      // reportProfile() — each tab has its own JS realm). Cached after the
      // first hit so this doesn't re-scan the document every apply() pass.
      let dmInboxTitleEl = null;
      function logDMHeaderScan(username, selected) {
        if ((window.__biDMHeaderScanCount || 0) >= 5) return;
        const candidates = [];
        document.querySelectorAll('span, div, button, a').forEach(function(el) {
          if (candidates.length >= 8) return;
          const text = (el.textContent || '').trim().replace(/\\s+/g, ' ');
          if (!text || text.length > 60) return;
          const r = el.getBoundingClientRect();
          if (r.top < 0 || r.top > 110 || r.width <= 0 || r.height <= 0) return;
          candidates.push({ tag: el.tagName, role: el.getAttribute('role') || '',
            textLength: text.length, ownUsernameMatch: !!username && text.toLowerCase() === username,
            rect: [Math.round(r.left), Math.round(r.top), Math.round(r.width), Math.round(r.height)],
            ancestry: shortAncestry(el, 4) });
        });
        const signature = username + '|' + JSON.stringify(candidates) + '|' + !!selected;
        if (window.__biLastDMHeaderScan === signature) return;
        window.__biLastDMHeaderScan = signature;
        window.__biDMHeaderScanCount = (window.__biDMHeaderScanCount || 0) + 1;
        biLog('[dm-header] profileHref=' + (window.__biLastProfileHref || '') + ' route=' + location.pathname +
          ' selected=' + !!selected + ' candidates=' + JSON.stringify(candidates));
      }

      function fixDMInboxHeader() {
        const username = (window.__biLastProfileHref || '').replace(/\\//g, '').toLowerCase();
        if (dmInboxTitleEl && dmInboxTitleEl.isConnected) {
          centerDMHeaderTitle(dmInboxTitleEl);
          logDMHeaderScan(username, dmInboxTitleEl);
          return;
        }
        if (!username) { logDMHeaderScan('', null); return; }
        let title = null;
        const candidates = document.querySelectorAll('span, div, button, a');
        for (let i = 0; i < candidates.length; i++) {
          const el = candidates[i];
          if (el.children.length > 0) continue;
          if ((el.textContent || '').trim().toLowerCase() !== username) continue;
          const r = el.getBoundingClientRect();
          if (r.top < 0 || r.top > 100) continue;
          title = clickableFor(el) || el;
          break;
        }
        if (!title) { logDMHeaderScan(username, null); return; }
        dmInboxTitleEl = title;
        centerDMHeaderTitle(title);
        logDMHeaderScan(username, title);
        if (!window.__biDMHeaderFixLogged) {
          window.__biDMHeaderFixLogged = true;
          biLog('[header] dm inbox title centered');
        }
      }

      function fixDMHeader() {
        if (!isTopFrame) return;
        if (/^\\/direct\\/t\\//.test(location.pathname)) { fixDMThreadHeader(); return; }
        if (/^\\/direct\\/(inbox\\/?)?$/.test(location.pathname)) { fixDMInboxHeader(); }
      }

      // DM threads use an inner scroller around a fixed composer. Keep the
      // existing conservative padding backstop, but reassert it after React
      // restyles the node and capture enough geometry to identify the actual
      // scroller on-device.
      let dmScrollFixContainer = null;
      function fixDirectThreadScroll() {
        if (!isTopFrame || !/^\\/direct\\/t\\//.test(location.pathname)) return;
        const cachedContainer = dmScrollFixContainer && dmScrollFixContainer.isConnected ? dmScrollFixContainer : null;
        let container = cachedContainer;
        let maxOverflow = 0;
        const plausible = [];
        const captureScrollGeometry = (window.__biDMScrollScanCount || 0) < 6;
        scanRoot().querySelectorAll('div').forEach(function(node) {
          if (node.clientHeight < 120) return;
          const cs = getComputedStyle(node);
          if (cs.overflowY !== 'auto' && cs.overflowY !== 'scroll') return;
          const overflow = node.scrollHeight - node.clientHeight;
          if (captureScrollGeometry && plausible.length < 8) {
            const r = node.getBoundingClientRect();
            plausible.push({ tag: node.tagName, overflow: cs.overflowY,
              rect: [Math.round(r.top), Math.round(r.bottom), Math.round(r.height)],
              top: Math.round(node.scrollTop), client: node.clientHeight, scroll: node.scrollHeight, max: overflow,
              ancestry: shortAncestry(node, 4) });
          }
          if (!cachedContainer && overflow > maxOverflow) { maxOverflow = overflow; container = node; }
        });
        if (!container) return;
        dmScrollFixContainer = container;
        container.style.paddingBottom = '28px';
        container.style.scrollPaddingBottom = '28px';
        container.style.overscrollBehaviorY = 'contain';
        if (!window.__biDMScrollFixLogged) {
          window.__biDMScrollFixLogged = true;
          biLog('[dm] extended thread scroll container');
        }
        if (!captureScrollGeometry) return;
        const composerControl = document.querySelector('textarea, input[placeholder], [contenteditable="true"]');
        const composer = composerControl && (clickableFor(composerControl) || composerControl.parentElement);
        const composerRect = composer ? composer.getBoundingClientRect() : null;
        const last = container.lastElementChild;
        const lastRect = last ? last.getBoundingClientRect() : null;
        const signature = Math.round(container.scrollTop / 50) + '|' + Math.round((container.scrollHeight - container.clientHeight) / 50) +
          '|' + (composerRect ? Math.round(composerRect.top) : '?') + '|' + (lastRect ? Math.round(lastRect.bottom) : '?');
        if (window.__biLastDMScrollScan !== signature && (window.__biDMScrollScanCount || 0) < 6) {
          window.__biLastDMScrollScan = signature;
          window.__biDMScrollScanCount = (window.__biDMScrollScanCount || 0) + 1;
          biLog('[dm-scroll] chosen=' + shortAncestry(container, 6) + ' top=' + Math.round(container.scrollTop) +
            ' max=' + Math.round(container.scrollHeight - container.clientHeight) +
            ' lastBottom=' + (lastRect ? Math.round(lastRect.bottom) : '?') +
            ' composerTop=' + (composerRect ? Math.round(composerRect.top) : '?') +
            ' viewport=' + window.innerHeight + ' ancestors=' + JSON.stringify(plausible));
        }
      }

      // Home header: center the Instagram logo and add a favorites star on
      // the left (plus/heart stay on the right where IG puts them). The star
      // opens the native favorites editor via the biFavEdit message.
      // The star control button must persist even on a pass where the
      // stricter header-geometry walk below fails to find a header (a
      // transient compact/sticky scroll variant, an in-flight animation,
      // or any other momentary layout state). Previously fixHomeHeader()
      // returned early before ever reaching the button-injection check when
      // that happened, so a header remount (React replacing the header
      // node, taking a previously-injected button with it) followed by one
      // failed geometry pass left the button gone until geometry happened
      // to match again — sometimes never, on that page view. Decoupling
      // button (re)attachment from that walk fixes the "preferences button
      // sometimes disappears" report (issue #4).
      function ensureStarButton(container) {
        if (!container) return;
        const existing = document.getElementById('__bi_star_btn');
        if (existing && container.contains(existing)) return;
        if (existing) existing.remove();
        const starButton = document.createElement('button');
        starButton.id = '__bi_star_btn';
        starButton.setAttribute('type', 'button');
        starButton.setAttribute('aria-label', 'Lillygram Controls');
        starButton.innerHTML = '<svg width="24" height="24" viewBox="0 0 24 24" fill="none" ' +
          'stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round">' +
          '<line x1="4" y1="21" x2="4" y2="14"></line>' +
          '<line x1="4" y1="10" x2="4" y2="3"></line>' +
          '<line x1="12" y1="21" x2="12" y2="12"></line>' +
          '<line x1="12" y1="8" x2="12" y2="3"></line>' +
          '<line x1="20" y1="21" x2="20" y2="16"></line>' +
          '<line x1="20" y1="12" x2="20" y2="3"></line>' +
          '<line x1="1" y1="14" x2="7" y2="14"></line>' +
          '<line x1="9" y1="8" x2="15" y2="8"></line>' +
          '<line x1="17" y1="16" x2="23" y2="16"></line></svg>';
        const logo = document.querySelector('svg[aria-label="Instagram"]');
        try { if (logo) starButton.style.color = getComputedStyle(logo).color || 'inherit'; } catch (e) {}
        starButton.addEventListener('click', function(e) {
          e.preventDefault();
          e.stopPropagation();
          if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.biFavEdit) {
            window.webkit.messageHandlers.biFavEdit.postMessage(true);
          }
        });
        container.appendChild(starButton);
        if (!window.__biHeaderFixLogged) {
          window.__biHeaderFixLogged = true;
          biLog('[header] control button injected');
        }
      }

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
        const validHeader = header && header !== document.body ? header : null;
        // Always try to (re)attach the star button to *some* reasonable
        // header container, even when the stricter geometry walk above
        // missed this pass — see ensureStarButton().
        ensureStarButton(validHeader || logo.closest('header') || logo.parentElement);
        if (!validHeader) return;
        header = validHeader;
        if (getComputedStyle(header).position === 'static') header.style.position = 'relative';

        // The logo lives inside a small clickable control. IG sometimes renders
        // a feed-switcher CARET either as a separate svg sibling next to the
        // logo's box, or nested inside the same box alongside the logo, and can
        // remount either one on scroll (a compact/sticky header variant) — all
        // observed live. A DOM-relationship heuristic ("the box's next sibling",
        // "svgs nested in the same box") breaks the instant that relationship
        // shifts, which is exactly what scrolling seems to trigger. Centering by
        // identity + hiding by GEOMETRY (anything small sitting near the header's
        // horizontal center, once the logo box is pinned there) is robust to
        // that: it doesn't matter how the caret nests or which pass remounted
        // it, only where it visually sits relative to the now-centered logo.
        const logoBox = logo.closest('a, [role="link"], [role="button"], button') || logo.parentElement;
        if (!logoBox.querySelector('article')) {
          logoBox.style.position = 'absolute';
          logoBox.style.left = '50%';
          logoBox.style.top = '50%';
          logoBox.style.transform = 'translate(-50%, -50%)';
          logoBox.style.zIndex = '2';
          // The header logo is decorative here — clicking it must do nothing
          // (no feed switcher, no scroll-to-top), so make it inert.
          logoBox.style.pointerEvents = 'none';
          // Forces a synchronous layout so the rect below reflects the
          // positioning just applied above, not last frame's stale layout.
          const headerRect = header.getBoundingClientRect();
          const centerX = headerRect.left + headerRect.width / 2;
          const nearby = [];
          header.querySelectorAll('svg').forEach(function(svg) {
            if (svg === logo || svg.id === '__bi_star_btn') return;
            if (svg.closest('#__bi_star_btn, article')) return;
            const r = svg.getBoundingClientRect();
            if (r.width === 0 || r.width >= 44) return;
            const cx = r.left + r.width / 2;
            if (Math.abs(cx - centerX) < 60) {
              nearby.push({ tag: svg.tagName, aria: svg.getAttribute('aria-label') || '',
                rect: [Math.round(r.left), Math.round(r.top), Math.round(r.width), Math.round(r.height)] });
              svg.style.display = 'none';
            }
          });
          if ((window.__biHeaderScanCount || 0) < 6) {
            const logoRect = logoBox.getBoundingClientRect();
            const scan = 'header=' + shortAncestry(header, 3) + '.' + String(header.className || '').slice(0, 80) +
              ' logo=' + shortAncestry(logoBox, 3) + '.' + String(logoBox.className || '').slice(0, 80) +
              ' logoRect=' + JSON.stringify([Math.round(logoRect.left), Math.round(logoRect.top),
                Math.round(logoRect.width), Math.round(logoRect.height)]) + ' nearby=' + JSON.stringify(nearby) +
              ' scroll=' + Math.round(window.scrollY);
            if (window.__biLastHeaderScan !== scan) {
              window.__biLastHeaderScan = scan;
              window.__biHeaderScanCount = (window.__biHeaderScanCount || 0) + 1;
              biLog('[header-scan] variant=' + (header.getAttribute('role') || header.tagName) + ' ' + scan);
            }
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

      function visibleCommentSheet() {
        function visible(el) {
          if (!el) return false;
          const rect = el.getBoundingClientRect();
          if (rect.width <= 0 || rect.height <= 0) return false;
          const computed = getComputedStyle(el);
          if (computed.display === 'none' || computed.visibility === 'hidden') return false;
          return rect.bottom > 0 && rect.top < window.innerHeight;
        }

        function commentInput(scope) {
          const inputs = scope.querySelectorAll(
            'textarea[placeholder*="comment" i], textarea[aria-label*="comment" i], ' +
            'input[placeholder*="comment" i], input[aria-label*="comment" i]'
          );
          for (let i = 0; i < inputs.length; i++) {
            if (visible(inputs[i])) return inputs[i];
          }
          return null;
        }

        function commentsHeading(scope) {
          const labels = scope.querySelectorAll('h1, h2, h3, [role="heading"], span');
          for (let i = 0; i < labels.length; i++) {
            if ((labels[i].textContent || '').trim().toLowerCase() === 'comments' && visible(labels[i])) {
              return labels[i];
            }
          }
          return null;
        }

        const dialogs = document.querySelectorAll('[role="dialog"]');
        for (let i = 0; i < dialogs.length; i++) {
          const dialog = dialogs[i];
          if (!visible(dialog)) continue;
          const signal = commentInput(dialog) || commentsHeading(dialog);
          if (signal) return { dialog: dialog, signal: signal, fullPage: false };
        }

        const input = commentInput(document);
        const heading = commentsHeading(document);
        if (input && heading && heading.getBoundingClientRect().top < Math.max(180, window.innerHeight * 0.25)) {
          return { dialog: document.body, signal: heading, fullPage: true };
        }
        return null;
      }

      function installCommentBackRouting() {
        if (window.__biCommentBackPatched) return;
        window.__biCommentBackPatched = true;
        document.addEventListener('click', function(e) {
          if (!window.__biCommentSheetOpen || !e.target.closest) return;
          const control = e.target.closest('a[href], [role="button"], button');
          if (!control) return;
          const back = e.target.closest('svg[aria-label="Back"]') || control.querySelector('svg[aria-label="Back"]');
          if (!back) return;
          e.preventDefault();
          biLog('[comments] back captured path=' + location.pathname +
            ' tag=' + control.tagName + ' href=' + (control.getAttribute('href') || 'none'));
        }, true);
      }

      let commentCloseTimer = null;
      function updateCommentSheet() {
        const active = visibleCommentSheet();
        if (active) {
          if (commentCloseTimer) {
            clearTimeout(commentCloseTimer);
            commentCloseTimer = null;
          }
          if (!window.__biCommentSheetOpen) {
            window.__biCommentSheetOpen = true;
            biLog('[comments] open=true path=' + location.pathname + ' history=' + history.length);
          }
          return;
        }
        if (!window.__biCommentSheetOpen || commentCloseTimer) return;
        commentCloseTimer = setTimeout(function() {
          commentCloseTimer = null;
          if (visibleCommentSheet()) return;
          window.__biCommentSheetOpen = false;
          biLog('[comments] open=false');
          beginFeedDiagnostic('comments-close');
          requestAnimationFrame(apply);
          reportNavVisibility();
        }, 250);
      }

      function computeNavVisible() {
        return !window.__biCommentSheetOpen && !/^\\/direct\\/t\\//.test(location.pathname) &&
          !isImmersiveSurface(shouldLockScroll());
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
        articles.forEach(function(a) {
          if (a.classList.contains('__bi_hidden') || a.classList.contains('__bi_fav_hidden')) hidden++;
        });
        const line = articles.length + ' articles, ' + hidden + ' hidden';
        if (window.__biFeedCensus !== line) {
          window.__biFeedCensus = line;
          biLog('[feed] ' + line);
        }
      }

      // ---- feed fail-safe watchdog -----------------------------------------
      // The one unrecoverable failure: the splice succeeds but IG's Relay hangs,
      // leaving a permanent spinner. Detect it and let native recover, so we
      // never brick on an eternal spinner. Conservative: only "stuck" if NO
      // favorite has rendered AND a loading spinner is still present, and only
      // armed once favorite edges have actually been delivered (so we never fire
      // during the normal waiting-for-edges spinner).

      function feedLooksStuck() {
        if (location.pathname !== '/') return false;
        const articles = scanRoot().querySelectorAll('article');
        for (let i = 0; i < articles.length; i++) {
          const a = articles[i];
          if (a.classList.contains('__bi_hidden') || a.classList.contains('__bi_fav_hidden')) continue;
          const author = articleAuthor(a);
          if (author && (favSet.has(author) || favAuthors.has(author))) return false;
        }
        // No favorite rendered — only "stuck" if a loading spinner is present.
        return !!document.querySelector('[role="progressbar"], [aria-label="Loading..."], svg[aria-label="Loading..."]');
      }

      function armFeedWatchdog() {
        if (!isTopFrame || window.__biWatchArmed) return;
        if (location.pathname !== '/' || !favoritesOn) return;
        if (!favEdges || !favEdges.length) return;
        window.__biWatchArmed = true;
        setTimeout(function() {
          try {
            if (!feedLooksStuck()) return;
            biLog('[watchdog] favorites feed stuck (no favorites rendered, spinner present)');
            if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.biFeedStuck) {
              window.webkit.messageHandlers.biFeedStuck.postMessage(true);
            }
          } catch (e) {}
        }, 9000);
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

      function colorComponents(bg) {
        if (!bg || bg === 'transparent') return null;
        const match = bg.match(/^rgba?\\(([^)]+)\\)$/);
        if (!match) return null;
        const parts = match[1].split(',').map(function(value) { return parseFloat(value); });
        if (parts.length < 3 || parts.some(function(value) { return isNaN(value); })) return null;
        return { r: parts[0], g: parts[1], b: parts[2], a: parts.length > 3 ? parts[3] : 1 };
      }

      function compositedPointBackground(x, y) {
        const stack = document.elementsFromPoint(x, y) || [];
        const layers = [];
        for (let i = 0; i < stack.length; i++) {
          const rect = stack[i].getBoundingClientRect();
          if (rect.width < window.innerWidth * 0.5) continue;
          const color = colorComponents(getComputedStyle(stack[i]).backgroundColor);
          if (!color || color.a <= 0) continue;
          layers.push(color);
          if (color.a >= 0.999) break;
        }
        if (!layers.length || layers[layers.length - 1].a < 0.999) return null;
        let result = layers[layers.length - 1];
        for (let i = layers.length - 2; i >= 0; i--) {
          const source = layers[i];
          result = {
            r: source.r * source.a + result.r * (1 - source.a),
            g: source.g * source.a + result.g * (1 - source.a),
            b: source.b * source.a + result.b * (1 - source.a),
            a: 1
          };
        }
        return 'rgb(' + Math.round(result.r) + ', ' + Math.round(result.g) + ', ' + Math.round(result.b) + ')';
      }

      function currentPageBackground() {
        if (!document.body || !document.documentElement) return null;
        const sampleXs = [0.2, 0.5, 0.8];
        const sampleYs = [8, 24, 44];
        const counts = {};
        let mostCommon = null;
        let mostCommonCount = 0;
        for (let yIndex = 0; yIndex < sampleYs.length; yIndex++) {
          for (let xIndex = 0; xIndex < sampleXs.length; xIndex++) {
            const x = Math.floor(window.innerWidth * sampleXs[xIndex]);
            const bg = compositedPointBackground(x, sampleYs[yIndex]);
            if (!bg) continue;
            counts[bg] = (counts[bg] || 0) + 1;
            if (counts[bg] > mostCommonCount) {
              mostCommon = bg;
              mostCommonCount = counts[bg];
            }
          }
        }
        if (mostCommon) return mostCommon;
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
        return null;
      }

      function defaultPageColor() {
        return (window.matchMedia && window.matchMedia('(prefers-color-scheme: dark)').matches)
          ? 'rgb(12, 16, 20)'
          : 'rgb(255, 255, 255)';
      }

      function reportBackgroundColor() {
        if (!isTopFrame) return;
        const bg = currentPageBackground() || defaultPageColor();
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

      // apply() runs a long chain of DOM-mutating passes (hide/lock/fix
      // functions) on essentially every DOM mutation (see the MutationObserver
      // below), which fires very often on a busy page like a DM thread
      // (message status ticks, avatar/story-ring loads, etc.). If one of those
      // passes mutates something mid-gesture — between touchstart and the
      // click a tap normally produces — the browser can lose the tap entirely
      // (a layout shift during an active touch reads as a scroll, not a tap),
      // which is the likely cause of share-card links needing a second tap to
      // register. Defer apply() until any in-flight touch has fully finished
      // (plus one short buffer for the resulting click to dispatch) instead
      // of running it mid-touch. Passive-only: this never calls
      // preventDefault, so it cannot itself block or alter a gesture.
      let touchActive = false;
      document.addEventListener('touchstart', function() {
        touchActive = true;
      }, { capture: true, passive: true });
      document.addEventListener('touchend', function() {
        setTimeout(function() { touchActive = false; }, 50);
      }, { capture: true, passive: true });
      document.addEventListener('touchcancel', function() {
        touchActive = false;
      }, { capture: true, passive: true });

      let applyScheduled = false;
      let lastApply = 0;
      let applyPerf = { count: 0, total: 0, max: 0, stages: {} };
      function clockNow() {
        return (window.performance && performance.now) ? performance.now() : Date.now();
      }
      function recordApplyTiming(total, timings) {
        applyPerf.count++;
        applyPerf.total += total;
        applyPerf.max = Math.max(applyPerf.max, total);
        timings.forEach(function(item) {
          const value = applyPerf.stages[item.name] || { total: 0, max: 0 };
          value.total += item.duration;
          value.max = Math.max(value.max, item.duration);
          applyPerf.stages[item.name] = value;
        });
        if (applyPerf.count < 20) return;
        if ((window.__biApplyPerfReports || 0) < 6) {
          window.__biApplyPerfReports = (window.__biApplyPerfReports || 0) + 1;
          const slowest = Object.keys(applyPerf.stages).map(function(name) {
            return { name: name, total: applyPerf.stages[name].total, max: applyPerf.stages[name].max };
          }).sort(function(a, b) { return b.total - a.total; }).slice(0, 5).map(function(item) {
            return item.name + ':' + item.total.toFixed(1) + '/' + item.max.toFixed(1);
          });
          biLog('[apply-perf] count=' + applyPerf.count + ' total=' + applyPerf.total.toFixed(1) +
            ' max=' + applyPerf.max.toFixed(1) + ' stages=' + slowest.join(','));
        }
        applyPerf = { count: 0, total: 0, max: 0, stages: {} };
      }

      function apply() {
        applyScheduled = false;
        lastApply = Date.now();
        let stage = 'setup';
        const started = clockNow();
        const timings = [];
        const measureApply = (window.__biApplyPerfReports || 0) < 6;
        function run(name, fn) {
          stage = name;
          if (!measureApply) { fn(); return; }
          const before = clockNow();
          fn();
          timings.push({ name: name, duration: clockNow() - before });
        }
        try {
          run('style', ensureStyleInjected);
          const path = location.pathname;
          const isHome = path === '/';
          const isDirect = /^\\/direct\\//.test(path);
          const isSearch = path.indexOf('/explore/search') === 0;

          run('hide-sponsored-reels', hideSponsoredAndReels);
          run('hide-feed-noise', hideFeedNoise);
          run('lock-primary-reel', lockToPrimaryReel);
          run('update-scroll-lock', updateScrollLock);
          run('plays-inline', forcePlaysInline);
          run('dismiss-app-nag', dismissAppNag);
          run('hide-original-nav', hideOriginalNav);
          if (!isHome) run('hide-bottom-bars', hideBottomBars);
          if (isSearch) run('search', fixSearchPage);
          // Resolve own-profile identity before the inbox header needs it, so
          // the first Direct apply can center the title instead of waiting for
          // an unrelated later mutation.
          run('report-profile', reportProfile);
          if (isDirect) {
            run('direct-inbox', fixDirectInbox);
            run('dm-header', fixDMHeader);
            run('dm-scroll', fixDirectThreadScroll);
            run('dm-media-quality', fixDirectMediaQuality);
            run('dm-preview-upgrade', upgradeDirectPreviews);
            run('dm-card-cursor', fixDMShareCardCursor);
          }
          if (isHome) {
            run('home-header', fixHomeHeader);
            run('home-nav-space', removeReservedNavSpace);
          }
          run('comments', updateCommentSheet);
          run('report-nav', reportNavVisibility);
          run('report-avatar', reportAvatar);
          run('report-feed', reportFeedHealth);
          run('feed-watchdog', armFeedWatchdog);
          run('report-background', reportBackgroundColor);
          if (measureApply) recordApplyTiming(clockNow() - started, timings);
        } catch (e) {
          biLog('[apply-error] stage=' + stage + ' path=' + diagnosticPath(location.pathname) + ' doc=' + documentID +
            ' error=' + (e && e.message ? e.message : e));
        } finally {
          // Marks this document as having run its own DOM-filter pass at
          // least once (style injected, header restyled) — see
          // maybePostFavReady(). Set even if a stage above threw, since the
          // earlier stages (style, header) already ran by then and waiting
          // forever for a clean pass would just re-cover a working page.
          if (!window.__biFirstApplyDone) {
            window.__biFirstApplyDone = true;
            maybePostFavReady();
          }
        }
      }

      function scheduleApply() {
        if (applyScheduled) return;
        applyScheduled = true;
        const wait = Math.max(0, 300 - (Date.now() - lastApply));
        function fire() {
          if (touchActive) { setTimeout(fire, 50); return; }
          requestAnimationFrame(apply);
        }
        setTimeout(fire, wait);
      }

      postLog('[boot] filter running on ' + diagnosticPath(location.pathname) + ' id=' + documentID +
        ' frame=' + (isTopFrame ? 'top' : 'sub') + ' origin=' + location.origin);
      if (isTopFrame && !window.__biLifecycleHooked) {
        window.__biLifecycleHooked = true;
        window.addEventListener('pageshow', function(e) {
          biLog('[lifecycle] pageshow persisted=' + !!e.persisted + ' doc=' + documentID +
            ' path=' + diagnosticPath(location.pathname));
        });
        window.addEventListener('pagehide', function(e) {
          biLog('[lifecycle] pagehide persisted=' + !!e.persisted + ' doc=' + documentID +
            ' path=' + diagnosticPath(location.pathname));
        });
        document.addEventListener('visibilitychange', function() {
          biLog('[lifecycle] visibility=' + document.visibilityState + ' doc=' + documentID +
            ' path=' + diagnosticPath(location.pathname));
        });
      }
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
      installDMReelClickRouting();
      installCommentBackRouting();
      preventNativeFullscreen();
      guardLocation();
      postPresentation(false, isImmersiveSurface(false), 'boot');
      window.__biReapply = scheduleApply;
      window.__biSetFavorites = setFavorites;
      setFavorites(window.__biFavorites, window.__biFavoritesEnabled);

      function classTokens(value, markersOnly) {
        return (value || '').split(/\\s+/).filter(function(token) {
          if (!token) return false;
          return markersOnly ? token.indexOf('__bi_') === 0 : token.indexOf('__bi_') !== 0;
        }).sort();
      }

      function removedClassMarkers(m) {
        if (m.type !== 'attributes' || m.attributeName !== 'class') return [];
        const oldMarkers = classTokens(m.oldValue, true);
        const now = (m.target && m.target.getAttribute) ? m.target.getAttribute('class') : '';
        const current = new Set(classTokens(now, true));
        return oldMarkers.filter(function(token) { return !current.has(token); });
      }

      // Suppress only expected Lillygram marker additions. If React
      // removes one of our markers, that is a real visibility change and must
      // immediately refilter the article instead of waiting for another mutation.
      function selfClassChurn(m) {
        if (m.type !== 'attributes' || m.attributeName !== 'class') return false;
        if (removedClassMarkers(m).length) return false;
        const now = (m.target && m.target.getAttribute) ? m.target.getAttribute('class') : '';
        return classTokens(m.oldValue, false).join(' ') === classTokens(now, false).join(' ');
      }

      const observer = new MutationObserver(function(mutations) {
        let viewerSurfaceChanged = false;
        let realChange = false;
        for (let i = 0; i < mutations.length; i++) {
          const mutation = mutations[i];
          if (mutation.type === 'childList') {
            if ((mutation.addedNodes && mutation.addedNodes.length) ||
                (mutation.removedNodes && mutation.removedNodes.length)) realChange = true;
            noteFeedArticles(mutation.addedNodes, 'added');
            noteFeedArticles(mutation.removedNodes, 'removed');
          } else if (!selfClassChurn(mutation)) {
            const removedMarkers = removedClassMarkers(mutation);
            if (removedMarkers.length) {
              if (!feedDiagnostic && location.pathname === '/') beginFeedDiagnostic('marker-removal');
              if (feedDiagnostic) {
                feedDiagnostic.markerRemoved += removedMarkers.length;
                feedDiagnostic.reused++;
              }
              const article = mutation.target && mutation.target.closest ? mutation.target.closest('article') : null;
              if (article) filterArticle(article);
            }
            realChange = true;
          }
          if (mutations[i].type === 'attributes' && /^\\/(stories|reels?)\\//.test(location.pathname)) {
            viewerSurfaceChanged = true;
          }
          const removed = mutations[i].removedNodes;
          for (let j = 0; j < removed.length; j++) {
            const node = removed[j];
            if (!node || node.nodeType !== 1) continue;
            if (node.matches('video, img, canvas, [role="dialog"]') ||
                (node.querySelector && node.querySelector('video, img, canvas, [role="dialog"]'))) {
              viewerSurfaceChanged = true;
            }
          }
          const added = mutations[i].addedNodes;
          for (let j = 0; j < added.length; j++) {
            const node = added[j];
            if (!node || node.nodeType !== 1) continue;
            // Pending DM reel surfaces are hidden in this same mutation
            // microtask, before WebKit gets a chance to paint Instagram's slide.
            gatePendingDMReel(node);
            if (node.matches('video, img, canvas, [role="dialog"]') ||
                (node.querySelector && node.querySelector('video, img, canvas, [role="dialog"]'))) {
              viewerSurfaceChanged = true;
            }
            if (node.tagName === 'ARTICLE') {
              filterArticle(node);
            } else if (node.querySelectorAll) {
              const articles = node.querySelectorAll('article');
              for (let k = 0; k < articles.length; k++) filterArticle(articles[k]);
            }
          }
        }
        if (viewerSurfaceChanged &&
            (/^\\/(direct|stories|reels?)\\//.test(location.pathname) || activeStorySurface || activeReelSurface)) {
          requestAnimationFrame(function() {
            updateScrollLock();
            reportBackgroundColor();
          });
          setTimeout(function() {
            updateScrollLock();
            reportBackgroundColor();
          }, 50);
        }
        if (realChange) scheduleApply();
      });

      function start() {
        if (document.body) {
          observer.observe(document.body, {
            childList: true,
            subtree: true,
            attributes: true,
            attributeOldValue: true,
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
    // Known ids of authors already present in the streamed edges — used ONLY
    // as a lookup shortcut below (skip re-fetching an id we already have).
    // This must NOT by itself make someone a density-fetch target: the
    // streamed favorites feed can still legitimately contain an account
    // that's no longer one of the app's current picks (e.g. real Instagram
    // Favorites the app hasn't been able to unfavorite yet), and topping
    // that account up with MORE profile posts would be compounding exactly
    // the wrong thing. Density targets are strictly `usernames` (the app's
    // current picks) below.
    const edgeIds = {};
    edges.forEach(function(e) {
      try {
        const m = e.node.media;
        const id = m.pk || m.id || m.code;
        if (id != null) seen.add(String(id));
        const u = m.user;
        if (u && u.username && (u.pk || u.id)) {
          edgeIds[String(u.username).toLowerCase()] = String(u.pk || u.id);
        }
      } catch (err) {}
    });
    const ids = {};
    for (const name of (usernames || [])) {
      const key = String(name).toLowerCase();
      if (edgeIds[key]) { ids[key] = edgeIds[key]; continue; }
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
        // The per-profile media endpoint doesn't return friendship_status
        // nested under item.user, so the fill-in above would leave it null
        // there — which is why the star badge was missing on these appended
        // posts (Instagram's own star render reads media.user.friendship_status,
        // NOT a media-level field). We already know this author is a current
        // favorite pick (that's the only reason we fetched their profile), so
        // set it directly at the correct nesting level instead of leaving it
        // null.
        if (item.user) {
          if (!item.user.friendship_status) {
            item.user.friendship_status = { following: true, is_feed_favorite: true };
          } else if (item.user.friendship_status.is_feed_favorite == null) {
            item.user.friendship_status.is_feed_favorite = true;
          }
        }
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
}
