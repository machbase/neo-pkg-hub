#!/usr/bin/env bash
set -euo pipefail

# Publishes packages.json in the versions[] schema (issue machbase/neo#1369).
#
# packages.json is a NON-DESTRUCTIVE version-history accumulator: each package keeps
# a `versions: [{version, minServer, released_at}]` list. This script reads the
# existing packages.json, refreshes repo metadata, and PREPENDS only newly-released
# versions — existing rows (and their hand-curated / previously auto-filled minServer
# values) are carried forward verbatim, so daily syncs never wipe minServer data.
#
# The top-level `version`/`released_at` mirror versions[0] (latest) for backward
# compatibility with clients that predate the versions[] schema.
#
# Two files are published, distinguished by the `experiment` gate (machbase/neo#1438):
#
#   packages.json      non-experiment packages ONLY  — the legacy view
#   packages-all.json  every package, each carrying its `experiment` flag
#
# Non-experiment packages therefore appear in BOTH files. That redundancy is the
# point, and it buys two things:
#
#  1. Legacy safety. A client renders whatever the file it fetches contains, so a
#     field it does not know about cannot hide anything — a single file with an
#     `experiment` flag is fail-OPEN for every neo-web build predating the feature.
#     Old builds only ever fetch packages.json, so leaving the entry out of that
#     file is the only mechanism that actually hides it.
#  2. Atomicity. Current neo-web reads packages-all.json and nothing else, so it
#     never has to reconcile two independently-cached responses. Splitting the data
#     across two files instead (stable here, experiment there) would let a package
#     in transition appear in both or neither for up to the 5 minute
#     raw.githubusercontent max-age, showing a duplicate card or none at all.
#
# Both files are ALWAYS written, empty ones as `[]` — neo-web treats a non-ok fetch
# as an error, so a missing file would break the whole catalog.

PACKAGES_YAML="${PACKAGES_YAML:-packages.yaml}"
OUTPUT_JSON="${OUTPUT_JSON:-packages.json}"
ALL_JSON="${ALL_JSON:-packages-all.json}"
GH_API="${GH_API:-https://api.github.com}"

AUTH_HEADER=()
if [[ -n "${GITHUB_TOKEN:-}" ]]; then
  AUTH_HEADER=(-H "Authorization: Bearer ${GITHUB_TOKEN}")
fi

# Returns the HTTP status of an authenticated Contents API probe, retrying while
# the answer is neither 200 nor 404. Probing raw.githubusercontent.com instead
# would be anonymous and IP-rate-limited: a 429 there is indistinguishable from a
# 404 under `curl -f`, which is how a throttled run once blanked every icon.
probe_status() {
  local url="$1" code attempt
  for attempt in 1 2 3; do
    code=$(curl -sSL -o /dev/null -w '%{http_code}' "${AUTH_HEADER[@]}" \
      -H "Accept: application/vnd.github+json" "$url" || echo 000)
    case "$code" in
      200|404) break ;;
    esac
    if [[ $attempt -lt 3 ]]; then sleep $((attempt * 2)); fi
  done
  echo "$code"
}

# Fetches a JSON document, retrying transient failures. Echoes the body on success
# and NOTHING on failure, always returning 0 — a non-zero return here would be fatal
# under `set -e`, which is exactly the blast radius this exists to remove: one
# unreadable repository used to abort the run and stop publication for every other
# package. Callers decide what an empty body means.
fetch_json() {
  local url="$1" body attempt
  for attempt in 1 2 3; do
    if body=$(curl -fsSL "${AUTH_HEADER[@]}" \
      -H "Accept: application/vnd.github+json" "$url"); then
      echo "$body"
      return 0
    fi
    if [[ $attempt -lt 3 ]]; then sleep $((attempt * 2)); fi
  done
  return 0
}

# Existing accumulator (empty array on first run). packages-all.json is the superset
# and is read first so its rows win the `.[0]` lookups below; packages.json is read
# as a fallback so the very first run after this split still inherits the version
# history that only exists in the legacy file. A package flipping `experiment` keeps
# its versions[] and icon either way — it is the same accumulator on both sides.
existing="[]"
for prev_file in "$ALL_JSON" "$OUTPUT_JSON"; do
  [[ -f "$prev_file" ]] || continue
  existing=$(echo "$existing" | jq --slurpfile prev "$prev_file" '. + ($prev[0] // [])')
done

count=$(yq '.packages | length' "$PACKAGES_YAML")
results="[]"
all_results="[]"
# Packages whose repository could not be read this run. Non-empty ⇒ exit 2 at the
# end, which the workflow turns into a red job AFTER publishing (see sync.yml).
skipped=()

