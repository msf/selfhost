# Blog Build System

Builds https://blog.mfilipe.eu/ from github.com/msf/msf.github.io.git.

## Structure

- `site/` — clone of msf.github.io (git source)
- `build.sh` — adds front matter to markdown, runs jekyll via docker
- `public/` — built static site (served by caddy @ blog.mfilipe.eu)

## Manual Build

```bash
cd /srv/selfhost/blog
bash build.sh
```

## How It Works

1. Pulls latest from `github.com/msf/msf.github.io`
2. Adds Jekyll front matter to `blogpost/*.md` and `papers/*.md`
3. Overrides `_config.yml` to use `minima` theme (local, no remote-theme plugin)
4. Runs `jekyll build` in docker, outputs to `public/`

## Caddy

`blog.mfilipe.eu` → `file_server` at `/srv/selfhost/blog/public/`

## Why Separate Cache Dir

The Jekyll docker container runs as root, which creates root-owned cache files.
By mounting a separate `$CACHE` dir for `.jekyll-cache`, we avoid permission
conflicts when re-running as non-root (bolotas).
