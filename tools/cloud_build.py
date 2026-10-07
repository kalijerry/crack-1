#!/usr/bin/env python3
"""云端融合建图（GitHub Actions 里跑）。

1. 从后台拉所有采集会话（zip），按会话里记的地图编号（meta.json 的 map_id）分组；purpose=test 的当测试会话；
2. 每张地图：拉地图 JSON（/api/maps/<id>，App 连上后台时会自动上传当前地图），读云端已有地图包里的名字、类型、地图朝向；
3. 会话和上次融合时一样就跳过；否则跑 hpass-build（多会话偏移联合求解 + 蓝牙 + 覆盖率 + 测试会话精度），
   上传地图包（版本 = 现在，盖过手机上生成的）和报告（/api/reports/build_<地图>_<时间>.json）。

环境变量：HPASS_URL（后台地址）、HPASS_TOKEN（口令）、HPASS_BUILD（hpass-build 可执行文件路径）、
MAP_ID（可选，只处理这一张）、FORCE=1（会话没变也重建）、DRY_RUN=1（只算、不上传）。会话数据只放在临时目录，不进仓库、不进 artifact。
"""
import io, json, os, struct, subprocess, sys, tempfile, time, urllib.parse, urllib.request, zipfile, zlib

URL = os.environ["HPASS_URL"].rstrip("/")
if not URL.startswith("http"):
    URL = "https://" + URL
TOKEN = os.environ["HPASS_TOKEN"]
BUILD = os.environ.get("HPASS_BUILD", "hpass-build")
ONLY = os.environ.get("MAP_ID", "").strip()
FORCE = os.environ.get("FORCE") == "1"
DRY = os.environ.get("DRY_RUN") == "1"          # 只算不上传


def req(path, method="GET", data=None, headers=None):
    h = {"Authorization": "Bearer " + TOKEN, "User-Agent": "hpass-cloud-build/1.0"}   # 默认的 Python UA 会被 Cloudflare 拦（403）
    h.update(headers or {})
    r = urllib.request.Request(URL + path, data=data, method=method, headers=h)
    with urllib.request.urlopen(r, timeout=300) as resp:
        return resp.read()


def get_json(path):
    return json.loads(req(path))


def package_meta(map_id):
    """云端已有地图包的说明（名字、类型、地图朝向）；没有返回 None"""
    try:
        raw = req("/api/packages/" + urllib.parse.quote(map_id))
    except urllib.error.HTTPError:
        return None
    d = zlib.decompress(raw, -15)                  # NSData .zlib = 不带头的 deflate
    assert d[:4] == b"HPMP"
    n = struct.unpack_from("<I", d, 6)[0]
    return json.loads(d[10:10 + n])


def main():
    work = tempfile.mkdtemp(prefix="hpass-")
    sessions = get_json("/api/sessions")
    print(f"后台有 {len(sessions)} 个会话")
    groups = {}                                     # map_id -> {"build": [...], "test": [...]}
    for o in sessions:
        name = o["key"].split("/", 1)[1]
        z = zipfile.ZipFile(io.BytesIO(req("/api/sessions/" + urllib.parse.quote(name))))
        z.extractall(work)
        metas = [n for n in z.namelist() if n.endswith("meta.json") and n.count("/") == 1]
        for m in metas:
            d = os.path.join(work, os.path.dirname(m))
            meta = json.load(open(os.path.join(work, m)))
            if not meta.get("survey") or not os.path.exists(os.path.join(d, "anchors.csv")):
                continue
            mid = meta.get("map_id") or ""
            if not mid:
                print(f"  跳过 {os.path.basename(d)}：旧版本会话，没记地图编号")
                continue
            g = groups.setdefault(mid, {"build": [], "test": []})
            g["test" if meta.get("purpose") == "test" else "build"].append(d)
    reports = get_json("/api/reports")
    for mid, g in sorted(groups.items()):
        if ONLY and mid != ONLY:
            continue
        print(f"\n== 地图 {mid}：建图 {len(g['build'])} 个、测试 {len(g['test'])} 个")
        if not g["build"]:
            continue
        names = sorted(os.path.basename(d) for d in g["build"] + g["test"])
        # 上次融合用的会话
        last = [r for r in reports if r["key"].startswith(f"reports/build_{mid}_")]
        if last and not FORCE:
            prev = get_json("/api/" + last[0]["key"])
            prev_names = sorted([s["name"] for s in prev.get("sessions", [])] + prev.get("testSessions", []))
            if prev_names == names:
                print("  会话没变，跳过")
                continue
        try:
            map_json = req("/api/maps/" + urllib.parse.quote(mid))
        except urllib.error.HTTPError:
            print("  后台没有这张地图的 JSON（用这张地图的手机连一次后台就会上传），跳过")
            continue
        map_path = os.path.join(work, f"map_{mid}.json")
        open(map_path, "wb").write(map_json)
        pm = package_meta(mid) or {}
        out = os.path.join(work, f"{mid}.hpmp")
        rep = os.path.join(work, f"{mid}.json")
        cmd = [BUILD, "--map", map_path, "--sessions", ",".join(g["build"]), "--id", mid,
               "--name", pm.get("name") or mid, "--kind", pm.get("kind") or "store", "--out", out, "--report", rep]
        if g["test"]:
            cmd += ["--test", ",".join(g["test"])]
        if pm.get("mapUpBearingDeg") is not None:
            cmd += ["--bearing", str(pm["mapUpBearingDeg"])]
        subprocess.run(cmd, check=True)
        report = json.load(open(rep))
        report["testSessions"] = sorted(os.path.basename(d) for d in g["test"])
        pkg = open(out, "rb").read()
        if DRY:
            print(f"  试运行：地图包 {len(pkg) // 1024} KB，不上传")
            continue
        hdr = {"Content-Type": "application/octet-stream", "X-Map-Name": urllib.parse.quote(report["name"]),
               "X-Map-Kind": pm.get("kind") or "store", "X-Map-Version": str(report["version"]),
               "X-Field-Cells": str(report["fieldCells"]), "X-Ble-Tags": str(report["bleTags"])}
        print(req("/api/packages/" + urllib.parse.quote(mid), "PUT", pkg, hdr).decode())
        stamp = time.strftime("%Y%m%d_%H%M%S", time.gmtime())
        req(f"/api/reports/build_{mid}_{stamp}.json", "PUT", json.dumps(report, ensure_ascii=False).encode(),
            {"Content-Type": "application/json"})
        print(f"  已上传地图包（{len(pkg) // 1024} KB）和报告")


if __name__ == "__main__":
    main()
