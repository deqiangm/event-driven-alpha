#!/usr/bin/env bash
# scripts/09_compute_structural_forces.sh — Structural Force Aggregation & C1 Conflict Arbitration
# Collects per-force outputs, detects direction conflicts, applies priority matrix
# Pipeline order: Force Computation → C1 Conflict → C3 Confluence → C4 Gate
# stdout=JSON machine output, stderr=human logs

set -euo pipefail
ESAD_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "${ESAD_ROOT}/lib/esad_common.sh"

FORCE_DATE="${1:-$TODAY}"
PRIORITY_FILE="${CONFIG_DIR}/force_priority.json"
OUTPUT="${DATA_DIR}/structural_forces_${TODAY}.json"
export ESAD_CACHE_DIR="${CACHE_DIR}"
export ESAD_CONFIG_DIR="${CONFIG_DIR}"
export TODAY

esad_log "C1/C3/C4: Computing structural forces pipeline for ${FORCE_DATE}"

# ── Step 1: Collect all per-force outputs ──
collect_forces() {
    python3 << PYEOF
import json, sys, os, glob

cache_dir = os.environ.get('ESAD_CACHE_DIR', '')
today = os.environ.get('TODAY', '')
if not cache_dir:
    cache_dir = os.path.expanduser('~/.hermes/cron/event-driven-alpha/data/cache')

force_patterns = {
    'F1': 'ipo_underwriter_*',
    'F2': 'gamma_dealer_*',
    'F3': 'quarter_end_*',
    'F4': 'short_squeeze_*',
    'F5a': 'fomc_vol_*',
    'F5b': 'fed_balance_sheet_*',
    'F5c': 'fomc_guidance_*',
    'F6': 'index_rebalancing_*',
    'F7': 'lockup_expiration_*',
    'F8': 'etf_flows_*',
    'F9': 'vix_term_structure_*',
}

active_forces = []
for fcode, pattern in force_patterns.items():
    matches = glob.glob(os.path.join(cache_dir, pattern + '.json'))
    today_nodash = today.replace('-', '')
    matches = [m for m in matches if today in os.path.basename(m) or today_nodash in os.path.basename(m)]
    if matches:
        try:
            with open(matches[-1]) as f:
                data = json.load(f)
            confidence = float(data.get('confidence', 0))
            if confidence > 0:
                direction = data.get('direction', 'NEUTRAL')
                source_tag = data.get('source_tag', f'{fcode.lower()}:{today}')
                force_name = data.get('force_name', fcode)
                active_forces.append({
                    'force_code': fcode,
                    'force_name': force_name,
                    'direction': direction,
                    'confidence': confidence,
                    'source_tag': source_tag,
                    'raw_data_file': os.path.basename(matches[-1])
                })
        except Exception as e:
            pass

print(json.dumps(active_forces))
PYEOF
}

