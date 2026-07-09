#!/usr/bin/env node
'use strict';

// Validation gates for packages.json (issue machbase/neo#1369, Phase 4).
// Uses the same semver library neo-web's runtime eligibility check uses, so the
// CI invariant and the client agree on version precedence (comparator 단일화).
//
// Gates:
//   - schema:       every entry has a non-empty versions[]; top-level version
//                   mirrors versions[0].
//   - format:       every versions[].version and minServer is valid semver
//                   (leading `v` allowed on version; minServer must be plain).
//   - completeness: every versions[] row has a minServer  (WARN by default; set
//                   STRICT_MIN_SERVER=1 to make it a hard error once every package
//                   ships package.json `minServerVersion`).
//   - monotonic:    within a package, a newer version's minServer is >= an older
//                   version's minServer.
//   - no-regression: against an optional baseline (argv[3], the committed
//                   packages.json), a package that had an icon must still have one.
//                   A throttled icon probe once blanked three icons and the job
//                   pushed it, because nothing compared the result to the baseline.
//                   When an icon is deliberately deleted upstream, re-run with
//                   ALLOW_ICON_REMOVAL=1 to let the removal through.
//
// Exit 1 on any error.

const fs = require('fs');
const semver = require('semver');

const file = process.argv[2] || 'packages.json';
const baselineFile = process.argv[3] || null;
const STRICT = process.env.STRICT_MIN_SERVER === '1';
const ALLOW_ICON_REMOVAL = process.env.ALLOW_ICON_REMOVAL === '1';

const strip = (v) => String(v || '').trim().replace(/^v/i, '');
const errors = [];
const warnings = [];

const readJson = (path) => JSON.parse(fs.readFileSync(path, 'utf8'));

let data;
try {
    data = readJson(file);
} catch (e) {
    console.error(`ERROR cannot read/parse ${file}: ${e.message}`);
    process.exit(1);
}
if (!Array.isArray(data)) {
    console.error('ERROR packages.json must be a top-level array');
    process.exit(1);
}

// Baseline is advisory: absent or unreadable (first run, fresh clone) just skips
// the regression gate rather than failing the sync.
let baseline = [];
if (baselineFile) {
    try {
        const parsed = readJson(baselineFile);
        if (Array.isArray(parsed)) baseline = parsed;
        else warnings.push(`baseline ${baselineFile} is not an array — skipping regression gate`);
    } catch {
        warnings.push(`baseline ${baselineFile} unreadable — skipping regression gate`);
    }
}
const baselineByName = new Map(baseline.map((p) => [p.name, p]));

for (const pkg of data) {
    const name = pkg && pkg.name ? pkg.name : '<unnamed>';
    const versions = Array.isArray(pkg.versions) ? pkg.versions : null;

    // no-regression — an icon that was published must not silently disappear.
    const before = baselineByName.get(name);
    if (before && before.icon && !pkg.icon) {
        const msg = `${name}: icon dropped (was "${before.icon}")`;
        if (ALLOW_ICON_REMOVAL) {
            warnings.push(`${msg} — allowed via ALLOW_ICON_REMOVAL`);
        } else {
            errors.push(`${msg} — a failed probe, not a real removal? re-run, or set ALLOW_ICON_REMOVAL=1 if intended`);
        }
    }

    // schema
    if (!versions || versions.length === 0) {
        errors.push(`${name}: missing or empty versions[]`);
        continue;
    }
    if (pkg.version !== versions[0].version) {
        errors.push(`${name}: top-level version "${pkg.version}" != versions[0] "${versions[0].version}" (must mirror latest)`);
    }

    for (const row of versions) {
        // format — version
        if (!semver.valid(strip(row.version))) {
            errors.push(`${name} ${row.version}: invalid semver version`);
        }
        // completeness + format — minServer
        if (!row.minServer) {
            (STRICT ? errors : warnings).push(`${name} ${row.version}: minServer empty (backfill needed)`);
        } else if (!semver.valid(strip(row.minServer))) {
            errors.push(`${name} ${row.version}: invalid minServer "${row.minServer}"`);
        }
    }

    // monotonic — sort the rows that have a valid minServer by version asc, then
    // assert minServer never decreases.
    const withMin = versions.filter((r) => r.minServer && semver.valid(strip(r.minServer)) && semver.valid(strip(r.version)));
    const sorted = [...withMin].sort((a, b) => semver.compare(strip(a.version), strip(b.version)));
    for (let i = 1; i < sorted.length; i++) {
        if (semver.compare(strip(sorted[i].minServer), strip(sorted[i - 1].minServer)) < 0) {
            errors.push(
                `${name}: minServer not monotonic — ${sorted[i].version} (${sorted[i].minServer}) < ${sorted[i - 1].version} (${sorted[i - 1].minServer})`
            );
        }
    }
}

warnings.forEach((w) => console.warn(`WARN  ${w}`));
if (errors.length) {
    errors.forEach((e) => console.error(`ERROR ${e}`));
    console.error(`\npackages.json validation FAILED (${errors.length} error(s))`);
    process.exit(1);
}
console.log(`packages.json validation passed (${data.length} packages${warnings.length ? `, ${warnings.length} warning(s)` : ''})`);
