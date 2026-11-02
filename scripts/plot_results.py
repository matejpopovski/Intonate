# /// script
# requires-python = ">=3.12"
# dependencies = ["matplotlib==3.10.0"]
# ///
"""Draws docs/pitch_by_snr.png from results/accuracy.json.

Run with: uv run --script scripts/plot_results.py
"""

import json
from pathlib import Path

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt

SURFACE = "#0B0912"
INK = "#EDE4D3"
MUTED = "#A99C92"
GRID = "#2A2430"
MARKS = {"linewidth": 2, "marker": "o", "markersize": 6, "markeredgecolor": SURFACE, "markeredgewidth": 1}
SERIES = {"white": ("#C4801F", "White noise"), "pink": ("#4F8AE6", "Pink noise")}

root = Path(__file__).resolve().parent.parent
data = json.loads((root / "results/accuracy.json").read_text())


def series(kind: str) -> list[tuple[float, dict]]:
    rows = data["trackerBySNRWhite"] if kind == "white" else data["trackerBySNRPink"]
    return [(float(row["label"].split()[0]), row) for row in rows]


plt.rcParams.update(
    {
        "font.family": "serif",
        "font.size": 11,
        "text.color": INK,
        "axes.edgecolor": GRID,
        "axes.labelcolor": MUTED,
        "xtick.color": MUTED,
        "ytick.color": MUTED,
    }
)

figure, (left, right) = plt.subplots(1, 2, figsize=(10, 3.9), facecolor=SURFACE)

for axis in (left, right):
    axis.set_facecolor(SURFACE)
    axis.grid(True, axis="y", color=GRID, linewidth=0.8)
    axis.set_axisbelow(True)
    axis.spines[["top", "right", "left"]].set_visible(False)
    axis.tick_params(length=0)
    axis.set_xlim(42, -2)
    axis.set_xlabel("Signal-to-noise ratio (dB), worse to the right")

for kind, (color, label) in SERIES.items():
    points = series(kind)
    snr = [point[0] for point in points]
    accuracy = [point[1]["rawPitchAccuracy50"] * 100 for point in points]
    left.plot(snr, accuracy, color=color, label=label, **MARKS)

    measured = [(s, row["medianAbsCents"]) for s, row in points if row["voicedRate"] >= 0.5]
    right.plot(
        [item[0] for item in measured],
        [item[1] for item in measured],
        color=color,
        label=label,
        **MARKS,
    )

left.set_title("Frames within 50 cents, all frames (%)", loc="left", color=INK, fontsize=12)
left.set_ylim(-3, 105)
left.legend(frameon=False, loc="lower left", labelcolor=INK)

right.set_title("Median error of those frames (cents)", loc="left", color=INK, fontsize=12)
right.set_yscale("log")
right.set_yticks([0.01, 0.1, 1, 10], labels=["0.01", "0.1", "1", "10"])
right.minorticks_off()

figure.tight_layout(w_pad=3)
figure.savefig(root / "docs/pitch_by_snr.png", dpi=160, facecolor=SURFACE)
print("wrote docs/pitch_by_snr.png")