# ── Step 2: C1 — Conflict Detection & Arbitration ──
resolve_conflicts() {
    local forces_json="$1"
    python3 << PYEOF
import json, sys, os

forces = json.loads('$forces_json') if '$forces_json' else []

priority_path = os.environ.get('ESAD_CONFIG_DIR', '') + '/force_priority.json'
try:
    with open(priority_path) as f:
        priority = json.load(f)
except Exception:
    try:
        with open(os.path.expanduser('~/.hermes/cron/event-driven-alpha/config/force_priority.json')) as f:
            priority = json.load(f)
    except Exception:
        priority = {'forces': []}

rank_map = {}
for entry in priority.get('forces', []):
    code = entry.get('force_code', '')
    rank_map[code] = entry.get('priority_rank', 99)

if not forces:
    print(json.dumps({'active_forces': [], 'conflicts': [], 'pipeline_step': 'C1'}))
    sys.exit(0)

bullish = [f for f in forces if f['direction'] in ('BULLISH', 'MILDLY_BULLISH', 'EXPLOSIVELY_BULLISH')]
bearish = [f for f in forces if f['direction'] in ('BEARISH', 'MILDLY_BEARISH')]

conflicts = []
adjusted_forces = list(forces)

if bullish and bearish:
    for bf in bullish:
        bf_rank = rank_map.get(bf['force_code'], 99)
        for br in bearish:
            br_rank = rank_map.get(br['force_code'], 99)
            rank_delta = abs(bf_rank - br_rank)
            if rank_delta <= 1:
                winner_conf = max(bf['confidence'], br['confidence'])
                adj_conf = round(winner_conf * 0.7, 3)
                conflicts.append({
                    'type': 'adjacent_stalemate',
                    'force_a': bf['force_code'], 'force_b': br['force_code'],
                    'rank_delta': rank_delta,
                    'dominant_direction': 'BLURRED',
                    'adjusted_confidence': adj_conf,
                    'signal_strength': 'COMPLEX'
                })
                for af in adjusted_forces:
                    if af['force_code'] in (bf['force_code'], br['force_code']):
                        af['confidence'] = adj_conf
                        af['direction'] = 'BLURRED'
                        af['conflict_penalty'] = round(1.0 - (adj_conf / winner_conf), 3)
            elif rank_delta > 1:
                if bf_rank < br_rank:
                    winner, loser = bf, br
                else:
                    winner, loser = br, bf
                penalty = (abs(bf_rank - br_rank) / 8) * 0.15
                adj_conf = round(winner['confidence'] * (1 - penalty), 3)
                if winner['confidence'] >= 0.80 and min(bf_rank, br_rank) <= 3:
                    opposing_top5 = sum(1 for f in (bearish if winner in bullish else bullish)
                                       if rank_map.get(f['force_code'], 99) <= 5)
                    if opposing_top5 < 2:
                        penalty = 0.0
                        adj_conf = winner['confidence']
                conflicts.append({
                    'type': 'priority_override',
                    'winner': winner['force_code'],
                    'loser': loser['force_code'],
                    'rank_delta': rank_delta,
                    'conflict_penalty': round(penalty, 4),
                    'dominant_direction': winner['direction'],
                    'adjusted_confidence': adj_conf
                })
                for af in adjusted_forces:
                    if af['force_code'] == winner['force_code']:
                        af['confidence'] = adj_conf
                        af['conflict_penalty'] = round(penalty, 4)
                        af['conflict_winner'] = True
                    elif af['force_code'] == loser['force_code']:
                        af['direction'] = 'OPPOSED'
                        af['opposed_by'] = winner['force_code']

if len(bullish) + len(bearish) >= 3 and len(bullish) >= 1 and len(bearish) >= 1:
    # Simplified multi-way blur
    pass

result = {
    'active_forces': adjusted_forces,
    'conflicts': conflicts,
    'active_count': len(forces),
    'conflict_count': len(conflicts),
    'pipeline_step': 'C1'
}
print(json.dumps(result))
PYEOF
}

# ── Step 3: C3 — Decorrelated Confluence Boost ──
compute_confluence() {
    local c1_output="$1"
    python3 << PYEOF
import json, sys

c1 = json.loads('$c1_output')
forces = c1.get('active_forces', [])

def extract_source(tag):
    if not tag or ':' not in tag:
        return tag or 'unknown'
    src = tag.split(':')[0]
    if src.startswith('fomc'):
        return 'fomc'
    return src

source_groups = {}
for f in forces:
    src = extract_source(f.get('source_tag', ''))
    if src not in source_groups:
        source_groups[src] = []
    source_groups[src].append(f)

S = len(source_groups)
D = sum(max(0, len(v) - 1) for v in source_groups.values())

B_base = {1: 1.00, 2: 1.20, 3: 1.35}.get(S, 1.45)
B_deriv = 1 + 0.10 * D
composite_boost = round(B_base * B_deriv, 3)

active_conf = [f['confidence'] for f in forces if f['direction'] not in ('OPPOSED', 'NEUTRAL')]
if not active_conf:
    active_conf = [f['confidence'] for f in forces if f['confidence'] > 0]
mean_conf = sum(active_conf) / len(active_conf) if active_conf else 0

raw_composite = mean_conf * composite_boost
final_confidence = min(raw_composite, 0.92)

bullish = [f for f in forces if f['direction'] in ('BULLISH', 'MILDLY_BULLISH', 'EXPLOSIVELY_BULLISH')]
bearish = [f for f in forces if f['direction'] in ('BEARISH', 'MILDLY_BEARISH')]
blurred = [f for f in forces if f['direction'] == 'BLURRED']

if blurred and not bullish and not bearish:
    dominant = 'BLURRED'
elif len(bullish) > len(bearish):
    dominant = 'BULLISH'
elif len(bearish) > len(bullish):
    dominant = 'BEARISH'
elif bullish and bearish:
    bull_w = sum(f.get('confidence', 0) for f in bullish)
    bear_w = sum(f.get('confidence', 0) for f in bearish)
    dominant = 'BULLISH' if bull_w >= bear_w else 'BEARISH'
else:
    dominant = 'NEUTRAL'

result = {
    'active_forces': forces,
    'confluence': {
        'independent_sources': S,
        'total_derivatives': D,
        'B_base': B_base,
        'B_deriv': round(B_deriv, 2),
        'composite_boost': composite_boost,
        'mean_confidence': round(mean_conf, 3),
        'raw_composite': round(raw_composite, 3),
        'final_confidence': round(final_confidence, 3),
        'capped': raw_composite > 0.92,
        'source_groups': {k: [f['force_code'] for f in v] for k, v in source_groups.items()}
    },
    'conflicts': c1.get('conflicts', []),
    'dominant_direction': dominant,
    'pipeline_step': 'C1+C3'
}
print(json.dumps(result))
PYEOF
}

