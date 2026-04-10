#!/bin/bash
# Build blog — add front matter to markdown files and run jekyll
set -euo pipefail

SITE=/srv/selfhost/blog/site
BUILD=/srv/selfhost/blog/build      # processed source with front matter
TMP=/srv/selfhost/blog/jekyll-tmp   # writable copy for jekyll source
CACHE=/srv/selfhost/blog/jekyll-cache  # jekyll cache (separate dir, owned by us)
PUBLIC=/srv/selfhost/blog/public

# sync from git
cd "$SITE" && git pull --quiet

rm -rf "$BUILD"
cp -r "$SITE" "$BUILD"

# add front matter to README.md → becomes index.md
cat > "$BUILD/index.md" << 'EOF'
---
layout: home
title: Miguel Filipe
---
EOF
cat "$SITE/README.md" >> "$BUILD/index.md"

# add front matter to blogposts + fix .md → .html internal links
for f in "$BUILD/blogpost"/*.md; do
  title=$(head -1 "$f" | sed 's/^# //')
  tmp=$(mktemp)
  printf -- "---\nlayout: post\ntitle: \"%s\"\n---\n" "$title" > "$tmp"
  sed 's/\(([^)]*\)\.md)/\1.html)/g' "$f" >> "$tmp"
  chmod 644 "$tmp"       # ensure readable by docker container (nobody)
  mv "$tmp" "$f"
done

# add front matter to papers
for f in "$BUILD/papers"/*.md; do
  title=$(head -1 "$f" | sed 's/^# //')
  tmp=$(mktemp)
  printf -- "---\nlayout: page\ntitle: \"%s\"\n---\n" "$title" > "$tmp"
  sed 's/\(([^)]*\)\.md)/\1.html)/g' "$f" >> "$tmp"
  chmod 644 "$tmp"       # ensure readable by docker container (nobody)
  mv "$tmp" "$f"
done

# config without remote theme
cat > "$BUILD/_config.yml" << 'EOF'
theme: minima
title: Miguel Filipe
twitter_username: m3thos
github_username: msf
linkedin_username: miguelmfilipe
EOF

# writable temp copy for jekyll source
rm -rf "$TMP"
cp -r "$BUILD" "$TMP"

# ensure cache dir exists and is ours (separate from jekyll-tmp, owned by us)
mkdir -p "$CACHE"

# build — isolated cache dir avoids stale root-owned docker cache
docker run --rm \
  -v "$TMP":/srv/jekyll \
  -v "$PUBLIC":/output \
  -v "$CACHE":/srv/jekyll/.jekyll-cache \
  jekyll/jekyll:latest \
  sh -c "cd /srv/jekyll && jekyll build -d /output" 2>&1 \
  | grep -v "^from\|^	from\|gems\|ruby\|mercenary\|load\|program\|main\|bin"

echo "Build done → $PUBLIC"
