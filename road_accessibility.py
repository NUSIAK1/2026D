"""Road/DEM exposure and service-zone ground accessibility (read-only inputs).

Run from any directory with Python + numpy, pandas, Pillow and openpyxl.
Outputs go to 结果/道路可达性先验. Existing Q1/Q2 results are never opened for writing.
"""

from __future__ import annotations

import csv
import heapq
import json
import math
from collections import defaultdict
from pathlib import Path

import numpy as np
import pandas as pd
from PIL import Image, ImageDraw, ImageFont


ROOT = Path(__file__).resolve().parent.parent
GEO = ROOT / "原始题目信息/数据/镇龙乡地理空间数据/镇龙乡及周边地理数据"
BASE = ROOT / "原始题目信息/数据/无人机应急物资运输基础数据"
OUT = ROOT / "结果/道路可达性先验"
SLOPE_DEG = 30.0
WATER_M = 100.0
SAMPLE_M = 30.0
MAX_SNAP_M = 300.0  # 10 nominal DEM cells: beyond this, mapped-road access is unavailable
EXCLUDED_ROAD_TYPES = {"在建道路", "人行步道", "步行街", "小径"}


def write_csv(path: Path, rows: list[dict]):
    if not rows:
        raise ValueError(f"No rows for {path}")
    with path.open("w", encoding="utf-8-sig", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=list(rows[0]))
        writer.writeheader()
        writer.writerows(rows)


def xy(lon, lat, lat0):
    return np.asarray(lon) * (111_320 * math.cos(math.radians(lat0))), np.asarray(lat) * 111_320


def load_nodes():
    raw = pd.read_excel(BASE / "调度中心与服务区.xlsx", sheet_name="数据", header=None)
    rows = []
    for _, r in raw.iterrows():
        ident = str(r.iloc[0]).strip()
        if ident == "O01" or (ident.startswith("S") and len(ident) == 4 and ident[1:].isdigit()):
            rows.append({"id": ident, "name": str(r.iloc[1]), "lon": float(r.iloc[2]),
                         "lat": float(r.iloc[3]), "population": int(r.iloc[5]) if ident != "O01" else None})
    assert len(rows) == 16 and rows[0]["id"] == "O01"
    return rows


def load_dem():
    path = GEO / "数字高程模型数据（DEM）/镇龙乡及周边30米DEM.tif"
    with Image.open(path) as im:
        z = np.array(im, dtype=np.float32)
        scale = im.tag_v2[33550]
        tie = im.tag_v2[33922]
    z[z <= -32767] = np.nan
    return z, float(tie[3]), float(tie[4]), float(scale[0]), float(scale[1])


def rasterize_water(shape, lon0, lat0, dlon, dlat):
    mask = Image.new("1", (shape[1], shape[0]), 0)
    draw = ImageDraw.Draw(mask)
    counts = {}
    for folder, key, is_polygon in [("水系（线）", "水系要素编号", False),
                                    ("水体（面）", "水体要素编号", True)]:
        data = pd.read_csv(next((GEO / folder).glob("*.csv")))
        counts[folder] = int(data[key].nunique())
        group_cols = [key, "多边形编号", "环编号"] if is_polygon else [key]
        data = data.sort_values(group_cols + ["点序号"])
        for _, group in data.groupby(group_cols, sort=False):
            pts = [((float(a) - lon0) / dlon, (lat0 - float(b)) / dlat)
                   for a, b in zip(group["经度"], group["纬度"])]
            if len(pts) > 1:
                if is_polygon and len(pts) > 2:
                    draw.polygon(pts, fill=1)
                else:
                    draw.line(pts, fill=1, width=1)
    return np.asarray(mask, dtype=bool), counts


