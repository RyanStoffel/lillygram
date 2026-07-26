# BetterInstagram — Documentation

This `docs/` folder is the **source of truth** for what BetterInstagram is, why
it exists, and how it is built.

> It supersedes `ios/README.md` and `ios/project.yml`, both of which are
> **stale** — they describe an old `fetch`-based favorites filter and an iOS 17
> target. The real code uses a hidden-harvest + XHR edge-splice, and the
> hand-edited `pbxproj` targets iOS 26.

## What BetterInstagram is

A SwiftUI iOS app that wraps the real `instagram.com` mobile site in persistent
`WKWebView`s using the user's own Instagram login, then injects userscript-style
JS/CSS to remove distracting surfaces. **The product goal is a
distraction-reduced Instagram that still feels like the native app — not feature
parity.** No private/native Instagram API is used; this is the same category of
technique as a browser content blocker or userscript.

This app is the realization of "Option C: separate reels-free client" from the
original planning docs (see _Historical_ below) — the official-app-modification
path was correctly found infeasible on non-jailbroken iOS.

## Read in this order

| Doc | What it covers |
| --- | --- |
| [product-requirements.md](product-requirements.md) | **The contract.** The 4 hard, non-negotiable requirements + acceptance criteria. Start here. |
| [architecture.md](architecture.md) | System design: files, the WKWebView layer, blocking layers, native↔web bridge. |
| [favorites-feed.md](favorites-feed.md) | Deep dive on the favorites-only feed — the most complex/fragile piece (and the current regression). |
| [blocking-and-selectors.md](blocking-and-selectors.md) | Reels/search blocking mechanics + a reference table of fragile Instagram selectors & GraphQL query names. |
| [performance-and-ux.md](performance-and-ux.md) | Requirement #4 turned into measurable standards + the techniques to hit them. |
| [known-issues.md](known-issues.md) | Regressions and open problems, led by the favorites-feed regression + fix plan. |
| [audit.md](audit.md) | Objective best-practice audit (scorecard + per-area verdicts) as of 2026. |
| [research-notes.md](research-notes.md) | External research on WKWebView wrappers, blocking, performance — with sources. |

## Ground rules for changes

- **Requirements in `product-requirements.md` are non-negotiable.** A change that
  violates one is a bug, not a trade-off.
- **The favorites splice is load-bearing and fragile.** Read `favorites-feed.md`
  before touching anything that produces or orders the spliced edges.
- **Keep these docs current.** Per the "Documentation" section in the repo-root
  `AGENTS.md`: whenever a change alters architecture, requirements, blocking
  approach, or perf standards, update the relevant doc in the same session.
  Keep docs lean; prune stale content.

## Historical (superseded)

Pre-pivot planning documents, kept for provenance. They predate the working
WKWebView client and their conclusions ("blocked", "not yet built") no longer
describe reality — treat them as history, not guidance:

- [01-product-scope.md](01-product-scope.md)
- [02-feasibility-analysis.md](02-feasibility-analysis.md)
- [03-technical-options.md](03-technical-options.md)
- [04-project-plan.md](04-project-plan.md)
- [05-branch-strategy.md](05-branch-strategy.md)
</content>
