#!/usr/bin/env bash
set -euo pipefail

PACKAGES_YAML="${PACKAGES_YAML:-packages.yaml}"
OUTPUT_JSON="${OUTPUT_JSON:-packages.json}"
README_DIR="${README_DIR:-readmes}"
GH_API="${GH_API:-https://api.github.com}"
RAW_BASE="${RAW_BASE:-https://raw.githubusercontent.com}"

mkdir -p "$README_DIR"

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

  echo "Syncing: $org/$repo (name: $name)"

  repo_json=$(curl -fsSL "${AUTH_HEADER[@]}" \
    -H "Accept: application/vnd.github+json" \
    "$GH_API/repos/$org/$repo")

  default_branch=$(echo "$repo_json" | jq -r '.default_branch')

  entry=$(jq -n \
    --arg name "$name" \
    --arg org "$org" \
    --arg repo "$repo" \
    --argjson r "$repo_json" \
    '{
      name: $name,
      description: ($r.description // ""),
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
      pushed_at: $r.pushed_at
    }')

  readme_url="$RAW_BASE/$org/$repo/$default_branch/README.md"
  if curl -fsSL "${AUTH_HEADER[@]}" "$readme_url" -o "$README_DIR/$name.md"; then
    echo "  README -> $README_DIR/$name.md"
  else
    echo "  README not found at $readme_url" >&2
    rm -f "$README_DIR/$name.md"
  fi

  results=$(echo "$results" | jq --argjson e "$entry" '. + [$e]')
done

echo "$results" | jq '.' > "$OUTPUT_JSON"
echo "Wrote $OUTPUT_JSON"