def graph_from_roads(lat0):
    src = next((GEO / "道路").glob("*.csv"))
    road = pd.read_csv(src).sort_values(["道路要素编号", "点序号"])
    road = road.loc[~road["道路类型"].isin(EXCLUDED_ROAD_TYPES)].copy()
    ids = {}
    coords = []
    edges = []
    adj = defaultdict(list)
    for rid, g in road.groupby("道路要素编号", sort=False):
        series = list(zip(g["经度"].astype(float), g["纬度"].astype(float)))
        road_type = str(g["道路类型"].iloc[0])
        for a, b in zip(series[:-1], series[1:]):
            if a == b:
                continue
            pair = []
            for point in (a, b):
                if point not in ids:
                    ids[point] = len(coords)
                    coords.append(point)
                pair.append(ids[point])
            ax, ay = xy(a[0], a[1], lat0)
            bx, by = xy(b[0], b[1], lat0)
            length = float(math.hypot(bx - ax, by - ay))
            if length == 0:
                continue
            eid = len(edges)
            edges.append({"edge_id": eid, "road_id": rid, "road_type": road_type,
                          "a": pair[0], "b": pair[1], "length_m": length,
                          "lon_a": a[0], "lat_a": a[1], "lon_b": b[0], "lat_b": b[1],
                          "x_a": ax, "y_a": ay, "x_b": bx, "y_b": by})
            adj[pair[0]].append((pair[1], eid))
            adj[pair[1]].append((pair[0], eid))
    return road, coords, edges, adj


def nearest_edges(nodes, edges, lat0):
    ax = np.array([e["x_a"] for e in edges]); ay = np.array([e["y_a"] for e in edges])
    bx = np.array([e["x_b"] for e in edges]); by = np.array([e["y_b"] for e in edges])
    vx, vy = bx - ax, by - ay
    denom = vx * vx + vy * vy
    result = []
    for n in nodes:
        x, y = xy(n["lon"], n["lat"], lat0)
        t = np.clip(((x - ax) * vx + (y - ay) * vy) / denom, 0, 1)
        d = np.hypot(x - (ax + t * vx), y - (ay + t * vy))
        i = int(np.argmin(d))
        result.append({"edge_id": i, "fraction": float(t[i]), "snap_m": float(d[i])})
    return result


def dijkstra(adj, edges, source, blocked=None):
    distance = {source: 0.0}
    parent = {}
    queue = [(0.0, source)]
    while queue:
        d, u = heapq.heappop(queue)
        if d != distance[u]:
            continue
        for v, eid in adj[u]:
            if blocked is not None and blocked[eid]:
                continue
            nd = d + edges[eid]["length_m"]
            if nd < distance.get(v, math.inf):
                distance[v] = nd
                parent[v] = (u, eid)
                heapq.heappush(queue, (nd, v))
    return distance, parent


