# ---
# jupyter:
#   jupytext:
#     formats: py:percent
#   kernelspec:
#     display_name: Python 3
#     language: python
#     name: python3
# ---

# %% [markdown]
# # 2. Where each loss is burned: a chain of transformers
#
# Every transformer gets two hidden consumers:
#
# | Consumer | Network | Burns |
# |---|---|---|
# | **Line loss** | downstream (the one it feeds) | its line loss × its output |
# | **Transf. ineff.** | upstream (the one it draws from) | `drawn × (1 − e) / e` + core loss |
#
# Core loss is a constant 0.1% of the transformer's rating while it is switched on; the rating is the
# weaker of its two sides (the highest-rated pole wired to each side, then the smaller of the two).
#
# Working backwards from the machines gives every figure, as the mod's burns do at steady state.

# %%
import matplotlib.pyplot as plt

import lineloss_model as m

# %% [markdown]
# ## Why the burn is `delivered × loss / (1 − loss)`
#
# The "Line loss" consumer is itself fed by the transformer, so the measured output includes it. If
# the burn were set to `loss × measured output`, it would feed back on itself and settle slowly at high
# losses. The mod computes it from the delivered power instead, which lands on the fixed point in one
# step. The iteration below shows the slow version for a 95% loss.

# %%
loss, useful = 0.95, 10.0
out, history = useful, []
for _ in range(60):
    burn = loss * out          # naive: burn from the measured output
    out = useful + burn
    history.append(out)
target = useful / (1 - loss)
plt.figure(figsize=(7, 3))
plt.plot(history, label="naive feedback")
plt.axhline(target, color="k", ls="--", label=f"one-step value {target:.0f} MW")
plt.xlabel("measurement")
plt.ylabel("transformer output (MW)")
plt.legend()
plt.title("Burn settling at a 95% line loss")
plt.show()

# %% [markdown]
# ## FAQ example 1: generator → T1 → 300 tiles of big poles → T2 → 10 MW of machines
#
# T1 has big poles on both sides (rated 300 MW); T2 goes from big to medium poles (rated 60 MW). The
# machines are spread along 20 tiles of medium poles, so their average distance from T2 is
# 10 × 2.2 = 22.

# %%
t2 = m.transformer_stage(10e6, m.route_loss(10 * m.resistance("medium")), rating=60e6)
t1 = m.transformer_stage(t2["draw"], m.route_loss(300), rating=300e6)
rows = [
    ("Generator output", t1["draw"], ""),
    ("T1 core loss (0.1% of 300 MW)", t1["core"], "Transf. ineff. (T1)"),
    ("T1 inefficiency (1%)", t1["ineff"], "Transf. ineff. (T1)"),
    ("300-tile line (7.5%)", t1["line"], "Line loss (T1)"),
    ("T2 core loss (0.1% of 60 MW)", t2["core"], "Transf. ineff. (T2)"),
    ("T2 inefficiency (1%)", t2["ineff"], "Transf. ineff. (T2)"),
    ("Wires to the machines (0.55%)", t2["line"], "Line loss (T2)"),
    ("Reaching the machines", 10e6, ""),
]
for name, value, consumer in rows:
    print(f"{name:<34}{value / 1e6:8.2f} MW   {consumer}")
lost = t1["draw"] - 10e6
print(f"\nLost {lost / 1e6:.2f} MW = {lost / t1['draw'] * 100:.1f}% of generation")

# %% [markdown]
# ## FAQ example 2: three generators, a trunk and two branches
#
# G1, G2, G3 (equal output) at 5, 10 and 15 tiles of medium poles from T1; 100 tiles of big poles; T2
# and T3 side by side at the end of the trunk. T2 feeds 30 MW along 200 tiles of medium poles, T3
# feeds 5 MW along 20 tiles. Each transformer has medium poles on one side, so each is rated 60 MW.

# %%
t2 = m.transformer_stage(30e6, m.route_loss(100 * m.resistance("medium")), rating=60e6)
t3 = m.transformer_stage(5e6, m.route_loss(10 * m.resistance("medium")), rating=60e6)
t1 = m.transformer_stage(t2["draw"] + t3["draw"], m.route_loss(100), rating=60e6)
gen_loss = m.route_loss(10 * m.resistance("medium"))     # generators' average distance from T1
gen_wires = t1["draw"] * gen_loss / (1 - gen_loss)
generated = t1["draw"] + gen_wires

parts = {
    "generator wires": gen_wires,
    "T1 core + ineff.": t1["core"] + t1["ineff"],
    "trunk": t1["line"],
    "T2 core + ineff.": t2["core"] + t2["ineff"],
    "T3 core + ineff.": t3["core"] + t3["ineff"],
    "S2 long line": t2["line"],
    "S3 short line": t3["line"],
}
for name, value in parts.items():
    print(f"{name:<18}{value / 1e6:6.2f} MW")
print(f"\ngenerated {generated / 1e6:.2f} MW, delivered 35.00 MW, "
      f"lost {(generated - 35e6) / 1e6:.2f} MW ({(generated - 35e6) / generated * 100:.1f}%)")

plt.figure(figsize=(7, 3.2))
plt.barh(list(parts), [v / 1e6 for v in parts.values()], color="#ff9f1c")
plt.xlabel("MW lost")
plt.title("Example 2: where the 3.88 MW go")
plt.gca().invert_yaxis()
plt.show()

# %% [markdown]
# S2's long medium-pole line is the biggest single loss; carrying the power closer to S2 on big poles,
# or feeding S2 from both ends, would cut it.
