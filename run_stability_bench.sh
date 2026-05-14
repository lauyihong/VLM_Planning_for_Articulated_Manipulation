#!/bin/bash
# Multi-cabinet stability benchmark for the new TypeCheck pipeline.
#
# Per-cabinet flow (action_server is per-cabinet because the planner caches
# INIT state — reusing across cabinets fed stale handle_3d values):
#   1. start fresh action_server on $VLM_ZMQ_PORT
#   2. run client_sapien_generic_scaled.py with HEADLESS+AUTOSTART+TIME_BUDGET
#   3. save result.json
#   4. kill server
#
# Aggregates per-cabinet results into $OUT_ROOT/all_results.json + a table.

set -e
VENV=/scratch/liuyf23/conda_envs/repro_vlm_plan/bin/python
DIR=/scratch/liuyf23/coco-data/VLM_Planning_for_Articulated_Manipulation
OUT_ROOT=${OUT_ROOT:-/tmp/vlm_stability_bench}
TIME_BUDGET=${TIME_BUDGET:-80}
ZMQ_PORT=${VLM_ZMQ_PORT:-5556}
PARTNET_BASE=/scratch/liuyf23/datasets/partnet_mobility/StorageFurniture

mkdir -p $OUT_ROOT
LOG_DIR=$OUT_ROOT/logs
mkdir -p $LOG_DIR

# Cabinet list:  pid  scale  z  url(optional override)
declare -a cases=(
  "40147 0.6 0.5"
  "46230 0.6 0.5"
  "44781 0.6 0.5"
  "45146 0.6 0.5"
  "45235 0.6 0.5"
  "45575 0.6 0.5"
)

for cfg in "${cases[@]}"; do
  set -- $cfg
  pid=$1; scale=$2; cz=$3
  case_dir=$OUT_ROOT/${pid}
  mkdir -p $case_dir

  if [ -d "$DIR/${pid}" ]; then
    URDF=$DIR/${pid}/mobility.urdf
  else
    URDF=$PARTNET_BASE/${pid}/mobility.urdf
  fi
  if [ ! -f "$URDF" ]; then echo "[skip] no URDF for $pid"; continue; fi

  echo ""
  echo "════════════════════════════════════"
  echo "Case ${pid}  URDF=${URDF}  scale=${scale}  z=${cz}"
  echo "════════════════════════════════════"

  # 1. kill any prior server we tracked
  if [ -n "${SERVER_PID:-}" ]; then kill $SERVER_PID 2>/dev/null || true; sleep 2; fi

  # 2. start fresh action_server in background, capture python PID via $!
  CUDA_VISIBLE_DEVICES=${CUDA_VISIBLE_DEVICES:-3} \
      OPENAI_API_KEY=$(cat /tmp/.openai_key) \
      VLM_ZMQ_PORT=$ZMQ_PORT PYTHONUNBUFFERED=1 \
      nohup $VENV -u $DIR/action_server.py --use_api true > $LOG_DIR/${pid}_server.log 2>&1 &
  SERVER_PID=$!
  for i in $(seq 1 30); do
    if ss -tln | grep -q ":$ZMQ_PORT "; then break; fi
    sleep 1
  done

  # 3. run client
  CUDA_VISIBLE_DEVICES=${CUDA_VISIBLE_DEVICES:-3} \
      CABINET_HEADLESS=1 CABINET_AUTOSTART=1 CABINET_TIME_BUDGET_S=$TIME_BUDGET \
      CABINET_RESULT_JSON=$case_dir/result.json \
      CABINET_URDF=$URDF CABINET_SCALE=$scale CABINET_Z=$cz \
      VLM_ZMQ_PORT=$ZMQ_PORT PYTHONUNBUFFERED=1 \
      $VENV -u $DIR/client_sapien_generic_scaled.py 2>&1 \
    | grep -v "Step.*已" > $LOG_DIR/${pid}_client.log

  # 4. kill action_server before next case + wait for port to free
  if [ -n "$SERVER_PID" ]; then
    kill $SERVER_PID 2>/dev/null || true
    for i in $(seq 1 20); do
      if ! ss -tln | grep -q ":$ZMQ_PORT "; then break; fi
      sleep 1
    done
  fi
  echo "[done] ${pid} → $(cat $case_dir/result.json 2>/dev/null | grep -E 'joint_|n_steps' | head -5)"
done

echo ""
echo "════════════════════════════════════"
echo "Aggregating $OUT_ROOT/*/result.json …"
echo "════════════════════════════════════"
$VENV - <<PYEOF
import glob, json, os, xml.etree.ElementTree as ET
rows = []
for p in sorted(glob.glob("$OUT_ROOT/*/result.json")):
    r = json.load(open(p))
    pid = os.path.basename(os.path.dirname(p))
    # Lookup GT joint limits for the actuated joint(s)
    urdf_path = r["cabinet_urdf"]
    gt_limits = {}
    for j in ET.parse(urdf_path).getroot().findall("joint"):
        nm = j.attrib.get("name"); jt = j.attrib.get("type")
        if jt in ("revolute","prismatic"):
            lim = j.find("limit")
            up = float(lim.attrib.get("upper", 0)) if lim is not None else 0
            lo = float(lim.attrib.get("lower", 0)) if lim is not None else 0
            gt_limits[nm] = (lo, up, jt)
    # Find which actual joint moved most
    qpos = r["final_qpos"]
    moved = [(nm, q) for nm, q in qpos.items() if abs(q) > 0.01]
    if moved:
        moved_name, moved_val = max(moved, key=lambda x: abs(x[1]))
    else:
        # No joint moved meaningfully — pick first joint name and report 0
        moved_name = next(iter(qpos.keys()))
        moved_val = 0.0
    gt = gt_limits.get(moved_name, (0,0,"?"))
    rows.append({
        "pid": pid,
        "joint": moved_name,
        "type": gt[2],
        "q_final": moved_val,
        "gt_upper": gt[1],
        "frac_opened": (moved_val / gt[1]) if gt[1] else 0,
        "n_steps": r["n_steps"],
        "wall_s": r["wall_time_s"],
    })

with open("$OUT_ROOT/all_results.json", "w") as f:
    json.dump(rows, f, indent=2)

print(f"{'pid':<6} {'joint':<10} {'type':<10} {'q_final':>10} {'gt_upper':>10} {'frac':>7} {'n_steps':>8}")
print("-" * 70)
for r in rows:
    print(f"{r['pid']:<6} {r['joint']:<10} {r['type']:<10} "
          f"{r['q_final']:10.4f} {r['gt_upper']:10.4f} "
          f"{r['frac_opened']*100:6.1f}% {r['n_steps']:8d}")

n_total = len(rows)
n_partial = sum(1 for r in rows if r['frac_opened'] > 0.10)
n_done = sum(1 for r in rows if r['frac_opened'] > 0.80)
print(f"\nstability: opened≥10%: {n_partial}/{n_total}, opened≥80%: {n_done}/{n_total}")
PYEOF