def route_to_edge(adj, edges, origin, target, blocked=None):
    """Shortest route from a point on an edge to another point on an edge."""
    oe, te = edges[origin["edge_id"]], edges[target["edge_id"]]
    if blocked is not None and (blocked[origin["edge_id"]] or blocked[target["edge_id"]]):
        return math.inf, []
    targets = [(oe["a"], origin["fraction"]), (oe["b"], 1 - origin["fraction"])]
    ends = [(te["a"], target["fraction"]), (te["b"], 1 - target["fraction"])]
    best = (math.inf, [])
    for start, start_share in targets:
        dist, parent = dijkstra(adj, edges, start, blocked)
        for stop, end_share in ends:
            cost = start_share * oe["length_m"] + dist.get(stop, math.inf) + end_share * te["length_m"]
            if cost < best[0]:
                path = []
                node = stop
                while node != start:
                    previous, eid = parent[node]
                    path.append((eid, 1.0))
                    node = previous
                path.reverse()
                if start_share > 0:
                    path.insert(0, (origin["edge_id"], start_share))
                if end_share > 0:
                    path.append((target["edge_id"], end_share))
                best = cost, path
    if origin["edge_id"] == target["edge_id"] and (blocked is None or not blocked[origin["edge_id"]]):
        direct = abs(origin["fraction"] - target["fraction"]) * oe["length_m"]
        if direct < best[0]:
            best = direct, [(origin["edge_id"], abs(origin["fraction"] - target["fraction"]))]
    return best


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    nodes = load_nodes()
    lat0 = sum(n["lat"] for n in nodes) / len(nodes)
    z, lon0, north, dlon, dlat = load_dem()
    dx = dlon * 111_320 * math.cos(math.radians(lat0))
    dy = dlat * 111_320
    z_work = np.nan_to_num(z, nan=float(np.nanmedian(z)))
    gy, gx = np.gradient(z_work, dy, dx)
    slope = np.degrees(np.arctan(np.hypot(gx, gy)))
    water, water_counts = rasterize_water(z.shape, lon0, north, dlon, dlat)
    road, coords, edges, adj = graph_from_roads(lat0)
    snapped = nearest_edges(nodes, edges, lat0)

    # One midpoint sample per <=30 m of road. Local water-mask search is bounded
    # by 100 m, so it does not impose any hydrological or failure probability model.
    for e in edges:
        count = max(1, math.ceil(e["length_m"] / SAMPLE_M))
        t = (np.arange(count) + 0.5) / count
        lon = e["lon_a"] + t * (e["lon_b"] - e["lon_a"])
        lat = e["lat_a"] + t * (e["lat_b"] - e["lat_a"])
        col = np.rint((lon - lon0) / dlon).astype(int)
        row = np.rint((north - lat) / dlat).astype(int)
        ok = (row >= 0) & (row < z.shape[0]) & (col >= 0) & (col < z.shape[1])
        ok_idx = np.flatnonzero(ok)
        ok[ok_idx] &= np.isfinite(z[row[ok_idx], col[ok_idx]])
        steep = np.zeros(count, dtype=bool)
        wet = np.zeros(count, dtype=bool)
        steep[ok] = slope[row[ok], col[ok]] >= SLOPE_DEG
        r, c = row[ok], col[ok]
        for dr in range(-math.ceil(WATER_M / dy), math.ceil(WATER_M / dy) + 1):
            for dc in range(-math.ceil(WATER_M / dx), math.ceil(WATER_M / dx) + 1):
                if math.hypot(dr * dy, dc * dx) > WATER_M:
                    continue
                rr, cc = r + dr, c + dc
                valid = (rr >= 0) & (rr < z.shape[0]) & (cc >= 0) & (cc < z.shape[1])
                sub = np.zeros(len(r), dtype=bool)
                sub[valid] = water[rr[valid], cc[valid]]
                wet[ok] |= sub
        e["sample_count"] = count
        e["valid_fraction"] = float(ok.mean())
        e["steep_fraction"] = float(np.mean(steep[ok])) if ok.any() else math.nan
        e["water_fraction"] = float(np.mean(wet[ok])) if ok.any() else math.nan
        e["dual_fraction"] = float(np.mean(steep[ok] & wet[ok])) if ok.any() else math.nan
        e["exposed_fraction"] = float(np.mean(steep[ok] | wet[ok])) if ok.any() else math.nan
        e["high_risk"] = bool(ok.any() and np.mean(steep & wet) >= 0.5)

    edge_rows = []
    for e in edges:
        edge_rows.append({k: e[k] for k in ["edge_id", "road_id", "road_type", "lon_a", "lat_a", "lon_b", "lat_b",
                                           "length_m", "sample_count", "valid_fraction", "steep_fraction",
                                           "water_fraction", "dual_fraction", "exposed_fraction", "high_risk"]})
    write_csv(OUT / "道路分段风险.csv", edge_rows)

    blocked = [e["high_risk"] for e in edges]
    results = []
    route_edges = set()
    for n, snap in zip(nodes[1:], snapped[1:]):
        mapped = snap["snap_m"] <= MAX_SNAP_M and snapped[0]["snap_m"] <= MAX_SNAP_M
        length, path = route_to_edge(adj, edges, snapped[0], snap) if mapped else (math.inf, [])
        detour, _ = route_to_edge(adj, edges, snapped[0], snap, blocked) if mapped else (math.inf, [])
        route_edges.update(eid for eid, _ in path)
        x0, y0 = xy(nodes[0]["lon"], nodes[0]["lat"], lat0)
        x1, y1 = xy(n["lon"], n["lat"], lat0)
        straight = float(math.hypot(x1 - x0, y1 - y0))
        known = sum(edges[i]["length_m"] * share * edges[i]["valid_fraction"] for i, share in path)
        total = sum(edges[i]["length_m"] * share for i, share in path)
        exposed = sum(edges[i]["length_m"] * share * edges[i]["exposed_fraction"] for i, share in path if math.isfinite(edges[i]["exposed_fraction"]))
        steep = sum(edges[i]["length_m"] * share * edges[i]["steep_fraction"] for i, share in path if math.isfinite(edges[i]["steep_fraction"]))
        wet = sum(edges[i]["length_m"] * share * edges[i]["water_fraction"] for i, share in path if math.isfinite(edges[i]["water_fraction"]))
        dual = sum(edges[i]["length_m"] * share * edges[i]["dual_fraction"] for i, share in path if math.isfinite(edges[i]["dual_fraction"]))
        results.append({"服务区编号": n["id"], "服务区名称": n["name"], "保障人口_人": n["population"],
                        "最近道路距离_m": round(snap["snap_m"], 1),
                        "路网匹配状态": "有效" if mapped else "超出300m匹配范围",
                        "路网最短距离_km": round(length / 1000, 3) if math.isfinite(length) else None,
                        "直线距离_km": round(straight / 1000, 3), "道路绕行系数": round(length / straight, 2) if math.isfinite(length) else None,
                        "路径DEM有效覆盖率": round(known / total, 4) if total else None,
                        "路径陡坡暴露率": round(steep / known, 4) if known else None,
                        "路径临水暴露率": round(wet / known, 4) if known else None,
                        "路径陡坡且临水率": round(dual / known, 4) if known else None,
                        "路径任一风险暴露率": round(exposed / known, 4) if known else None,
                        "高风险段封闭后绕行_km": round(detour / 1000, 3) if math.isfinite(detour) else None,
                        "高风险段封闭后状态": "未评估" if not mapped else ("可绕行" if math.isfinite(detour) else "已映射路网不连通")})

    demand = pd.read_excel(BASE / "物资需求与配送时限.xlsx", sheet_name="数据")
    demand = demand[demand["服务区编号"].isin([n["id"] for n in nodes[1:]])]
    for row in results:
        d = demand[demand["服务区编号"] == row["服务区编号"]]
        row["原始优先系数_按箱加权均值"] = round(float(np.average(d["应急优先系数"], weights=d["总需求箱数"])), 3)
        row["原始医疗优先系数"] = int(d.loc[d["物资类型"] == "医疗物资", "应急优先系数"].iloc[0])
    write_csv(OUT / "服务区道路可达性.csv", results)
    write_csv(OUT / "易损路段清单.csv", [row for row in edge_rows if row["high_risk"]])

    draw_map(z, water, nodes, edges, route_edges, lon0, north, dlon, dlat)
    diagnostics = {"road_features_used": int(road["道路要素编号"].nunique()), "road_edges": len(edges),
                   "road_length_km": round(sum(e["length_m"] for e in edges) / 1000, 2),
                   "high_risk_length_km": round(sum(e["length_m"] for e in edges if e["high_risk"]) / 1000, 2),
                   "water_feature_counts": water_counts,
                   "dem_valid_fraction": round(float(np.isfinite(z).mean()), 5),
                   "mapped_services": sum(r["路网匹配状态"] == "有效" for r in results),
                   "high_risk_edges": sum(blocked),
                   "max_snap_m": round(max(s["snap_m"] for s in snapped), 1)}
    (OUT / "校核.json").write_text(json.dumps(diagnostics, ensure_ascii=False, indent=2), encoding="utf-8")
    print(json.dumps(diagnostics, ensure_ascii=False, indent=2))
    for r in results:
        print(r["服务区编号"], r["最近道路距离_m"], r["路网最短距离_km"], r["路径任一风险暴露率"], r["高风险段封闭后状态"])


