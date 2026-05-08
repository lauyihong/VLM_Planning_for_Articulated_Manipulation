# Integration Plan — Sidecar / Scan / Fusion (Options 2 / 1 / 3)

This document is the canonical reference for the three-stage integration of
the **reconstruction_activeperception** streaming pipeline into the
**VLM_Planning_for_Articulated_Manipulation** simulation repo. The original
plan document lived only in chat; this file captures it for posterity, marks
each option's status, and adds expanded designs derived from the
2026-05-08 session findings.

---

## Status Overview

| Option | Title | Status | Last commit |
|--------|-------|--------|-------------|
| **2** | Reconstruction Server Sidecar | ✅ shipped (drawer case emits physics-consistent URDF) | `ddc9e2d` on `claude/sidecar` |
| **1** | ScanPlanner multi-handle exploration | ⏳ pending — bottleneck ② is the gating sub-piece | — |
| **3** | Closed-loop parallel fusion | ⏳ pending — depends on Option 1 | — |

See `SESSION_SUMMARY_2026-05-08.zh.md` for a full record of what was done in
the most recent session.

---

# Option 2 — Reconstruction Server Sidecar (✅ DONE)

> **Original TL;DR**: VLM_Planning_for_Articulated_Manipulation 跑 task 的同时，旁路一个 `reconstruction_server` 进程累积 RGB-D 流，task 结束后吐出一份 URDF。**不闭环、不影响 ActionPlanner 决策**，仅作为重建结果旁观者。
>
> **预算**: 2 小时
> **前置**: `SAM3D_ActivePerception` 已改名为 `reconstruction_activeperception` 并 commit
> **下一里程碑**: Option 1 (ScanPlanner 多 handle 探索) → Option 3 (闭环 + 并联融合)

## Context (original)

涉及两个 repo：

- **VLM_Planning_for_Articulated_Manipulation**: 仿真 + Panda 机械臂 + 现有 task pipeline（`det_pipeline:8001` + `action_server:5555` + `client_sapien_*.py`）
- **reconstruction_activeperception**: SAM3 video segmentation + streaming URDF 重建（前身 SAM3D_ActivePerception）

本里程碑只在 **VLM_Planning** 仓库内新增一个 sidecar HTTP 服务，调用 `reconstruction_activeperception` 的 streaming API。reconstruction_activeperception 仓库本身不改。

## Architecture (original)

```
                                          ┌─────────────────────────────┐
                                          │  reconstruction_server :8002│
                                          │  (新增)                     │
client_sapien_40147.py                    │  - StreamingSAM3 (GPU)      │
   ├─ ZMQ → action_server :5555  (不改)   │  - SceneState (memory+disk) │
   ├─ HTTP → det_pipeline :8001  (不改)   │  POST /init                 │
   └─ HTTP → reconstruction_server (新)   │  POST /ingest_frame         │
                                          │  POST /emit_urdf            │
                                          │  GET  /health               │
                                          └─────────────────────────────┘
                                                       ↓
                                          uses pipeline.streaming.* APIs
                                          from reconstruction_activeperception
```

**关键约束**:
- reconstruction_server 不读不写 ZMQ；client 单独 POST 给它
- action_server 完全不动
- 重建结果只落盘成 URDF 文件，不实时反馈给 ActionPlanner

## Original Task List (T0–T4) — annotated with shipped commits

### T0 — 环境前置检查
- ✅ Verified `RECONSTRUCTION_PIPELINE_PATH`, owlsam env imports work, OPENAI key, HF cache has `models--facebook--sam3`.
- Plus: discovered Open3D 0.18 `ScalableTSDFVolume.integrate()` segfaults on Ubuntu 24.04 + Py3.11 + RTX 5090 → upgraded to 0.19 (env-level fix, not in commits).

### T1 — `reconstruction_server.py` (FastAPI :8002)
- ✅ shipped in commit `3116444` (initial), refined in `0f54060` (faulthandler + main-thread SAM3 preload + async-but-blocking handlers), `7db33d3` (GT-mask shim).
- Endpoints: `POST /init` `POST /ingest_frame` `POST /emit_urdf` `GET /health`.

