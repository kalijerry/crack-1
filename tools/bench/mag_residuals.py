"""地磁残差统计：标定跟踪档的观测噪声下限、残差相关长度、整体偏移估计。

输入是 hpass-eval --residuals 导出的 CSV（测试会话每 50 cm 一条：实测特征、地图在参考位置的均值 / 标准差）：

    hpass-eval --map map.json --build build --test test --residuals res.csv
    python -I -X utf8 tools/bench/mag_residuals.py res.csv

输出：每个分量扣掉会话整体偏移（中位数）后的残差分布和 Student-t（ν=4）尺度、不同噪声下限下 |z| 的中位数和 3σ 外比例、
残差沿路的自相关和积分相关长度（按更新次数）、开头一次 / 前 20 次读数估偏移的误差。
"""
import csv, math, statistics as st, sys
from collections import defaultdict
rows = defaultdict(list)
for r in csv.DictReader(open(sys.argv[1])):
    rows[r['session']].append(r)
C = ['total','vertical','horizontal']
def med(a): return st.median(a) if a else float('nan')
def pct(a,q):
    a=sorted(a); return a[min(int((len(a)-1)*q+0.5),len(a)-1)]
allr = {c: [] for c in C}; alls={c:[] for c in C}
seqs = []  # per session list of residual vectors (None when no map)
offerr = {c: [] for c in C}; offerr20 = {c: [] for c in C}
cov=0; n=0
for s, rs in rows.items():
    pts=[]
    for r in rs:
        n+=1
        if r['m_total']=='': pts.append(None); continue
        cov+=1
        f=[float(r['f_'+c]) for c in C]; m=[float(r['m_'+c]) for c in C]; sg=[float(r['s_'+c]) for c in C]
        pts.append((f,m,sg,int(r['t_ms'])))
    good=[p for p in pts if p]
    if len(good)<10: continue
    t0=int(rs[0]['t_ms'])
    off=[med([p[0][k]-p[1][k] for p in good]) for k in range(3)]
    for k,c in enumerate(C):
        offerr[c].append(abs((good[0][0][k]-good[0][1][k])-off[k]))
        offerr20[c].append(abs(med([p[0][k]-p[1][k] for p in good[:20]])-off[k]))
    seq=[]
    for p in pts:
        if p is None: seq.append(None); continue
        rr=[p[0][k]-off[k]-p[1][k] for k in range(3)]
        seq.append(rr)
        for k,c in enumerate(C): allr[c].append(rr[k]); alls[c].append(p[2][k])
    seqs.append(seq)
print(f"samples {n}, with map at truth {cov} ({cov/n:.0%}), sessions {len(seqs)}")
for c in C:
    a=[abs(x) for x in allr[c]]
    mad=med(a)
    print(f"{c:10s} resid |r| med {mad:.2f} P90 {pct(a,0.9):.2f} P99 {pct(a,0.99):.2f}  t4-scale {mad/0.741:.2f}  "
          f"map sigma med {med(alls[c]):.2f} P90 {pct(alls[c],0.9):.2f}  first-sample offset err med {med(offerr[c]):.2f} P90 {pct(offerr[c],0.9):.2f}  20-sample {med(offerr20[c]):.2f}/{pct(offerr20[c],0.9):.2f}")
    for fl in (1.5,3,4,5,6):
        z=[abs(x)/math.sqrt(s*s+fl*fl) for x,s in zip(allr[c],alls[c])]
        print(f"   floor {fl}: |z| med {med(z):.2f} (t4 expects 0.74)  >3: {sum(1 for v in z if v>3)/len(z):.0%} (t4 expects 5.5%)")
# autocorrelation vs lag (updates of 50 cm)
for k,c in enumerate(C):
    out=[]
    for lag in (1,2,3,4,6,8,12,16):
        xs=[];ys=[]
        for seq in seqs:
            for i in range(len(seq)-lag):
                if seq[i] and seq[i+lag]: xs.append(seq[i][k]); ys.append(seq[i+lag][k])
        mx=st.mean(xs); my=st.mean(ys)
        cv=sum((a-mx)*(b-my) for a,b in zip(xs,ys))/len(xs)
        out.append((lag, cv/ (st.pstdev(xs)*st.pstdev(ys))))
    print(c, ' '.join(f"{l}:{r:.2f}" for l,r in out))
# integrated autocorrelation time (sum over all lags until first <0.05)
for k,c in enumerate(C):
    s=1.0
    for lag in range(1,40):
        xs=[];ys=[]
        for seq in seqs:
            for i in range(len(seq)-lag):
                if seq[i] and seq[i+lag]: xs.append(seq[i][k]); ys.append(seq[i+lag][k])
        mx=st.mean(xs); my=st.mean(ys)
        r=sum((a-mx)*(b-my) for a,b in zip(xs,ys))/len(xs)/(st.pstdev(xs)*st.pstdev(ys))
        if r<0.05: break
        s+=2*r
    print(f"{c}: integrated autocorr time ~{s:.1f} updates (lag cut {lag})")
# cross-correlation between components
for a,b in ((0,1),(0,2),(1,2)):
    xs=[];ys=[]
    for seq in seqs:
        for p in seq:
            if p: xs.append(p[a]); ys.append(p[b])
    print(C[a],C[b],'corr',round(st.correlation(xs,ys),2))
