# FlowCatalyst documentation site

Plain Jekyll for GitHub Pages: no Node, no theme gem. Pages are Markdown, the layout is in
`_layouts/`, the sidebar and previous/next links come from `_data/nav.yml`, and the one stylesheet is
`assets/css/docs.css` (the FlowCatalyst UI kit's design tokens, light and dark).

- Add a page: write the `.md` file, then add one line to `_data/nav.yml`.
- Check it: `docs/verify.sh` (nav coverage, links and heading anchors, forbidden terms, Liquid safety).
- Build it: `jekyll build -s docs -d _site/docs --baseurl /docs` with `jekyll-optional-front-matter` and
  `jekyll-relative-links` available (both are on the GitHub Pages allow-list). Serve `_site/` and
  copy `index.html` and `logopack/` beside `docs/` to see the landing page link up.
- Hosting is not decided: `url`, `baseurl` and `home_url` in `_config.yml` are placeholders.
- Facts in the pages were checked against the code in the platform repository, not copied from older
  documents. When behaviour changes, update the page in the same change.
