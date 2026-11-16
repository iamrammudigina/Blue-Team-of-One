# Ground Truth — auto-build

Adding a post is now **one file**. Drop a new `.html` into `posts/` and commit it.
A GitHub Action rebuilds everything else — the section list, the counts, the home
"recent" list, and the search index — for you. No more editing listing pages, no zip.

## One-time setup (do this once)
1. Commit this whole folder to your repo (replace what's there).
2. In GitHub: **Settings → Actions → General → Workflow permissions →** choose
   **"Read and write permissions" → Save.** (This lets the Action commit the
   regenerated pages back.)

That's it. Cloudflare keeps deploying from the repo exactly as before.

## Adding a post from now on
1. In any chat, say "add a Ground Truth post" and paste your draft. You get back
   one `posts/<slug>.html` file (it already contains a small `gt-meta` block).
2. In GitHub, upload that one file into `posts/`. Done.
   Within a minute the Action lists it everywhere and Cloudflare redeploys.

Deleting a post works the same way — remove the file, everything updates.

## What makes it work
Each post carries a tiny block in its `<head>`:
```html
<script type="application/json" id="gt-meta">
{"vertical":"email","section":"outbound","fmtc":"deep","fmt":"Field case",
 "date":"2026-11-16","title":"Card/headline title","teaser":"One-line teaser for the cards.",
 "text":"keywords for search"}
</script>
```
`build.mjs` reads those blocks and regenerates the listings. `vertical`/`section`
are the folder + section-file names (e.g. `email` + `outbound` → `/email/outbound.html`).
Optional fields: `stitle` (shorter search title), `excerpt` (search blurb, defaults to the teaser).

## Run it yourself (optional)
You never need to, but `node build.mjs` from the repo root does exactly what the
Action does. Running it twice changes nothing (it's idempotent).

## Notes
- Empty sections and custom badges (e.g. "Series · 3 parts") are left untouched.
- `assets/search-extra.json` holds the one non-post search entry (the KQL Library
  page); leave it in place.
- Two posts on disk aren't listed anywhere yet (`dkim-per-sender-authentication`,
  `intune-privileged-access-evidence`) — add a `gt-meta` block to surface them.

## Alternative (no Action)
If you'd rather not use the Action: in Cloudflare Pages set **Build command:**
`node build.mjs` and **Build output directory:** `/`. Then Pages builds on every
deploy and nothing is committed back. Either way, same result.
