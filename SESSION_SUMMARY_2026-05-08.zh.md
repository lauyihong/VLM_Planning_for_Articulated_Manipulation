# Session 工作进展总结 — 2026-05-08

> 起点：用户给的 `Integration Plan Option 2 — Reconstruction Server Sidecar`
> 终点：sidecar 端到端跑通，emit 出 type/axis/range 都跟物理一致的 URDF（drawer case）

---

## 一、跨 3 个 repo 的改动总览

```
lauyihong/reconstruction_activeperception
├── 78eb63d  整库改名 (SAM3D_ActivePerception → reconstruction_activeperception)
├── b3ab94c  local_validation/: render_archive_locally.py + run_e2e_local.py
├── 6d0172f  local_validation/README: Phase D 激活说明
└── 7d51f85  local_validation/render_urdf_autofit.py        ← 本次最后一个

lauyihong/VLM_Planning_for_Articulated_Manipulation (claude/sidecar branch)
├── 3116444  feat: add reconstruction sidecar server (Option 2)
├── 0f54060  fix: stabilize reconstruction sidecar full task lifecycle
├── fe082bd  async ingest + MAX_INGEST cap + OPENAI key
├── 7db33d3  GT-mask injection path
├── 01a8484  align experiment for drawer scenario
└── 478d3f8  widen capture window (15 frames @ 2s)         ← 当前 HEAD

lauyihong/ActivePerception_manipulation
└── d26b57c  update SAM3D_ActivePerception → reconstruction_activeperception path refs
```

---

## 二、技术里程碑（按时间序）

### 阶段 1: SAM3D_ActivePerception 复现 + 重命名

- 把 intern's SAM3D_ActivePerception fork (`/home/harvardair/.yifeng/`) 重命名为 reconstruction_activeperception
- 同步 3 个 repo 的路径引用（SCP 路径、env vars 保留）
- 写 `local_validation/` 让 `test_e2e_door.py` 在新机器（无 scratch 集群路径）上能跑
- 发现 **OpenAI API key 必须 source ~/.openai_env**：Phase D 没 key 就 silently skip
- Drawer case Layer 0 完全通过（type ✅, range_err 0.91% < 5%）

### 阶段 2: VLM_Planning_for_Articulated_Manipulation 复现

- 端口 8000 被占 → det_pipeline + action_server 改 :8001
- environment.yml 5 个坏 pin 修复（`clip==1.0`, `mobile-sam==1.0`, ROS deps 等）
- `bagpy==0.5` 与 `jinja2==3.1.6` 冲突
- 端到端跑通 40147 柜门任务（90° Pull_Arc）

### 阶段 3: Sidecar 集成 — Plan Option 2

按 plan 文档执行 T0 → T4：

- T0 env check: `owlsam` env 能 import streaming pipeline
- T1: `reconstruction_server.py` (FastAPI :8002) — `/init` `/ingest_frame` `/emit_urdf` `/health`
- T2: `client_sapien_40147.py` 加 sidecar HTTP 集成（init + 周期 ingest + emit on shutdown）
- T3: `run_all.sh` 编排 4 服务 + trap cleanup
- T4: e2e 验证

### 阶段 4: 关键 bug 修复（按发现序）

| Bug | Symptom | Root Cause | Fix | Commit |
|---|---|---|---|---|
| Sidecar SIGSEGV during first ingest | `proc exit code: -11`, no traceback | **Open3D 0.18 ScalableTSDFVolume.integrate() 在 Ubuntu 24.04 + Py3.11 + RTX 5090 segfaults** | `pip install --upgrade open3d → 0.19.0` (env-level) | 0f54060 |
| Phase D 默认 skip → Phase E 选错 type | `D_vlm.type=null` | OPENAI_API_KEY 在 nohup'd shell 不存在 | run_all.sh source ~/.openai_env | fe082bd |
| Task 卡在 Grasp，sidecar 累积 ingest 越来越慢 | client step counter 涨极慢 | **client 主循环 sync `requests.post(/ingest_frame)` 阻塞 SAPIEN sim** | async fire-and-forget threading.Thread | fe082bd |
| Emit "moving mesh missing" | cabinet_door.obj 没生成 | SAM3 mask 跟踪在 frame 3+ 重新分配 label，导致 cabinet_door centroid 几乎不动 | GT-mask shim 旁路 SAM3，用 SAPIEN seg buffer | 7db33d3 |
| Emit type 错（prismatic vs revolute） | URDF 跟 task 实际运动不符 | sidecar PARTS_BY_ID hardcoded ≠ task runtime moving part | 手动对齐 USER_INSTRUCTION + PARTS_BY_ID | 01a8484 |
| Phase C 拟合到 noise（drawer range 0.147m） | mask centroid 锁死 218 | 8 帧采集窗口太短 + 过早；只 4 帧落在 Pull_Linear 期间 | wall-time INTERVAL 2.0s + MAX_INGEST 15 | 478d3f8 |

### 阶段 5: drawer case 完美 e2e（最后两次实验）

| 实验 | 配置 | 结果 |
|---|---|---|
| `experiments/drawer_1778245284/` (run1) | 8×1.5s | type ✅ axis ❌ range ❌ |
| **`experiments/drawer_1778246277/`** (run2) | 15×2s | **type ✅ axis ✅ range ✅** |

run2 emitted URDF：
```xml
<joint name="drawer_joint" type="prismatic">
    <axis xyz="0.9930 -0.1153 -0.0260"/>     <!-- ≈ ±X, panel_normal 同一直线 -->
    <limit upper="0.4305"/>                  <!-- = ProbePull(5cm)+Pull_Linear(38cm)-->
</joint>
```

URDF 4-q 渲染（experiments/drawer_1778246277/urdf_renders/）显示 drawer 沿单轴干净滑出，关节运动**视觉上确认正确**。