def draw_map(z, water, nodes, edges, route_edges, lon0, north, dlon, dlat):
    # Geographic axes remain EPSG:4326; the raster is resized only for display.
    lo_lon = min(n["lon"] for n in nodes) - 0.02
    hi_lon = max(n["lon"] for n in nodes) + 0.02
    lo_lat = min(n["lat"] for n in nodes) - 0.02
    hi_lat = max(n["lat"] for n in nodes) + 0.02
    box = (max(0, int((lo_lon - lon0) / dlon)), max(0, int((north - hi_lat) / dlat)),
           min(z.shape[1], int((hi_lon - lon0) / dlon)), min(z.shape[0], int((north - lo_lat) / dlat)))
    relief = z[box[1]:box[3], box[0]:box[2]]
    low, high = np.nanpercentile(relief, [3, 97])
    gray = np.uint8(np.clip((np.nan_to_num(relief, nan=low) - low) / (high - low), 0, 1) * 100 + 130)
    rgb = np.stack([gray, gray, gray], axis=2)
    rgb[water[box[1]:box[3], box[0]:box[2]]] = (107, 164, 190)
    im = Image.fromarray(rgb).resize(((box[2]-box[0])*2, (box[3]-box[1])*2))
    draw = ImageDraw.Draw(im)
    def px(lon, lat):
        return ((lon - lon0) / dlon - box[0]) * 2, ((north - lat) / dlat - box[1]) * 2
    for e in edges:
        a, b = px(e["lon_a"], e["lat_a"]), px(e["lon_b"], e["lat_b"])
        if e["high_risk"]:
            color, width = "#b22222", 3
        elif e["exposed_fraction"] >= 0.5:
            color, width = "#d8932e", 2
        elif e["edge_id"] in route_edges:
            color, width = "#225c55", 2
        else:
            color, width = "#cccccc", 1
        draw.line((a, b), fill=color, width=width)
    try:
        font = ImageFont.truetype("C:/Windows/Fonts/arial.ttf", 22)
    except OSError:
        font = ImageFont.load_default()
    for n in nodes:
        x, y = px(n["lon"], n["lat"])
        r = 6 if n["id"] == "O01" else 4
        draw.ellipse((x-r, y-r, x+r, y+r), fill="#101820" if n["id"] == "O01" else "#ffffff", outline="#101820", width=2)
        draw.text((x+6, y-12), n["id"], fill="#111111", font=font, stroke_width=2, stroke_fill="#ffffff")
    im.save(OUT / "道路风险地图_论文版.png")
    try:
        label_font = ImageFont.truetype("C:/Windows/Fonts/msyh.ttc", 23)
        small_font = ImageFont.truetype("C:/Windows/Fonts/msyh.ttc", 18)
    except OSError:
        label_font = small_font = ImageFont.load_default()
    canvas = Image.new("RGB", (im.width, im.height + 100), "#ffffff")
    canvas.paste(im, (0, 65))
    d = ImageDraw.Draw(canvas)
    d.text((18, 10), "道路陡坡与临水暴露筛查", font=label_font, fill="#17242b")
    d.text((18, 38), "道路和地形源数据：WGS 84；仅显示服务区周边范围", font=small_font, fill="#46545b")
    yy = im.height + 78
    xx = 18
    for color, label in [("#b22222", "陡坡且临水"), ("#d8932e", "任一因子暴露≥50%"),
                         ("#225c55", "有效匹配服务区的最短路径"), ("#cccccc", "其他道路")]:
        d.line((xx, yy, xx+34, yy), fill=color, width=5)
        d.text((xx+42, yy-11), label, font=small_font, fill="#263238")
        xx += 42 + int(d.textlength(label, font=small_font)) + 26
    canvas.save(OUT / "道路风险与服务区.png")


if __name__ == "__main__":
    main()