# ── Step 4: C4 — Global Confidence Gate ──
apply_gate() {
    local c3_output="$1"
    python3 << PYEOF
import json, sys

data = json.loads('$c3_output')

MIN_GATE = 0.50
conf = data.get('confluence', {}).get('final_confidence', 0)

if conf >= 0.65:
    signal_tier = 'ACTION'
    alert_suppressed = False
elif conf >= 0.55:
    signal_tier = 'ALERT'
    alert_suppressed = False
elif conf >= MIN_GATE:
    signal_tier = 'WATCH'
    alert_suppressed = False
elif conf >= 0.45:
    signal_tier = 'POTENTIAL'
    alert_suppressed = True
else:
    signal_tier = 'SUPPRESSED'
    alert_suppressed = True

direction = data.get('dominant_direction', 'NEUTRAL')
forces = data.get('active_forces', [])
conflicts = data.get('conflicts', [])
confluence = data.get('confluence', {})

import datetime
signal_id = 'sig_' + datetime.date.today().strftime('%Y%m%d') + '_' + direction.lower()
if conflicts:
    signal_id += '_c' + str(len(conflicts))

result = {
    'date': '$TODAY',
    'design_version': '1.2-batch2',
    'signal_id': signal_id,
    'direction': direction,
    'confidence': round(conf, 3),
    'signal_tier': signal_tier,
    'alert_suppressed': alert_suppressed,
    'active_force_count': len([f for f in forces if f.get('confidence', 0) > 0]),
    'conflict_count': len(conflicts),
    'confluence_detail': confluence,
    'conflicts_detail': conflicts[:5],
    'forces_summary': [
        {'code': f['force_code'], 'dir': f['direction'], 'conf': f['confidence'],
         'src': f.get('source_tag', ''), 'penalty': f.get('conflict_penalty', 0)}
        for f in forces if f.get('confidence', 0) > 0
    ],
    'pipeline': 'Force->C1(conflict)->C3(confluence)->C4(gate)',
    'gate_applied': True,
    'min_gate': MIN_GATE
}
print(json.dumps(result))
PYEOF
}

# ── Main Pipeline ──
esad_log "Step 1/4: Collecting per-force outputs"
forces_json=$(collect_forces)
force_count=$(echo "$forces_json" | python3 -c "import json,sys; print(len(json.loads(sys.stdin.read())))" 2>/dev/null || echo 0)
esad_log "Collected ${force_count} active forces"

esad_log "Step 2/4: C1 — Conflict Resolution"
c1_output=$(resolve_conflicts "$forces_json")
conflict_count=$(echo "$c1_output" | python3 -c "import json,sys; print(json.loads(sys.stdin.read()).get('conflict_count',0))" 2>/dev/null || echo 0)
esad_log "C1 found ${conflict_count} conflicts"

esad_log "Step 3/4: C3 — Decorrelated Confluence Boost"
c3_output=$(compute_confluence "$c1_output")
src_count=$(echo "$c3_output" | python3 -c "import json,sys; d=json.loads(sys.stdin.read()); print(d['confluence']['independent_sources'])" 2>/dev/null || echo 0)
deriv_count=$(echo "$c3_output" | python3 -c "import json,sys; d=json.loads(sys.stdin.read()); print(d['confluence']['total_derivatives'])" 2>/dev/null || echo 0)
final_conf=$(echo "$c3_output" | python3 -c "import json,sys; d=json.loads(sys.stdin.read()); print(d['confluence']['final_confidence'])" 2>/dev/null || echo 0)
esad_log "C3: ${src_count} sources, ${deriv_count} derivatives, confidence=${final_conf}"

esad_log "Step 4/4: C4 — Global Confidence Gate"
final_output=$(apply_gate "$c3_output")
tier=$(echo "$final_output" | python3 -c "import json,sys; print(json.loads(sys.stdin.read()).get('signal_tier','?'))" 2>/dev/null || echo '?')
direction=$(echo "$final_output" | python3 -c "import json,sys; print(json.loads(sys.stdin.read()).get('direction','?'))" 2>/dev/null || echo '?')
esad_log "C4: tier=${tier} direction=${direction}"

echo "$final_output" > "$OUTPUT"
esad_log "Pipeline complete. Output: ${OUTPUT}"
echo "$final_output"
