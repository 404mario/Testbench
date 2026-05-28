#!/usr/bin/env python3
"""Aggregate per-node + cluster results into aggregated.json + report.md.

Called by run_72gpu_full.sh after raw tests finish. Argv 1 is the results dir
(typically results_72gpu/<DATE>/).

Per-node aggregation:
  - gemm:        re-parse gemm_*.log (the result JSON only keeps the last dtype)
  - stream:      stream_result.json  (kept by binary, has all 4 ops)
  - nvbandwidth: nvbandwidth_result.json (kept, has all tests in one run)

Cluster aggregation:
  - cluster/<tool>.log:  awk peak busbw column, scrape "Out of bounds" wrong count
"""
import json, os, re, statistics, sys

if len(sys.argv) < 2:
    sys.exit("usage: aggregate_72gpu.py <results_dir>")

RES = sys.argv[1]
PER = os.path.join(RES, "per_node")
CLU = os.path.join(RES, "cluster")

# ---------------- per-node ----------------
gemm = {}
stream = {}
nvb = {}

for node in sorted(os.listdir(PER)):
    nd = os.path.join(PER, node)
    # gemm: parse each gemm_<dtype>.log for "Perf: X TFLOPS"
    for fn in os.listdir(nd):
        m = re.match(r'gemm_(\w+)\.log$', fn)
        if not m: continue
        dt = m.group(1)
        with open(os.path.join(nd, fn)) as f:
            for line in f:
                m2 = re.search(r'Perf:\s*([\d.]+)\s*TFLOPS', line)
                if m2: gemm.setdefault(dt, []).append(float(m2.group(1)))
    # stream: stream_result.json -> entries with metrics.bw_gb_s
    p = os.path.join(nd, "stream_result.json")
    if os.path.exists(p):
        with open(p) as f:
            for e in json.load(f):
                t = e.get('test_name')
                # try multiple possible keys defensively
                m = e.get('metrics', {})
                bw = m.get('bw_gb_s') or m.get('measured_bw_gb_s') or m.get('bandwidth_gb_s') or m.get('average_bw_gb_s')
                if t and bw is not None: stream.setdefault(t, []).append(bw)
    # nvbandwidth
    p = os.path.join(nd, "nvbandwidth_result.json")
    if os.path.exists(p):
        with open(p) as f:
            for e in json.load(f):
                t = e.get('test_name')
                m = e.get('metrics', {})
                bw = m.get('average_bw_gb_s') or m.get('avg_bw_gb_s') or m.get('bw_gb_s')
                if t and bw is not None: nvb.setdefault(t, []).append(bw)

def stats(vals):
    if not vals: return None
    return {
        'n': len(vals),
        'min': min(vals),
        'mean': statistics.mean(vals),
        'median': statistics.median(vals),
        'max': max(vals),
        'stddev': statistics.stdev(vals) if len(vals) > 1 else 0.0,
    }

# ---------------- cluster ----------------
cluster = {}
if os.path.isdir(CLU):
    for fn in sorted(os.listdir(CLU)):
        if not fn.endswith('.log'): continue
        tool = fn[:-4]
        peak = None
        avg = None
        wrong = None
        with open(os.path.join(CLU, fn)) as f:
            for line in f:
                m = re.match(r'\s*\d+\s+\d+\s+\w+\s+\w+\s+\S+\s+\S+\s+\S+\s+(\S+)', line)
                if m:
                    try:
                        v = float(m.group(1))
                        if peak is None or v > peak: peak = v
                    except ValueError: pass
                if 'Avg bus bandwidth' in line:
                    try: avg = float(line.strip().split()[-1])
                    except: pass
                if 'Out of bounds' in line:
                    parts = line.split()
                    try: wrong = int(parts[parts.index('values') + 2])
                    except: pass
        cluster[tool] = {'peak_busbw_gb_s': peak, 'avg_busbw_gb_s': avg, 'wrong': wrong}

# ---------------- write ----------------
out = {
    'per_node': {
        'gemm': {dt: stats(v) for dt, v in gemm.items()},
        'stream': {t: stats(v) for t, v in stream.items()},
        'nvbandwidth': {t: stats(v) for t, v in nvb.items()},
    },
    'cluster_72rank': cluster,
}
with open(os.path.join(RES, 'aggregated.json'), 'w') as f:
    json.dump(out, f, indent=2)
print(f"wrote {os.path.join(RES, 'aggregated.json')}")

# ---------------- report.md ----------------
lines = [f"# 72-GPU NVL72 test report — {os.path.basename(RES)}", ""]
lines.append("## Per-node (72 GPU aggregate)")
lines.append("")
lines.append("### GEMM (TFLOPS)")
lines.append("| dtype | N | min | mean | median | max | stddev |")
lines.append("|---|---:|---:|---:|---:|---:|---:|")
for dt in ['fp64','fp32','tf32','bf16','fp16','fp8_e4m3','fp8_e5m2','int8']:
    s = out['per_node']['gemm'].get(dt)
    if not s: continue
    lines.append(f"| {dt} | {s['n']} | {s['min']:.2f} | {s['mean']:.2f} | {s['median']:.2f} | {s['max']:.2f} | {s['stddev']:.2f} |")

lines += ["", "### STREAM (GB/s)", "| test | N | min | mean | median | max |", "|---|---:|---:|---:|---:|---:|"]
for t in ['Copy','Scale','Add','Triad']:
    s = out['per_node']['stream'].get(t)
    if not s: continue
    lines.append(f"| {t} | {s['n']} | {s['min']:.2f} | {s['mean']:.2f} | {s['median']:.2f} | {s['max']:.2f} |")

lines += ["", "### nvbandwidth (per-node avg GB/s)", "| test | N | min | mean | max |", "|---|---:|---:|---:|---:|"]
for t in sorted(out['per_node']['nvbandwidth'].keys()):
    s = out['per_node']['nvbandwidth'][t]
    lines.append(f"| {t} | {s['n']} | {s['min']:.2f} | {s['mean']:.2f} | {s['max']:.2f} |")

lines += ["", "## Cluster 72-rank NCCL collectives", "| collective | peak busbw GB/s | avg busbw GB/s | wrong |", "|---|---:|---:|---:|"]
for tool in ['all_reduce','alltoall','all_gather','broadcast','reduce','reduce_scatter','sendrecv']:
    c = cluster.get(tool, {})
    p = c.get('peak_busbw_gb_s')
    a = c.get('avg_busbw_gb_s')
    w = c.get('wrong')
    lines.append(f"| {tool} | {p if p is not None else 'N/A'} | {a if a is not None else 'N/A'} | {w if w is not None else '?'} |")

with open(os.path.join(RES, 'report.md'), 'w') as f:
    f.write('\n'.join(lines) + '\n')
print(f"wrote {os.path.join(RES, 'report.md')}")
