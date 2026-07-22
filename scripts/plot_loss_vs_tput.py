#!/usr/bin/env python3
"""
plot_loss_vs_tput.py  —  Loss vs UDP throughput + Real Effective Throughput plots.
Saves to ~/Desktop/plots/
"""
import csv, os, warnings
from pathlib import Path
from collections import defaultdict

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import matplotlib.ticker as ticker
import numpy as np

warnings.filterwarnings("ignore")

DATA   = Path("/tmp/ran_data2")
OUTDIR = Path(os.path.expanduser("~/Desktop/plots"))
OUTDIR.mkdir(parents=True, exist_ok=True)

plt.rcParams.update({
    "figure.facecolor":"#ffffff","axes.facecolor":"#f9fafb",
    "axes.edgecolor":"#cccccc","axes.grid":True,"grid.color":"#e5e7eb",
    "grid.linewidth":0.6,"font.family":"DejaVu Sans","font.size":10,
    "axes.titlesize":12,"axes.titleweight":"bold","axes.labelsize":10,
    "xtick.labelsize":8,"ytick.labelsize":9,"legend.fontsize":9,
    "lines.linewidth":1.8,"lines.markersize":5,
})
BLUE="#3b82d4"; GREEN="#22c55e"; ORANGE="#f97316"; RED="#ef4444"; PURPLE="#7c3aed"
RATES=[1,10,20,50,100,200,300,400,500]

def flt(v):
    try: return float(v)
    except: return None

rows=list(csv.DictReader(open(DATA/"udp_latency_all_ues.csv",errors="replace")))

pts=[]
for r in rows:
    if r["test_type"] not in ("udp_ramp","udp_ramp_retest","udp_ramp_fill"): continue
    uid=int(r["ue_id"]); rate=flt(r["rate_target_mbps"])
    tp=flt(r["throughput_mbps"]); ls=flt(r["pkt_loss_pct"]); jt=flt(r["jitter_ms"])
    if tp and tp>0 and rate is not None and ls is not None:
        real=tp*(1-ls/100)   # effective received throughput
        pts.append({"uid":uid,"rate":rate,"tput":tp,"loss":ls,"jitter":jt or 0,"real":real})

def save(fig,name):
    fig.savefig(OUTDIR/name,dpi=150,bbox_inches="tight")
    plt.close(fig)
    print(f"  ✓ {name}")

# ── P1: Sent vs Received vs Real — per rate (bar groups) ─────────────────────
print("P1: sent / received / real throughput per rate ...")
fig,ax=plt.subplots(figsize=(13,5))
w=0.28; x=np.arange(len(RATES))
sent=[r for r in RATES]                                          # target = sent
recv=[np.mean([p["tput"] for p in pts if int(p["rate"])==r]) for r in RATES]
real=[np.mean([p["real"] for p in pts if int(p["rate"])==r]) for r in RATES]
ax.bar(x-w,sent,width=w,color="#94a3b8",edgecolor="white",label="Target (sent) Mbps")
ax.bar(x,  recv,width=w,color=BLUE,     edgecolor="white",label="Reported throughput Mbps")
ax.bar(x+w,real,width=w,color=GREEN,    edgecolor="white",label="Effective (after loss) Mbps")
for xi,rv in enumerate(real):
    ax.text(xi+w,rv+1,f"{rv:.1f}",ha="center",fontsize=7.5,color="#166534",fontweight="bold")
ax.set_xticks(x); ax.set_xticklabels([f"{r}M" for r in RATES])
ax.set_xlabel("Target UDP Rate"); ax.set_ylabel("Throughput (Mbps)")
ax.set_title("Sent vs Reported vs Effective Throughput per Rate\n(Effective = Reported × (1 − Loss%))")
ax.legend(); fig.tight_layout()
save(fig,"P1_sent_recv_effective_tput.png")

