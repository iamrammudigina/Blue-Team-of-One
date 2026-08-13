# Blue Team of One — a security field-notes blog

A plain static website. **No build step, no framework, nothing to break.**
Every page is a standalone HTML file served directly by Cloudflare Pages.

Live at **rammudigina.dev**. Publishing is automatic: commit to this repo and
Cloudflare rebuilds the site in ~30 seconds. No zips, no manual uploads.

## Structure: Vertical → Section → Post

```
/index.html                     Home  — the four verticals as tiles (nothing else)
/{vertical}/index.html          Vertical page — its sections + post counts
/{vertical}/{section}.html      Section page — posts listed by date
/posts/*.html                   the actual articles
/posts/_template.html           copy this to start a new post
/about.html                     about page
/assets/style.css               one shared stylesheet
```

Verticals (each a folder):
```
/email/        delivery.html · inbound.html · outbound.html
/identity/     token-session.html · conditional-access.html · auth-mfa.html
/detection/    sentinel-rules.html · tuning-noise.html · correlation.html
/cloud-ir/     incident-response.html · endpoint.html · cloud-posture.html
```

- **Vertical** = top-level category (Email, Identity, Detection, Cloud/IR), with a
  top-nav entry and a tile on the home page.
- **Section** = a sub-topic inside a vertical (its own page, listing that section's posts).
- **Post** = one article in `/posts/`, listed on its section page.

All internal links are **root-relative** (`/identity/`, `/assets/style.css?v=N`),
so pages work the same at the domain root or in a subfolder.

---

## Publishing workflow

1. Add or edit files in this repo (upload via GitHub's web UI, or edit in place).
2. Commit.
3. Cloudflare Pages auto-publishes in ~30 seconds. Done.

Adding a post touches a few files, because the listing pages show counts:
- the new `posts/<name>.html` article, **and**
- its section page, the vertical `index.html`, and the home `index.html`
  (these show the post card / counts / badges).

The listing pages are generated from a single data model, so in practice the
post files are produced together and committed as a set. Each new post will come
with the exact list of files to commit.

## Cache-busting
The stylesheet is linked as `style.css?v=N`. When the CSS changes, bump `N`
across all pages so browsers load the new version instead of a cached copy.

---

## Reusable article blocks (styled in style.css)
- `<figure><svg …/><figcaption>…</figcaption></figure>` — a diagram
- `<pre class="code">…</pre>` — a dark code block (`<b>` highlights)
- `<table class="ref">` — a two-column reference table
- `<div class="smtp">` — a two-column dialog (sender / server)
- `<div class="analogy">` — a mental-model callout
- `<div class="mr">` + `.mr-card` — myth/reality pairs
- `<div class="caveat">` — an amber warning box
- `<div class="takeaway">` — the dark one-line summary
- `<div class="sources">` — a further-reading list
- `<h2 class="head"><span class="num">NN</span>Heading</h2>` — numbered section head

## Rename / re-theme
"Blue Team of One" appears in each page's masthead, `<title>`, and footer.
Swap the accent color via `--teal` in `assets/style.css`.

## Before publishing — sanitization checklist
Client-adjacent work must be generalized in every public post:
- [ ] No client / company names
- [ ] No real domains, tenant IDs, or subscription IDs
- [ ] No ticket numbers or incident IDs
- [ ] No user names or email addresses
- [ ] Numbers rounded or fictionalized; incidents described as archetypes
- [ ] Screenshots scrubbed of identifying UI