### T2 — `client_sapien_40147.py` modifications
- ✅ Camera-rotation change (45°) was applied then **reverted** per user request — see commit history. Original repo camera setting kept.
- ✅ Imports + constants added (`RECON_URL`, `RECON_SEND_INTERVAL_S`, `RECON_MAX_INGEST`).
- ✅ Init on first frame, periodic ingest. Final cap+interval tuned: 15 frames @ 2 s (commit `478d3f8`).
- ✅ Emit URDF on shutdown (only fires when client exits gracefully via Ctrl+C; SIGTERM cleanup misses it but doesn't matter).
- ✅ **Async fire-and-forget HTTP** (commit `fe082bd`) — synchronous post blocked SAPIEN main loop.
- ✅ **GT-mask injection** (commit `7db33d3`) — bypasses SAM3 by sending SAPIEN segmentation buffer as ground-truth masks.

### T3 — `run_all.sh` orchestration
- ✅ Sidecar starts between det_pipeline and action_server.
- ✅ Trap cleanup includes `RECON_PID`.
- ✅ `OPENAI_API_KEY` sourcing at script top so all subprocesses (including sidecar's Phase D VLM call) inherit it (commit `fe082bd`).
- ✅ `RECONSTRUCTION_PIPELINE_PATH` + `SAM3D_PIPELINE_PATH` (back-compat) both exported.

### T4 — End-to-end verification
- ✅ Drawer case verified end-to-end with all three intent layers aligned:
  ```
  USER_INSTRUCTION = "open the drawer"
  PARTS_BY_ID[40147].moving = ["drawer"]
  task: VLM picks drawer handle → TypeCheck Translation → Pull_Linear runs
  ```
  produces:
  ```
  type=prismatic ✅
  axis≈±X (panel_normal same line) ✅
  range=0.4305 m ✅ (matches ProbePull 0.05 + Pull_Linear 0.38 = 0.43 m)
  confidence=1.0
  ```
  See `experiments/drawer_1778246277/`.

## Option 2 Final Deliverables (shipped)

```
3116444  feat: add reconstruction sidecar server (Option 2)
0f54060  fix: stabilize reconstruction sidecar through full task lifecycle
fe082bd  main-line 1: async sidecar ingest + ingest cap + OPENAI key injection
7db33d3  add GT-mask injection path for sidecar mask-quality diagnosis
01a8484  align experiment for drawer scenario
478d3f8  sidecar ingest: widen capture window (15 frames @ 2s)
ddc9e2d  docs: add session summary for 2026-05-08 work
```

## Option 2 Known Bottlenecks (shipped with workarounds, not yet structurally fixed)

| # | Bottleneck | Effect | Workaround | Real fix |
|---|---|---|---|---|
| ① | SAM3 video tracker re-classifies labels at frame 3+ when panda partially occludes | wrong-part mask | GT-mask shim (7db33d3) | replace SAM3 / improve prompt |
| ② | `PARTS_BY_ID.moving` is hardcoded ≠ task runtime moving part | sidecar reconstructs the wrong part | manual sync of `USER_INSTRUCTION` + `PARTS_BY_ID` | **Option 1's main subgoal** — see below |
| ③ | Phase C front-edge p95 disp sensitive to perspective-dominant motion | axis bias when motion ≈ camera view direction | wider capture window (478d3f8) | use 3D centroid disp instead |
| ④ | Phase D VLM frequently picks wrong axis | — | Phase E correctly ignores when Phase C confidence high | better OBB-direction context in VLM prompt |
| ⑤ | URDF mesh fragmentary (cabinet appears as L-shape) | mesh visually wrong | — | multi-view RGB-D capture |
| ⑥ | URDF axis sign inverted vs panel_normal | downstream consumers may need flip | post-process flip | encode convention in URDF emit |

---

# Option 1 — ScanPlanner Multi-Handle Exploration (⏳ pending)

> **Original 4-bullet description** (from end of plan doc):
> - ActionPlanner 加 `mode='probe_only'`，stage list 截断为 `MoveTo→Approach→Grasp→ProbePull→Release`
> - 新建 `scan_planner.py` 外层循环，枚举 det_pipeline 给的所有 handle
> - reconstruction_server 加 `POST /attach_handle` + `GET /joint_state?handle_id=N`，建立 handle ↔ part 映射
> - 输出：完整的 `{handle_id: JointEstimate}` dict，覆盖整个柜子

## Expanded design (post-2026-05-08 session)

### Core insight from Option 2's experience

The lone *architectural* bottleneck Option 2 shipped with is **②: sidecar's
moving-part is hardcoded ≠ task's runtime moving part**. Every other
bottleneck is data/algorithm/device. So Option 1 should split into two
sub-milestones:

- **1a: Dynamic moving-part sync** (~1 hr) — fixes ② directly. Prerequisite for everything else.
- **1b: ScanPlanner outer loop** (~1.5 hr) — enumerates handles, builds the full part-joint map.
- **1c: Sidecar per-handle API surface** (~1 hr) — `/attach_handle` + `/joint_state?handle_id=N` endpoints; cleaner consumer interface.

### Sub-milestone 1a — Dynamic moving-part sync

**Goal**: sidecar's `state.moving_parts` and `state.parts` should track
ActionPlanner's runtime decision (target_handle_id + motion_type), not a
hardcoded `PARTS_BY_ID` table.

**Mechanism**: extend the ZMQ action_dict that action_server sends back to
client every step. Today it's:

```
{'shape': (10,), 'data': bytes}      # 10-D action vector only
```

Extend to:

```
{
  'shape': (10,), 'data': bytes,
  'stage':         'Pull_Linear',     # current ActionPlanner stage
  'moving_link':   'link_1',          # which URDF link is the moving part
  'motion_type':   'Translation',     # post-TypeCheck verdict
}
```

`client_sapien_*.py` reads `moving_link` + maps to SAM3 prompt name (using
the `LINK_TO_SAM3_PROMPT` we already added in commit `7db33d3`), then POSTs
to a new sidecar endpoint:

```
POST /set_moving_part
body (pickle): {'moving': 'drawer', 'static': ['cabinet body', 'cabinet door']}
```

Sidecar updates `state.moving_parts` / `state.static_parts`, drops accumulated
`per_part/{old_moving}/depth_pts.npy` so Phase C doesn't pollute fits with
the wrong part's history. Subsequent ingests then converge on the right part.

**Files to touch**:
- `action_server.py` — `process()` return path (~10 lines)
- `client_sapien_40147.py` (and 44817/46230) — ZMQ message parsing + new POST trigger (~25 lines)
- `reconstruction_server.py` — new `/set_moving_part` handler (~15 lines)

**Verifies**: rerun "open the drawer" e2e without manually editing
`PARTS_BY_ID[40147]` — sidecar should auto-pick `drawer` as moving and emit
the right URDF.

### Sub-milestone 1b — ScanPlanner outer loop

**Goal**: take the OWLv2 detection list (typically 2–4 handles per cabinet),
loop over each handle, run a probe-only ActionPlanner on it, accumulate
sidecar evidence across all handles, finally emit a URDF describing **every**
articulation in the scene.

**Mechanism**:

1. New file `scan_planner.py` that wraps action_server. Its outer loop:
   ```python
   for handle_id, handle_box in enumerate(detection_list):
       send_zmq_signal(server, 'reset_to_init')
       send_zmq_signal(server, f'set_target_handle={handle_id}')
       send_zmq_signal(server, 'start_probe_only')
       # wait for ActionPlanner to finish probe (Release done)
       send_zmq_signal(sidecar, '/attach_handle', handle_id)
       wait_for_idle()
   send_zmq_signal(sidecar, '/emit_full_scene_urdf')
   ```

2. ActionPlanner gets `mode='probe_only'`. When set, INIT plans only
   `MoveTo → Approach → Grasp → ProbePull → Release` (no TypeCheck-driven
   Pull_Linear/Pull_Arc). After Release, reset all stage state for next
   handle.

3. Sidecar gets `/attach_handle` — labels currently-buffered frames as
   "this batch belongs to handle N" so per-handle joint estimates can be
   separated. Internally one `SceneState` per handle, or one shared SceneState
   with a handle_id tag on each frame.

4. Sidecar `/emit_full_scene_urdf` synthesizes a URDF with all moving parts
   stitched onto the parent body.

**Files to touch**:
- New `scan_planner.py` (~120 lines)
- `action_server.py` — add `mode` flag + truncated stage list (~30 lines)
- `reconstruction_server.py` — `/attach_handle` + per-handle SceneState namespace (~50 lines)
- `client_sapien_*.py` — minor: stage-aware ingest gate (defer to per-handle scan window)

**Verifies**: cabinet 40147 has 1 door + 1 drawer; ScanPlanner should
output a URDF with **two** moving links (one revolute, one prismatic),
both axes sane, both ranges within 5% of GT.

### Sub-milestone 1c — Per-handle API + JointEstimate dict

**Goal**: clean output schema downstream consumers (especially Option 3) can
read.

```python
# GET /joint_state?handle_id=N
{
    'handle_id': 1,
    'link_name': 'drawer',
    'joint': {
        'type':     'prismatic',
        'origin':   [x, y, z],
        'axis':     [x, y, z],
        'range_lower': 0.0,
        'range_upper': 0.43,
        'confidence':  1.0,
        'source': {
            'axis_source':  'phase_c front-edge p95',
            'type_source':  'phase_d gpt-4o',
        },
    },
    'frames_used': [0, 2, 5, 7, 11],
}
```

Plus `GET /joint_states_all` returning `{handle_id: JointEstimate}` dict.

---

# Option 3 — Closed-Loop Parallel Fusion (⏳ pending)

> **Original 4-bullet description**:
> - 统一 `JointEstimate` schema (type / origin / axis / range / confidence / source)
> - ActionPlanner 在 TypeCheck 之前先 GET sam3d 的 joint_state
> - 写 `joint_estimate_fusion.py`：type 冲突按 cumulative_motion 决定，axis 冲突取 SAM3D direction + TypeCheck origin
> - Task 模式直接复用已 explore 出的 scene dict 作 prior

## Expanded sketch

### Core idea

Once Option 1 has populated a `{handle_id: JointEstimate}` dict for the
whole cabinet, Option 3 closes the loop: when a new task comes in,
ActionPlanner queries sidecar's prior-built scene dict **before** running
TypeCheck. If sidecar has high-confidence prior knowledge for the targeted
handle, ActionPlanner skips ProbePull/TypeCheck and goes straight to
Pull_Linear / Pull_Arc with the prior axis.

### Conflict resolution heuristics

| ActionPlanner says | Sidecar prior says | What to do |
|---|---|---|
| Translation, conf 0.5 | revolute, conf 0.95 | Trust sidecar, override |
| Translation, conf 0.95 | revolute, conf 0.6 | Trust ActionPlanner; sidecar prior was wrong, write back |
| both ≥ 0.9 but disagree | — | Cumulative_motion test: drag the part 5 cm, see which fit residual is lower |
| no sidecar prior for this handle | — | Fall back to standard TypeCheck |

### Files to touch (estimated)

- New `joint_estimate_fusion.py` (~80 lines) — pure-function fuse (`p_action`, `p_sidecar`) → final
- `action_server.py` — `_initialize` calls `GET /joint_state` early; if confident, sets `motion_type` directly + skips TypeCheck stage insertion (~30 lines)
- `reconstruction_server.py` — `/joint_state?handle_id=N` query; cache the scene dict per partnet_id (~20 lines)

### Outcome

The first time a cabinet is encountered, ScanPlanner (Option 1) probes
every handle and builds the scene dict. From then on, every task on the
same cabinet is **fast** (no per-task ProbePull) and **robust** (uses
prior axis even when current frame's RGB is occluded/noisy).

---

# Recommended Sequencing

```
Option 2 ✅ done
   │
   ▼
Sub-milestone 1a (dynamic moving-part sync)        ← do this FIRST. ~1 hr.
   │   Why: bottleneck ② is the lone architectural issue Option 2 left;
   │        without 1a every other Option 1 piece still requires manual
   │        PARTS_BY_ID alignment per task instance.
   ▼
Sub-milestone 1b (ScanPlanner outer loop)          ~1.5 hr
   │   Why: needed before Option 3 can populate its scene-dict prior.
   ▼
Sub-milestone 1c (per-handle API)                  ~1 hr
   │   Why: clean schema for Option 3 consumer.
   ▼
Option 3 (closed-loop fusion)                      ~3 hr
   │
   ▼
Optional precision improvements (③ ④ ⑤ ⑥ from Option 2 bottleneck table)

Total to "fully cooked": ~7 hr from Option 2 done.
```

---

# Out of scope / explicitly not doing

From the original Option 2 plan:

- ❌ 接 Phase 0 VLM（parts 已 hardcoded；后续 milestone 再加）
- ❌ 改 `action_server.py` / `ActionPlanner`（旁路，不闭环）  ← Option 1 will start touching this
- ❌ 接 TypeCheck 输出做并联融合（Option 3 才做）
- ❌ Part-handle mapping（Option 1 才做）
- ❌ ScanPlanner / `mode='probe_only'`（Option 1 才做）
- ❌ 把 URDF 反向加载到 SAPIEN（用户已确认永远不做）
- ❌ 改 `client_sapien_44817.py` / `client_sapien_46230.py`（先跑通 40147）

Items still out of scope after this session:
- Multi-cabinet generalisation across all 30 PartNet IDs
- Real-robot deployment (replace `client_sapien_*.py` with real RGB-D + IK)
- Active-perception camera relocation during scan (current single fixed view)

---

# Next-session quick-start

To resume work:

```bash
cd ~/.yifeng/VLM_Planning_for_Articulated_Manipulation
git checkout claude/sidecar
cat SESSION_SUMMARY_2026-05-08.zh.md       # what was last done
cat INTEGRATION_PLAN.md                    # this file
ls experiments/                            # latest experiment artifacts
```

Then start with **Option 1 sub-milestone 1a** — extending the ZMQ action
schema to carry `stage` + `moving_link` + `motion_type` metadata.