for ((i=0; i<count; i++)); do
  name=$(yq -r ".packages[$i].name" "$PACKAGES_YAML")
  org=$(yq -r ".packages[$i].organization" "$PACKAGES_YAML")
  repo=$(yq -r ".packages[$i].repo" "$PACKAGES_YAML")
  icon_override=$(yq -r ".packages[$i].icon // \"\"" "$PACKAGES_YAML")
  docs_path=$(yq -r ".packages[$i].docs // \"\"" "$PACKAGES_YAML")
  # Catalog visibility gate (issue machbase/neo#1438). Package-scoped, not per
  # version — the version axis is versions[].minServer. packages.yaml is the ONLY
  # source of truth: this file is regenerated wholesale below, so a hand-edit in
  # packages.json is silently dropped on the next sync. Value validity is enforced
  # in CI before this script runs; the guard here only keeps a non-boolean from
  # ever reaching `--argjson`.
  experiment=$(yq -r ".packages[$i].experiment // false" "$PACKAGES_YAML")
  [[ "$experiment" == "true" ]] || experiment="false"

  echo "Syncing: $org/$repo (name: $name)"

  repo_json=$(fetch_json "$GH_API/repos/$org/$repo")

  # A repository that cannot be read — private now, deleted, renamed, or a GitHub
  # failure that outlived the retries — must not take the run down with it. Publish
  # the last known entry unchanged and move on.
  #
  # There is deliberately no attempt to tell those cases apart. A 404 (private /
  # gone) and a 5xx (GitHub is unwell) lead to the same action here, because the hub
  # NEVER removes an entry on its own: taking a package out of the catalog is an
  # explicit `packages.yaml` edit. That leaves nothing for a status-code check to
  # decide, and it is why no drop heuristic, streak counter, or separate history
  # store is needed to keep versions[] safe — the entry is simply never dropped.
  #
  # The cost is that a private package keeps a broken card (icon/docs/release assets
  # all 404) until someone edits the yaml. The `exit 2` below is what makes sure
  # someone does.
  if [[ -z "$repo_json" ]]; then
    skipped+=("$name")
    prev_entry=$(echo "$existing" | jq --arg name "$name" \
      '(map(select(.name == $name)) | .[0]) // null')

    if [[ "$prev_entry" == "null" ]]; then
      echo "  ! repo unreachable and never published — omitting $name from this run"
      continue
    fi

    # `experiment` is re-read from packages.yaml rather than inherited from the old
    # entry: the yaml stays the gate's source of truth even when the repo is dark,
    # so flipping the flag still takes effect on an unreachable package.
    prev_entry=$(echo "$prev_entry" | jq --argjson e "$experiment" '.experiment = $e')
    all_results=$(echo "$all_results" | jq --argjson e "$prev_entry" '. + [$e]')
    if [[ "$experiment" != "true" ]]; then
      results=$(echo "$results" | jq --argjson e "$prev_entry" '. + [$e]')
    fi
    echo "  = repo unreachable — carrying previous entry forward unchanged"
    continue
  fi

  default_branch=$(echo "$repo_json" | jq -r '.default_branch')
  full_name=$(echo "$repo_json" | jq -r '.full_name')

  release_json=$(curl -sSL "${AUTH_HEADER[@]}" \
    -H "Accept: application/vnd.github+json" \
    "$GH_API/repos/$org/$repo/releases/latest" || echo '{}')
  version=$(echo "$release_json" | jq -r '.tag_name // ""')
  released_at=$(echo "$release_json" | jq -r '.published_at // ""')

  prev_icon=$(echo "$existing" | jq -r --arg name "$name" \
    '(map(select(.name == $name)) | .[0].icon) // ""')

  if [[ -n "$icon_override" ]]; then
    icon_url="$icon_override"
  else
    icon_url=""
    icon_unknown="false"
    for ext in svg png; do
      code=$(probe_status "$GH_API/repos/$org/$repo/contents/icon.${ext}?ref=${default_branch}")
      if [[ "$code" == "200" ]]; then
        icon_url="https://raw.githubusercontent.com/${full_name}/${default_branch}/icon.${ext}"
        break
      fi
      if [[ "$code" != "404" ]]; then
        icon_unknown="true"
        echo "  ! icon.${ext} probe inconclusive (HTTP $code)"
      fi
    done

    # Only an authoritative 404 on every candidate may clear the icon. If any probe
    # was inconclusive the last known-good value wins, so a transient failure can
    # never regress a published icon.
    if [[ "$icon_unknown" == "true" && -n "$prev_icon" ]]; then
      icon_url="$prev_icon"
      echo "  = icon probe inconclusive, keeping previous: $icon_url"
    fi
  fi

  docs_url=""
  if [[ -n "$docs_path" ]]; then
    docs_rel="${docs_path#${repo}/}"
    docs_url="https://raw.githubusercontent.com/${full_name}/${default_branch}/${docs_rel}"
  fi

  homepage_url=$(echo "$repo_json" | jq -r '.homepage // ""')

  # ---- versions[] non-destructive merge --------------------------------------
  prev_versions=$(echo "$existing" | jq --arg name "$name" \
    '(map(select(.name == $name)) | .[0].versions) // []')

  present="false"
  if [[ -n "$version" ]]; then
    present=$(echo "$prev_versions" | jq --arg v "$version" 'any(.[]; .version == $v)')
  fi

  if [[ -n "$version" && "$present" != "true" ]]; then
    # New release: auto-fill minServer from package.json at the release TAG (not the
    # default branch). Missing/empty → left blank for manual backfill; the validator
    # flags it (gate 3a/3c).
    min_server=""
    pkg_meta=$(curl -fsSL "${AUTH_HEADER[@]}" \
      -H "Accept: application/vnd.github+json" \
      "$GH_API/repos/$org/$repo/contents/package.json?ref=$version" 2>/dev/null || echo "")
    if [[ -n "$pkg_meta" ]]; then
      decoded=$(echo "$pkg_meta" | jq -r '.content // ""' | base64 -d 2>/dev/null || echo "")
      min_server=$(echo "$decoded" | jq -r '.minServerVersion // ""' 2>/dev/null || echo "")
    fi
    new_row=$(jq -n --arg v "$version" --arg m "$min_server" --arg r "$released_at" \
      '{version: $v, minServer: $m, released_at: (if $r == "" then null else $r end)}')
    versions=$(echo "$prev_versions" | jq --argjson new "$new_row" '[$new] + .')
    echo "  + new version $version (minServer: ${min_server:-<empty — backfill needed>})"
  else
    versions="$prev_versions"
  fi

  # Top-level mirror = latest (versions[0]).
  top_version=$(echo "$versions" | jq -r '.[0].version // ""')
  top_released=$(echo "$versions" | jq -r '.[0].released_at // ""')

  entry=$(jq -n \
    --arg name "$name" \
    --arg org "$org" \
    --arg repo "$repo" \
    --arg icon "$icon_url" \
    --arg docs "$docs_url" \
    --arg homepage "$homepage_url" \
    --arg version "$top_version" \
    --arg released_at "$top_released" \
    --argjson versions "$versions" \
    --argjson experiment "$experiment" \
    --argjson r "$repo_json" \
    '{
      name: $name,
      description: ($r.description // ""),
      version: (if $version == "" then null else $version end),
      icon: (if $icon == "" then null else $icon end),
      docs: (if $docs == "" then null else $docs end),
      homepage: (if $homepage == "" then null else $homepage end),
      experiment: $experiment,
      github: {
        organization: $org,
        repo: $repo,
        full_name: $r.full_name,
        html_url: $r.html_url,
        default_branch: $r.default_branch,
        language: $r.language,
        license: ($r.license.spdx_id // null),
        stargazers_count: $r.stargazers_count,
        forks_count: $r.forks_count
      },
      released_at: (if $released_at == "" then null else $released_at end),
      versions: $versions
    }')

  # Every package goes into the experiment-aware view. Only non-experiment ones are
  # also written to the legacy view — an experiment package must never land in
  # packages.json, which is what old neo-web builds render unconditionally.
  all_results=$(echo "$all_results" | jq --argjson e "$entry" '. + [$e]')
  if [[ "$experiment" != "true" ]]; then
    results=$(echo "$results" | jq --argjson e "$entry" '. + [$e]')
  fi
done

echo "$results" | jq '.' > "$OUTPUT_JSON"
echo "$all_results" | jq '.' > "$ALL_JSON"
echo "Wrote $OUTPUT_JSON ($(echo "$results" | jq 'length') packages, legacy view)"
echo "Wrote $ALL_JSON ($(echo "$all_results" | jq 'length') packages, $(echo "$all_results" | jq '[.[] | select(.experiment)] | length') experiment)"

if [[ ${#skipped[@]} -gt 0 ]]; then
  echo
  echo "WARNING ${#skipped[@]} package(s) unreachable: ${skipped[*]}"
  echo "  Their previous entries were republished unchanged, so the catalog is intact."
  echo "  Restore public access, or remove the package from $PACKAGES_YAML — the hub"
  echo "  does not drop an entry on its own."
  exit 2
fi