---

## 三、当前已知瓶颈（未解决）

| # | 瓶颈 | 影响 | 当前 workaround |
|---|---|---|---|
| **①** | SAM3 video tracker 在 task frame 3+ 时 re-classify part labels | mask 跟错 part → Phase C 看 noise | GT-mask shim 旁路 SAM3 |
| **②** | Sidecar `PARTS_BY_ID` hardcoded ≠ task runtime moving part | sidecar 重建错的 part | 手动同步 USER_INSTRUCTION + PARTS_BY_ID |
| ③ | Phase C 用 OBB front-edge p95 disp，对透视主导运动敏感 | axis 偏差大 | 多帧 + 长间隔（478d3f8 已 mitigate）|
| ④ | Phase D VLM 给的 axis 经常错 | — | Phase E 看 Phase C confidence 高时正确忽略 |
| ⑤ | URDF mesh 几何残破（cabinet 主体呈 L 形） | mesh 视觉上不像柜子 | **单视角 RGB-D 重建固有局限**；要多视角 |
| ⑥ | URDF axis sign convention 跟 GT 反相 | 关节 q 增方向倒了 | 物理上仍正确，下游消费者可能需 sign flip |

瓶颈 ② 是真正阻塞 sidecar"通用化"的**唯一架构问题**——其他都是数据/算法/设备问题。

---

## 四、调试基础设施（产出资产）

```
~/.yifeng/reconstruction_activeperception/pipeline/streaming/local_validation/
├── render_archive_locally.py    SAPIEN 渲染 6 个 first/mid/last frames + 写 archive json
├── run_e2e_local.py             跑 streaming test_e2e_door 用本地 inputs
├── render_urdf_autofit.py       渲染 emit URDF 在 4 个 q 值 (auto-fit camera)
└── README.md                    OPENAI_API_KEY 注意事项 + 运行说明

~/.yifeng/VLM_Planning_for_Articulated_Manipulation/experiments/   (gitignored)
├── drawer_1778245284/    run1 (8×1.5s)  失败案例
└── drawer_1778246277/    run2 (15×2s)   成功案例
    ├── README.md
    ├── urdf/             cabinet_drawer_rgbd.urdf + meshes_*
    ├── viz/              15 张 RGB+GT-mask overlay PNG
    ├── urdf_renders/     4 张 q=0/33/66/100 渲染
    ├── state/            joint.json + per_part/* (Phase C/D/E 完整决策)
    ├── phase_a_work/     8/15 帧 raw RGB+depth+c2w
    └── logs/             4 个 server log 完整副本
```

---

## 五、下一步候选路径（按价值/成本排）

| 路径 | 价值 | 成本 | 描述 |
|---|---|---|---|
| **A. 修瓶颈 ② sidecar moving-part 动态同步** | ★★★ | 1 hr | 通过 ZMQ action 元数据让 sidecar 在 runtime 跟着 ActionPlanner 走；任意 task 自动 align |
| B. Stage-aware ingest 触发 (plan 方案 A) | ★★ | 30 min | client 只在 Pull_Linear/Pull_Arc 期间 ingest，避免浪费早期 frame |
| C. Multi-view RGB-D 采集（解决 ⑤ mesh 残破） | ★★★ | 2-3 hr | 让相机绕 cabinet 转或加多个相机；TSDF 才能填充 unseen 表面 |
| D. SAM3 prompt 调优 / 替换 Grounded-SAM2 | ★★ | 2-4 hr | 让真 SAM3 mask 跟踪不在 frame 3+ 跟丢，去掉 GT-mask 旁路 |
| E. 修 Phase C front-edge p95 → 用 3D centroid disp | ★ | 1 hr | 改 reconstruction_activeperception/phase_c_joint.py |
| F. URDF axis sign 自动 flip 到 panel_normal 方向 | ★ | 15 min | 后处理小补丁 |

**我的推荐：先做 A**——它解决瓶颈 ②，是 sidecar 真正"通用化、不依赖手动对齐"的唯一一步。其他改进都建立在 A 之上才有意义（比如 B / D 改进的都是单 task 的细节，但如果 ② 没修，下次另一种 task instruction 又要重新手动对齐）。

---

## 六、关键 lessons learned（写到 memory 的）

- **Open3D 0.18 ScalableTSDFVolume.integrate() 在 Ubuntu 24.04 + Py3.11 + RTX 5090 segfaults**；必须 0.19+；`faulthandler.enable()` 是隐藏信号 segfault 的必备工具
- **CUDA + asyncio + 多进程**：sidecar SAM3 模型 load 必须在 uvicorn main thread（startup hook），否则 worker thread 触发 CUDA primary context 损坏
- **client 同步 HTTP 调用会阻塞 SAPIEN 主循环** → 一定要 fire-and-forget
- **Phase D VLM 在 streaming 已经被 ingest_frame 调用**；之前认为没调是因为 OPENAI_API_KEY 没设
- **VLM 看图选 handle 不可控**；同一 USER_INSTRUCTION 跨 run 给不同结果（gpt-4o temperature=0.1 但非 0）→ 必须三方对齐（instruction / VLM hardcoded fallback / sidecar PARTS）
- **Phase C 用 OBB front-edge p95**，对沿相机视线方向的运动敏感于 mask shape noise；多帧采样能稀释 noise
- **单视角 RGB-D TSDF 重建只能恢复"被看到的"那部分几何**；mesh 完整性需要多视角
EOF
)"
echo "wrote SESSION_SUMMARY_2026-05-08.zh.md"
wc -l /home/harvardair/.yifeng/VLM_Planning_for_Articulated_Manipulation/SESSION_SUMMARY_2026-05-08.zh.md