# ── P2: Loss % vs target rate (box per rate) ─────────────────────────────────
print("P2: loss distribution per rate ...")
fig,ax=plt.subplots(figsize=(12,5))
box=[[ p["loss"] for p in pts if int(p["rate"])==r] for r in RATES]
bp=ax.boxplot(box,patch_artist=True,tick_labels=[f"{r}M" for r in RATES],widths=0.55)
colors=[plt.cm.RdYlGn_r(i/8) for i in range(9)]
for patch,c in zip(bp["boxes"],colors):
    patch.set_facecolor(c); patch.set_alpha(0.7)
for m in bp["medians"]: m.set_color("black"); m.set_linewidth(2.5)
for f in bp["fliers"]:  f.set(marker="o",markersize=4,alpha=0.5)
ax.set_xlabel("Target UDP Rate"); ax.set_ylabel("Packet Loss %")
ax.set_title("Packet Loss Distribution per UDP Rate\n(ZMQ radio capacity ~15 Mbps; loss rises sharply above it)")
medians=[sorted(b)[len(b)//2] for b in box if b]
for i,(b,m) in enumerate(zip(box,medians)):
    ax.text(i+1,m+1,f"{m:.0f}%",ha="center",fontsize=8,color="#333")
fig.tight_layout()
save(fig,"P2_loss_distribution_per_rate.png")

# ── P3: Scatter — tput vs loss coloured by rate ───────────────────────────────
print("P3: scatter tput vs loss ...")
fig,ax=plt.subplots(figsize=(11,6))
cmap=plt.cm.viridis
norm=matplotlib.colors.LogNorm(vmin=1,vmax=500)
for p in pts:
    c=cmap(norm(p["rate"]))
    ax.scatter(p["tput"],p["loss"],color=c,alpha=0.55,s=30,edgecolors="none")
sm=plt.cm.ScalarMappable(cmap=cmap,norm=norm)
sm.set_array([])
cb=fig.colorbar(sm,ax=ax,label="Target Rate (Mbps)")
cb.set_ticks(RATES); cb.set_ticklabels([f"{r}M" for r in RATES])
ax.set_xlabel("Reported Throughput (Mbps)"); ax.set_ylabel("Packet Loss %")
ax.set_title("UDP Throughput vs Packet Loss — All UEs All Rates\n(colour = target rate)")
fig.tight_layout()
save(fig,"P3_scatter_tput_vs_loss.png")

# ── P4: Effective throughput per UE per rate — heatmap ───────────────────────
print("P4: effective tput heatmap ...")
all_ues=sorted(set(p["uid"] for p in pts))
mat=np.full((len(all_ues),len(RATES)),np.nan)
for p in pts:
    ri=RATES.index(int(p["rate"])); ui=all_ues.index(p["uid"])
    mat[ui,ri]=p["real"]

fig,ax=plt.subplots(figsize=(14,10))
im=ax.imshow(mat,aspect="auto",cmap="YlGn",vmin=0,vmax=20,
             extent=[-0.5,len(RATES)-0.5,-0.5,len(all_ues)-0.5])
ax.set_xticks(range(len(RATES))); ax.set_xticklabels([f"{r}M" for r in RATES])
ax.set_yticks(range(len(all_ues))); ax.set_yticklabels([f"UE{u}" for u in all_ues],fontsize=7)
ax.set_xlabel("Target UDP Rate"); ax.set_ylabel("UE")
ax.set_title("Effective Throughput Heatmap — All UEs × All Rates\n(Effective = Reported × (1−Loss%), capped at 20 Mbps for visibility)")
cb=fig.colorbar(im,ax=ax,shrink=0.6); cb.set_label("Effective Tput (Mbps)")
fig.tight_layout()
save(fig,"P4_effective_tput_heatmap.png")

# ── P5: Real throughput per UE at each rate — bar, sorted by UE ──────────────
print("P5: effective tput bars per rate ...")
fig,axes=plt.subplots(3,3,figsize=(18,13))
fig.suptitle("Effective UDP Throughput per UE at Each Rate\n(Effective = Reported × (1−Loss%))",
             fontsize=13,fontweight="bold")
for ai,rate in enumerate(RATES):
    ax=axes[ai//3][ai%3]
    sub=sorted([p for p in pts if int(p["rate"])==rate],key=lambda x:x["uid"])
    ue_ids=[p["uid"] for p in sub]; effs=[p["real"] for p in sub]
    colors_=[GREEN if e>0.5 else RED for e in effs]
    ax.bar(range(len(ue_ids)),effs,color=colors_,edgecolor="white",width=0.75)
    ax.set_xticks(range(len(ue_ids)))
    ax.set_xticklabels([f"UE{u}" for u in ue_ids],rotation=60,fontsize=6.5)
    ax.set_title(f"@ {rate} Mbps target",fontsize=10,fontweight="bold")
    ax.set_ylabel("Effective Tput (Mbps)")
    if effs:
        ax.axhline(np.mean(effs),color=ORANGE,ls="--",lw=1.2,
                   label=f"mean={np.mean(effs):.2f}")
        ax.legend(fontsize=7.5)
fig.tight_layout()
save(fig,"P5_effective_tput_per_ue_per_rate.png")

# ── P6: Loss vs effective tput trade-off line (mean per rate) ────────────────
print("P6: loss vs effective tput line ...")
fig,ax=plt.subplots(figsize=(10,6))
mean_real =[np.mean([p["real"] for p in pts if int(p["rate"])==r]) for r in RATES]
mean_loss =[np.mean([p["loss"] for p in pts if int(p["rate"])==r]) for r in RATES]
mean_tput =[np.mean([p["tput"] for p in pts if int(p["rate"])==r]) for r in RATES]

ax.plot(mean_tput,mean_loss,  color=BLUE,  marker="o",ms=9,lw=2,label="Reported Tput vs Loss")
ax.plot(mean_real, mean_loss, color=GREEN, marker="s",ms=9,lw=2,ls="--",label="Effective Tput vs Loss")
for i,(tp,rt,ls) in enumerate(zip(mean_tput,mean_real,mean_loss)):
    ax.annotate(f"{RATES[i]}M",(tp,ls),textcoords="offset points",xytext=(5,3),fontsize=8.5,color="#444")

ax.set_xlabel("Throughput (Mbps)"); ax.set_ylabel("Mean Packet Loss %")
ax.set_title("Loss vs Throughput Trade-off Curve (mean across all UEs)\nBlue=reported tput, Green=effective tput after loss")
ax.legend(); fig.tight_layout()
save(fig,"P6_loss_vs_tput_tradeoff.png")

# ── P7: Effective tput per UE @ 100M — horizontal bar sorted ─────────────────
print("P7: effective tput @100M sorted ...")
sub100=sorted([p for p in pts if int(p["rate"])==100],key=lambda x:x["real"],reverse=True)
fig,ax=plt.subplots(figsize=(9,12))
ue_labels=[f"UE{p['uid']}" for p in sub100]
eff_vals=[p["real"] for p in sub100]
rep_vals=[p["tput"] for p in sub100]
colors_=[GREEN if e>0.5 else RED for e in eff_vals]
y=np.arange(len(sub100))
ax.barh(y+0.2,rep_vals,height=0.35,color=BLUE,alpha=0.55,label="Reported tput")
ax.barh(y-0.2,eff_vals, height=0.35,color=GREEN,alpha=0.85,label="Effective tput")
ax.set_yticks(y); ax.set_yticklabels(ue_labels,fontsize=8)
ax.set_xlabel("Throughput (Mbps)")
ax.set_title("Effective vs Reported Throughput @100M\n(all UEs sorted by effective, green=usable data)")
ax.legend(); fig.tight_layout()
save(fig,"P7_effective_vs_reported_100M.png")

print(f"\nAll loss/tput plots saved to {OUTDIR}")
