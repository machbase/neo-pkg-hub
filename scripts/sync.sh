#!/usr/bin/env bash
set -euo pipefail

PACKAGES_YAML="${PACKAGES_YAML:-packages.yaml}"
OUTPUT_JSON="${OUTPUT_JSON:-packages.json}"
GH_API="${GH_API:-https://api.github.com}"

AUTH_HEADER=()
if [[ -n "${GITHUB_TOKEN:-}" ]]; then
  AUTH_HEADER=(-H "Authorization: Bearer ${GITHUB_TOKEN}")
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
  if [[ -n "$icon_override" ]]; then
    icon_url="$icon_override"
  else
    icon_url=""
    for ext in svg png; do
      candidate="https://raw.githubusercontent.com/${full_name}/${default_branch}/icon.${ext}"
      if curl -fsSL -o /dev/null -I "$candidate"; then
        icon_url="$candidate"
        break
      fi
    done
  fi

  docs_url=""
  if [[ -n "$docs_path" ]]; then
    docs_rel="${docs_path#${repo}/}"
    docs_url="https://raw.githubusercontent.com/${full_name}/${default_branch}/${docs_rel}"
  fi

  homepage_url=$(echo "$repo_json" | jq -r '.homepage // ""')

  entry=$(jq -n \
    --arg name "$name" \
    --arg org "$org" \
    --arg repo "$repo" \
    --arg icon "$icon_url" \
    --arg docs "$docs_url" \
    --arg homepage "$homepage_url" \
    --arg version "$version" \
    --arg released_at "$released_at" \
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
      released_at: (if $released_at == "" then null else $released_at end)
    }')

  results=$(echo "$results" | jq --argjson e "$entry" '. + [$e]')
done

echo "$results" | jq '.' > "$OUTPUT_JSON"
echo "Wrote $OUTPUT_JSON"
