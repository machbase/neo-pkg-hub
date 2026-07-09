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

PACKAGES_YAML="${PACKAGES_YAML:-packages.yaml}"
OUTPUT_JSON="${OUTPUT_JSON:-packages.json}"
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

# Existing accumulator (empty array on first run).
if [[ -f "$OUTPUT_JSON" ]]; then
  existing=$(cat "$OUTPUT_JSON")
else
  existing="[]"
fi

count=$(yq '.packages | length' "$PACKAGES_YAML")
results="[]"

for ((i=0; i<count; i++)); do
  name=$(yq -r ".packages[$i].name" "$PACKAGES_YAML")
  org=$(yq -r ".packages[$i].organization" "$PACKAGES_YAML")
  repo=$(yq -r ".packages[$i].repo" "$PACKAGES_YAML")
  icon_override=$(yq -r ".packages[$i].icon // \"\"" "$PACKAGES_YAML")
  docs_path=$(yq -r ".packages[$i].docs // \"\"" "$PACKAGES_YAML")

  echo "Syncing: $org/$repo (name: $name)"

  repo_json=$(curl -fsSL "${AUTH_HEADER[@]}" \
    -H "Accept: application/vnd.github+json" \
    "$GH_API/repos/$org/$repo")

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
    --argjson r "$repo_json" \
    '{
      name: $name,
      description: ($r.description // ""),
      version: (if $version == "" then null else $version end),
      icon: (if $icon == "" then null else $icon end),
      docs: (if $docs == "" then null else $docs end),
      homepage: (if $homepage == "" then null else $homepage end),
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

  results=$(echo "$results" | jq --argjson e "$entry" '. + [$e]')
done

echo "$results" | jq '.' > "$OUTPUT_JSON"
echo "Wrote $OUTPUT_JSON"
