#!/bin/sh
# Static checks for the documentation site. Run it from anywhere:
#
#   docs/verify.sh
#
# Page checks, for every .md page under docs/:
#   1. the page is listed in docs/_data/nav.yml, and every nav path exists;
#   2. the first line is a "# Title" heading;
#   3. it contains no Liquid markers ("{{" or "{%"), which Jekyll would try to evaluate;
#   4. every relative link to a .md file resolves to a file, and a "#fragment" on it matches a heading
#      in the target (using kramdown's id rule);
#   5. it contains none of the forbidden terms below (secrets, internal names, predecessor
#      implementations);
#   6. every "```" fence is closed.
# Site checks: the layout and stylesheet exist, _config.yml has no theme dependency and sets the default
# layout, the layout and includes use only Liquid tags and filters that GitHub Pages' Jekyll accepts
# (no render, liquid, include_relative; filters from an allow-list), and every href/src in them goes
# through relative_url. The landing page ../index.html must link to docs/.
#
# It does not fetch external URLs. To check the rendered site, build it with Jekyll (see docs/README.md).
#
# POSIX sh; needs only grep, find, sed, tr and awk.

set -u

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/.." && pwd)
cd "$root" || exit 2

failures=0
fail() {
  printf 'FAIL: %s\n' "$1" >&2
  failures=$((failures + 1))
}

pages=$(find docs -type f -name '*.md' ! -name 'README.md' | sort)
if [ -z "$pages" ]; then
  fail "no pages found under docs/"
fi

# kramdown's automatic heading id: drop leading non-letters, drop everything except letters, digits,
# spaces and hyphens, turn spaces into hyphens, lower-case. Backticks and emphasis markers vanish.
slug() {
  printf '%s' "$1" | sed -E 's/[`*]//g; s/^[^A-Za-z]+//; s/[^A-Za-z0-9 -]//g; s/ /-/g' | tr 'A-Z' 'a-z'
}

headings_of() {
  # Prints the slug of every heading in file $1, outside code fences.
  awk '/^```/ { f = !f; next } !f && /^#{1,6} / { sub(/^#+ +/, ""); print }' "$1" | while IFS= read -r h; do
    slug "$h"
    printf '\n'
  done
}

forbidden='TangentSource|flow-catalyst|-----BEGIN|AKIA[0-9A-Z]{16}|quarkus|predecessor|javalin|\.internal[:/ ]|belac\.io|aws_secret|xox[bp]-'

checked_pages=0
checked_links=0

