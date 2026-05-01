"""RGB-D streaming dump for SAM3D ActivePerception integration.

env-driven, default off. Saves per-frame npz under <SAM3D_DUMP_DIR>/<run>/frames/
and a meta.json (intrinsics + conventions) at run root. Frames carry:
  rgb (HxWx3 uint8) | depth_m (HxW float32, positive meters)
  c2w (4x4 float64, OpenCV: cam +z forward, +x right, +y down) = inv(get_extrinsic_matrix)
  cam_pos_world (3,) | step_idx (int64) | tag (<U16, e.g. "" or "final")

Convention chosen to match SAM3D pinhole unproject (rgbd_phase_b_obb.py:59 and
pipeline/streaming/ingest_frame.py:73). Do NOT use cam.get_model_matrix() — that's
OpenGL.

Env vars:
  SAM3D_DUMP_DIR             enable dump if set; frames go under <dir>/<run_tag>/
  SAM3D_DUMP_EVERY_K_STEPS   dump 1 frame per K policy steps (default 20)
  SAM3D_DUMP_RUN_TAG         override per-run subdir name; defaults to "<hint>_<ts>"
"""

import json
import os
import time

import numpy as np


class RGBDDumper:
    def __init__(self, run_tag_hint="run"):
        self.enabled = bool(os.environ.get("SAM3D_DUMP_DIR", "").strip())
        if not self.enabled:
            self.run_dir = None
            return
        root = os.environ["SAM3D_DUMP_DIR"].strip()
        tag = os.environ.get("SAM3D_DUMP_RUN_TAG", "").strip()
        if not tag:
            tag = f"{run_tag_hint}_{time.strftime('%Y%m%d_%H%M%S')}"
        self.run_dir = os.path.join(root, tag)
        self.frames_dir = os.path.join(self.run_dir, "frames")
        os.makedirs(self.frames_dir, exist_ok=True)
        try:
            self.every_k = max(1, int(os.environ.get("SAM3D_DUMP_EVERY_K_STEPS", "20")))
        except ValueError:
            self.every_k = 20
        self._meta_written = False
        self._dumped = 0
        print(f"[RGBDDumper] enabled -> {self.run_dir} (every {self.every_k} policy steps)")

    def write_meta_once(self, cam, cabinet_id):
        if not self.enabled or self._meta_written:
            return
        try:
            K = cam.get_intrinsic_matrix().astype(np.float64).tolist()
        except Exception:
            K = None
        meta = {
            "cabinet_id": str(cabinet_id),
            "width": int(cam.get_width()) if hasattr(cam, "get_width") else None,
            "height": int(cam.get_height()) if hasattr(cam, "get_height") else None,
            "fovy_rad": float(cam.fovy),
            "intrinsic_matrix_3x3": K,
            "c2w_convention": "opencv (cam +z forward, +x right, +y down) = inv(get_extrinsic_matrix)",
            "depth_units": "meters (positive, depth = -pos_buf.z)",
            "every_k_policy_steps": self.every_k,
        }
        with open(os.path.join(self.run_dir, "meta.json"), "w") as f:
            json.dump(meta, f, indent=2)
        self._meta_written = True

    def should_dump(self, step_idx):
        if not self.enabled:
            return False
        if step_idx == 1:  # always grab the closed-state snapshot at first action
            return True
        return step_idx > 0 and (step_idx % self.every_k == 0)

    @staticmethod
    def c2w_from_camera(cam):
        """OpenCV c2w (4x4 float64) from SAPIEN camera (3x4 OpenCV w2c → padded → inv)."""
        extr = np.asarray(cam.get_extrinsic_matrix(), dtype=np.float64)
        w2c = np.eye(4, dtype=np.float64); w2c[:3] = extr
        return np.linalg.inv(w2c)

    def dump(self, step_idx, rgb, depth_m, c2w, cam_pos_world, tag=""):
        if not self.enabled:
            return
        idx = self._dumped
        path = os.path.join(self.frames_dir, f"{idx:06d}.npz")
        np.savez_compressed(
            path,
            rgb=rgb.astype(np.uint8),
            depth_m=depth_m.astype(np.float32),
            c2w=np.asarray(c2w, dtype=np.float64),
            cam_pos_world=np.asarray(cam_pos_world, dtype=np.float64),
            step_idx=np.int64(step_idx),
            tag=np.array(tag, dtype="<U16"),
        )
        self._dumped += 1

    def dump_final(self, step_idx, scene, cam):
        """Capture a 'final' frame on shutdown (after the manipulation finishes)."""
        if not self.enabled:
            return
        try:
            scene.update_render()
            cam.take_picture()
            pos_buf = cam.get_picture("Position")
            col_buf = cam.get_picture("Color")
            rgb = (col_buf[:, :, :3] * 255).astype(np.uint8)
            depth = (-pos_buf[:, :, 2]).astype(np.float32)
            c2w = self.c2w_from_camera(cam)
            cam_pos = np.array(cam.entity.get_pose().p, dtype=np.float64)
            self.dump(step_idx, rgb, depth, c2w, cam_pos, tag="final")
            print(f"[RGBDDumper] dump_final captured at step {step_idx} "
                  f"(total frames: {self._dumped})")
        except Exception as e:
            print(f"[RGBDDumper] dump_final failed: {e}")
