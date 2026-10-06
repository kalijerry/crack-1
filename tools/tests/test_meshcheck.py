"""meshcheck.py 的单元测试：合成一个通道和两排货架的 LiDAR 网格（实物比地图偏 12 cm、高 2.3 m），看能不能量回来。"""
import json
import math
import struct
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools"))

import meshcheck  # noqa: E402

T0 = 1_700_000_000_000
PHI = 0.7                      # ARKit 坐标相对地图转了多少
A0 = (150.0, -80.0)            # 起点时刻的 ARKit (x, z)，cm
P0 = (500.0, 300.0)            # 起点地图坐标
SHIFT = 12.0                   # 实物货架比地图往 +x 偏 12 cm
HEIGHT = 2.3


def to_ar(p):
    dx, dy = p[0] - P0[0], p[1] - P0[1]
    c, s = math.cos(PHI), math.sin(PHI)
    return A0[0] + dx * c + dy * s, A0[1] - dx * s + dy * c          # R(−φ)


def write_map(path):
    els = [
        {"shapeType": "MapShelf", "code": "Shelf-001-01", "x": 300, "y": 200, "width": 120, "height": 2000, "rotation": 0},
        {"shapeType": "MapShelf", "code": "Shelf-002-01", "x": 580, "y": 200, "width": 120, "height": 2000, "rotation": 0},
        {"shapeType": "MapShelf", "code": "Virtual-Shelf-4-1-1", "x": 420, "y": 200, "width": 10, "height": 2000, "rotation": 0},
        {"shapeType": "MapCross", "code": "C", "lineWidth": 140, "points": [500, 200, 500, 2200]},
    ]
    Path(path).write_text(json.dumps({"code": "200", "success": True,
                                      "data": {"width": 1000, "height": 2400, "mapElementList": els}}))


def make_session(root):
    d = Path(root) / "survey_x"
    d.mkdir(parents=True)
    (d / "meta.json").write_text(json.dumps({"platform": "ios", "survey": True}))
    # 轨迹：沿通道中心从 y = 300 走到 2100，1.2 m/s，30 Hz
    pose = ["t_ms,x_m,y_m,z_m,qx,qy,qz,qw,tracking,limited_reason"]
    n = int((2100 - 300) / 120 * 30)
    for i in range(n + 1):
        p = (500.0, 300.0 + 1800.0 * i / n)
        a = to_ar(p)
        pose.append(f"{T0 + i * 33},{a[0] / 100:.4f},0,{a[1] / 100:.4f},0,0,0,1,2,0")
    (d / "arkit_pose.csv").write_text("\n".join(pose) + "\n")
    a_start, a_end = to_ar(P0), to_ar((500.0, 2100.0))
    t_end = T0 + n * 33
    (d / "anchors.csv").write_text("\n".join([
        "t_ms,kind,map_x_cm,map_y_cm,ar_x_cm,ar_z_cm,heading_rad,note",
        f"{T0},start,{P0[0]},{P0[1]},{a_start[0]:.1f},{a_start[1]:.1f},,",
        f"{T0 + 5},heading,{P0[0]},{P0[1]},{a_start[0]:.1f},{a_start[1]:.1f},0.0,",
        f"{t_end},reanchor,500,2100,{a_end[0]:.1f},{a_end[1]:.1f},,",
    ]) + "\n")
    # 网格：两排货架朝通道的面、货架顶面、地面
    verts = []
    def add(x, y, h):
        a = to_ar((x, y))
        verts.append((a[0] / 100, h - 1.3, a[1] / 100))
    for y in range(220, 2181, 5):
        for k in range(0, 47):
            h = k * 0.05
            add(420 + SHIFT, y, h)            # 左排货架的东面
            add(580 + SHIFT, y, h)            # 右排货架的西面
        for x in range(300, 421, 10):
            add(x + SHIFT, y, HEIGHT)          # 左排顶面
        for x in range(580, 701, 10):
            add(x + SHIFT, y, HEIGHT)          # 右排顶面
        for x in range(440, 571, 20):
            add(x, y, 0.0)                     # 地面
    header = (f"ply\nformat binary_little_endian 1.0\nelement vertex {len(verts)}\n"
              "property float x\nproperty float y\nproperty float z\nelement face 0\n"
              "property list uchar int vertex_indices\nend_header\n").encode()
    body = b"".join(struct.pack("<3f", *v) for v in verts)
    (d / "mesh.ply").write_bytes(header + body)
    return d


class MeshcheckTest(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="mesh_"))
        write_map(self.tmp / "map.json")

    def test_heights_and_shift_recovered(self):
        s = make_session(self.tmp)
        rep = meshcheck.run(self.tmp / "map.json", [s], self.tmp / "report.json")
        self.assertTrue((self.tmp / "report.json").exists())
        codes = {r["code"]: r for r in rep["shelves"]}
        self.assertEqual(set(codes), {"Shelf-001-01", "Shelf-002-01"})       # 虚拟货架不分析
        for r in codes.values():
            self.assertAlmostEqual(r["top_height_m"], HEIGHT, delta=0.1)
            self.assertAlmostEqual(r["shift_cm"], SHIFT, delta=4)
            self.assertAlmostEqual(r["shift_xy_cm"][0], SHIFT, delta=4)
            self.assertAlmostEqual(r["shift_xy_cm"][1], 0, delta=4)
        sm = rep["summary"]
        self.assertAlmostEqual(sm["height_median_m"], HEIGHT, delta=0.1)
        self.assertAlmostEqual(sm["mean_shift_xy_cm"][0], SHIFT, delta=4)

    def test_session_without_mesh_warns(self):
        s = make_session(self.tmp)
        (s / "mesh.ply").unlink()
        rep = meshcheck.run(self.tmp / "map.json", [s])
        self.assertTrue(rep["sessions"][0]["warnings"])
        self.assertEqual(rep["summary"]["shelves_analyzed"], 0)

    def test_standard_shelf_filter(self):
        shelves = meshcheck.standard_shelves(self.tmp / "map.json")
        self.assertEqual([s["code"] for s in shelves], ["Shelf-001-01", "Shelf-002-01"])
        # 左上角锚点：中心 = (300 + 60, 200 + 1000)
        self.assertAlmostEqual(shelves[0]["cx"], 360)
        self.assertAlmostEqual(shelves[0]["cy"], 1200)


if __name__ == "__main__":
    unittest.main()