for page in $pages; do
  checked_pages=$((checked_pages + 1))

  first=$(head -n 1 "$page")
  case $first in
    '# '*) ;;
    *) fail "$page: the first line must be a '# Title' heading" ;;
  esac

  if grep -nE '\{\{|\{%' "$page" >/dev/null 2>&1; then
    fail "$page: contains '{{' or '{%', which Jekyll treats as Liquid; reword it"
  fi

  if grep -nEi "$forbidden" "$page" >/dev/null 2>&1; then
    fail "$page: contains a forbidden term ($(grep -noEi "$forbidden" "$page" | head -n 1))"
  fi

  fences=$(grep -c '^```' "$page" || true)
  if [ $((fences % 2)) -ne 0 ]; then
    fail "$page: an unclosed code fence"
  fi

  dir=$(dirname "$page")
  links=$(grep -oE '\]\([^)[:space:]]+\.md(#[^)]*)?\)' "$page" 2>/dev/null | sed -E 's/^\]\(//; s/\)$//' | sort -u)
  for link in $links; do
    case $link in
      http://* | https://* | mailto:*) continue ;;
    esac
    checked_links=$((checked_links + 1))
    file=${link%%#*}
    frag=
    case $link in *'#'*) frag=${link#*#} ;; esac
    if [ ! -f "$dir/$file" ]; then
      fail "$page: link to '$file' does not resolve to a file"
      continue
    fi
    if [ -n "$frag" ] && ! headings_of "$dir/$file" | grep -qxF "$frag"; then
      fail "$page: link '$link' names a heading that does not exist in $file"
    fi
  done
  # Same-page fragments: ](#heading)
  for frag in $(grep -oE '\]\(#[^)[:space:]]+\)' "$page" 2>/dev/null | sed -E 's/^\]\(#//; s/\)$//' | sort -u); do
    checked_links=$((checked_links + 1))
    if ! headings_of "$page" | grep -qxF "$frag"; then
      fail "$page: link '#$frag' names a heading that does not exist on the page"
    fi
  done
done

# ---------------------------------------------------------------- navigation
nav=docs/_data/nav.yml
if [ ! -f "$nav" ]; then
  fail "$nav is missing (the sidebar, previous/next and titles come from it)"
else
  nav_paths=$(grep -v '^[[:space:]]*#' "$nav" | grep -oE 'path:[[:space:]]*[^ ,}]+' | sed -E 's/^path:[[:space:]]*//')
  for p in $nav_paths; do
    if [ ! -f "docs/$p" ]; then
      fail "$nav: path '$p' does not exist under docs/"
    fi
  done
  dups=$(printf '%s\n' "$nav_paths" | sort | uniq -d)
  if [ -n "$dups" ]; then
    fail "$nav: listed more than once: $dups"
  fi
  for page in $pages; do
    rel=${page#docs/}
    if ! printf '%s\n' "$nav_paths" | grep -qxF "$rel"; then
      fail "$page: not listed in $nav (add one line: - { title: ..., path: $rel })"
    fi
  done
fi

# ---------------------------------------------------------------- layout and config
for f in docs/_layouts/default.html docs/assets/css/docs.css docs/_config.yml; do
  [ -f "$f" ] || fail "$f is missing"
done
if grep -qE '^[[:space:]]*(theme|remote_theme):' docs/_config.yml 2>/dev/null; then
  fail "docs/_config.yml names a theme; the custom layout replaces it"
fi
if ! grep -qE 'layout:[[:space:]]*default' docs/_config.yml 2>/dev/null; then
  fail "docs/_config.yml: defaults must set 'layout: default' for all pages"
fi

tpl_files=$(find docs/_layouts docs/_includes -type f -name '*.html' 2>/dev/null | sort)
allowed_tags=" assign capture endcapture comment endcomment for endfor if elsif else endif unless endunless include break continue case when endcase raw endraw "
allowed_filters=" relative_url absolute_url append prepend replace escape default strip_html strip split first last slice size join downcase upcase date date_to_xml where sort uniq truncate jsonify markdownify slugify "
for f in $tpl_files; do
  for tag in $(grep -oE '\{%-?[[:space:]]*[a-z_]+' "$f" | sed -E 's/^\{%-?[[:space:]]*//' | sort -u); do
    case "$allowed_tags" in
      *" $tag "*) ;;
      *) fail "$f: Liquid tag '$tag' is not in the GitHub Pages-safe list (render/liquid/include_relative are not supported)" ;;
    esac
  done
  for filt in $(grep -oE '\{[{%][^}]*[}%]\}' "$f" | grep -oE '[^|]\|[[:space:]]*[a-z_]+' | sed -E 's/^.\|[[:space:]]*//' | sort -u); do
    case "$allowed_filters" in
      *" $filt "*) ;;
      *) fail "$f: Liquid filter '$filt' is not in the allow-list in verify.sh (check Jekyll 3.x supports it, then add it)" ;;
    esac
  done
  if grep -nE "href=\"/|src=\"/" "$f" | grep -v relative_url >/dev/null 2>&1; then
    fail "$f: absolute-path href/src without relative_url (breaks when the site is served under a base path)"
  fi
done

# ---------------------------------------------------------------- landing page
if [ -f index.html ]; then
  if ! grep -q 'href="docs/"' index.html; then
    fail "index.html: no link to docs/ (the landing page nav needs a Docs link)"
  fi
  if grep -q 'TangentSource' index.html; then
    fail "index.html: still links to the old TangentSource repository name"
  fi
fi

if [ "$failures" -gt 0 ]; then
  printf '\n%s problem(s) found.\n' "$failures" >&2
  exit 1
fi

printf 'OK: %s pages, %s internal links checked, nav.yml covers every page\n' "$checked_pages" "$checked_links"
