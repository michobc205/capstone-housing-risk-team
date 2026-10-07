"""
Housing price decline risk: results dashboard (phase 7).

Run from the repo root:
    streamlit run notebooks/07_phase7_dashboard.py

The dashboard does no modeling. It only reads the tables written by notebooks 05 and 06
(and the overview tables written by notebooks/07b_export_dashboard_data.py), so every
number on a page can be traced to a verified table. It reads Postgres first. If the
database cannot be reached, it reads the CSV snapshot in docs/dashboard_data/.
"""
import json
import os
from pathlib import Path

import numpy as np
import pandas as pd
import plotly.express as px
import plotly.graph_objects as go
import streamlit as st
from dotenv import find_dotenv, load_dotenv
from plotly.subplots import make_subplots
from sqlalchemy import create_engine, text

load_dotenv(find_dotenv(usecwd=True), override=True)

st.set_page_config(page_title="Housing price decline risk", page_icon="\U0001F3E1", layout="wide")

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent if HERE.name == "notebooks" else HERE
SNAP_DIR = ROOT / "docs" / "dashboard_data"
LOCK_DIR = ROOT / "docs"

FAMILY_LABELS = {"logreg": "Logistic regression", "random_forest": "Random forest",
                 "hist_gb": "Histogram gradient boosting"}
STEP_LABELS = {"baseline": "Baseline (momentum only)", "step2_rate_level": "+ rate level",
               "step3_rate_change": "+ rate change and interaction"}
COMPARISON_LABELS = {"step2_minus_baseline": "+ rate level, against baseline",
                     "step3_minus_step2": "+ rate change, against + rate level",
                     "step3_minus_baseline": "+ rate change, against baseline"}
RULES = ["top 5% each quarter", "top 10% each quarter", "top 20% each quarter", "F1 threshold from validation"]
MIN_GAIN = 0.01

TABLES = {  # name -> columns to parse as dates
    "phase5_fold_scores": [], "phase5_step_summary": [], "phase5_bootstrap_deltas": [],
    "phase6_test_scores": [], "phase6_test_deltas": [], "phase6_family_deltas": [],
    "phase6_thresholds": [], "phase6_decision_rules": [], "phase6_calibration": [],
    "phase6_calibration_all": [], "phase6_per_quarter": ["quarter"], "phase6_range_check": [],
    "phase6_eval_summary": [], "dash_split_summary": [], "dash_quarterly_rate": ["quarter"],
    "dash_fold_overview": [], "dash_fold_range_check": [], "dash_test_range_by_quarter": ["quarter"],
}


# ------------------------------------------------------------------------------------
# Data: database first, CSV snapshot as fallback
# ------------------------------------------------------------------------------------
@st.cache_resource
def get_engine():
    try:
        engine = create_engine(
            "postgresql+psycopg2://{}:{}@{}:{}/{}".format(
                os.environ.get("PGUSER", "postgres"), os.environ.get("PGPASSWORD", ""),
                os.environ.get("PGHOST", "localhost"), os.environ.get("PGPORT", "5432"),
                os.environ.get("PGDATABASE", "housing_risk_team")),
            connect_args={"connect_timeout": 3})
        with engine.connect() as conn:
            conn.execute(text("SELECT 1"))
        return engine
    except Exception:
        return None


@st.cache_data(show_spinner=False, ttl=300)
def load_table(name):
    """Return (DataFrame, source) where source is 'database' or 'snapshot'."""
    engine = get_engine()
    df, source = None, None
    if engine is not None:
        try:
            df, source = pd.read_sql(f"SELECT * FROM {name}", engine), "database"
        except Exception:
            df = None
    if df is None:
        path = SNAP_DIR / f"{name}.csv"
        if path.exists():
            df, source = pd.read_csv(path), "snapshot"
    if df is None:
        return None, None
    for col in TABLES[name]:
        df[col] = pd.to_datetime(df[col])
    return df, source


data, sources, missing = {}, {}, []
for tname in TABLES:
    df_, src_ = load_table(tname)
    if df_ is None:
        missing.append(tname)
    else:
        data[tname], sources[tname] = df_, src_

if missing:
    st.error("Some tables could not be found in the database or in docs/dashboard_data/: "
             + ", ".join(missing))
    st.info("Run notebooks 05 and 06, then `python notebooks/07b_export_dashboard_data.py`, "
            "and start the dashboard again.")
    st.stop()


# ------------------------------------------------------------------------------------
# Helpers
# ------------------------------------------------------------------------------------
def fl(f):
    return FAMILY_LABELS.get(f, f)


def sl(s):
    return STEP_LABELS.get(s, s)


def qlabel(ts):
    ts = pd.Timestamp(ts)
    return f"{ts.year}-Q{ts.quarter}"


def pct(v, d=1):
    return f"{100 * v:.{d}f}%"


def fmt_interval(lo, hi):
    return f"{lo:+.4f} to {hi:+.4f}"


def verdict(point, lo, hi):
    if lo > 0 and point >= MIN_GAIN:
        return "helps"
    if lo > 0:
        return "positive but below +0.01"
    if hi < 0:
        return "hurts"
    return "no significant effect"


eval_summary = dict(zip(data["phase6_eval_summary"]["key"], data["phase6_eval_summary"]["value"]))
REC_FAMILY, REC_STEP = eval_summary["recommended_family"], eval_summary["recommended_step"]
TEST_BASE_RATE = float(eval_summary["test_base_rate"])
test_scores = data["phase6_test_scores"]
rec_row = test_scores[(test_scores["family"] == REC_FAMILY) & (test_scores["step"] == REC_STEP)].iloc[0]
rules = data["phase6_decision_rules"]
thresholds = data["phase6_thresholds"]
per_quarter = data["phase6_per_quarter"]
N_TEST_QUARTERS = per_quarter["quarter"].nunique()


def rule_row(split, family, step, rule):
    sub = rules[(rules["split"] == split) & (rules["family"] == family)
                & (rules["step"] == step) & (rules["rule"] == rule)]
    return sub.iloc[0]


def delta_frame():
    val = data["phase5_bootstrap_deltas"].copy()
    val["period"] = "Validation (11 folds)"
    tst = data["phase6_test_deltas"].copy()
    tst["period"] = f"Test ({N_TEST_QUARTERS} quarters)"
    d = pd.concat([val, tst], ignore_index=True)
    d["label"] = d["family"].map(fl) + ": " + d["comparison"].map(COMPARISON_LABELS)
    return d


# ------------------------------------------------------------------------------------
# Sidebar
# ------------------------------------------------------------------------------------
st.sidebar.title("\U0001F3E1 Housing price decline risk")
page = st.sidebar.radio("Page", ["1. The answer", "2. Data and folds", "3. Models on validation",
                                 "4. Test and decision rules", "5. Limits and method"])
st.sidebar.markdown("---")
n_db = sum(1 for s in sources.values() if s == "database")
n_snap = sum(1 for s in sources.values() if s == "snapshot")
st.sidebar.caption(f"Data: {n_db} tables from Postgres, {n_snap} from the CSV snapshot.")
info_path = SNAP_DIR / "snapshot_info.json"
if n_snap and info_path.exists():
    st.sidebar.caption("Snapshot created " + json.loads(info_path.read_text())["created_utc"] + " (UTC).")
st.sidebar.caption("Question: which US counties will see home values fall by more than 2% next "
                   "quarter, and what do mortgage rates add once a county's own price momentum is known?")


# ------------------------------------------------------------------------------------
# Page 1: the answer
# ------------------------------------------------------------------------------------
if page.startswith("1"):
    st.title("What do mortgage rates add once price momentum is known?")
    st.caption("Everything on this page is read from the verified result tables. No model runs here.")

    d = delta_frame()
    d["verdict_check"] = [verdict(p, lo, hi) for p, lo, hi in zip(d["point_delta"], d["ci_lo"], d["ci_hi"])]
    n_help = int((d["verdict_check"] == "helps").sum())
    n_hurt = int((d["verdict_check"] == "hurts").sum())
    if n_help == 0:
        st.success(
            f"**The rate adds nothing robust.** In none of the {len(d)} comparisons (3 model families, 3 steps "
            "compared, validation and Test) does the gain clear the rule: the interval excludes zero **and** the "
            f"gain is at least +{MIN_GAIN:.2f} ROC-AUC. In {n_hurt} of them adding the rate lowers the score.")
    else:
        st.warning(f"{n_help} of {len(d)} comparisons clear the rule (interval excludes zero and gain of at least "
                   f"+{MIN_GAIN:.2f} ROC-AUC). See the chart and table below.")

    top10_test = rule_row("test", REC_FAMILY, REC_STEP, "top 10% each quarter")
    c1, c2, c3, c4 = st.columns(4)
    c1.metric("Test ROC-AUC", f"{rec_row['test_roc_auc']:.4f}",
              f"95% interval {rec_row['test_roc_ci_lo']:.3f} to {rec_row['test_roc_ci_hi']:.3f}", delta_color="off", delta_arrow="off")
    c2.metric("Test PR-AUC", f"{rec_row['test_pr_auc']:.4f}", f"base rate {pct(TEST_BASE_RATE, 2)}", delta_color="off", delta_arrow="off")
    c3.metric("Riskiest 10% each quarter: declines found", pct(top10_test["recall"]),
              f"{pct(top10_test['precision'])} of flagged declined", delta_color="off", delta_arrow="off")
    c4.metric("Lift of that list", f"{top10_test['lift']:.1f}x", "against the Test base rate", delta_color="off", delta_arrow="off")
    st.caption(f"Recommended model (chosen on validation only): **{fl(REC_FAMILY)}**, **{sl(REC_STEP).lower()}**.")

    st.subheader("Change in ROC-AUC when the rate is added")
    d["err_plus"] = d["ci_hi"] - d["point_delta"]
    d["err_minus"] = d["point_delta"] - d["ci_lo"]
    fig = px.scatter(d, x="point_delta", y="label", color="period", error_x="err_plus", error_x_minus="err_minus",
                     labels={"point_delta": "Change in ROC-AUC, with 95% interval", "label": ""},
                     height=560, color_discrete_sequence=["#1f77b4", "#d62728"])
    fig.add_vline(x=0, line_color="gray")
    fig.add_vline(x=MIN_GAIN, line_dash="dash", line_color="green",
                  annotation_text=f"+{MIN_GAIN:.2f} needed", annotation_position="top")
    fig.update_traces(marker=dict(size=9))
    fig.update_yaxes(autorange="reversed")
    st.plotly_chart(fig, width="stretch")
    st.caption("A step helps only if its whole interval is to the right of zero and the point is at or beyond "
               "the green line. Intervals come from a bootstrap that resamples whole quarters, because counties "
               "in one quarter share the same rate environment.")

    with st.expander("The same result as a table"):
        t = d[["period", "family", "comparison", "point_delta", "ci_lo", "ci_hi", "verdict_check"]].copy()
        t["family"] = t["family"].map(fl)
        t["comparison"] = t["comparison"].map(COMPARISON_LABELS)
        t["95% interval"] = [fmt_interval(a, b) for a, b in zip(t["ci_lo"], t["ci_hi"])]
        t["change"] = t["point_delta"].map(lambda v: f"{v:+.4f}")
        st.dataframe(t[["period", "family", "comparison", "change", "95% interval", "verdict_check"]]
                     .rename(columns={"verdict_check": "verdict"}), hide_index=True, width="stretch")

# ------------------------------------------------------------------------------------
# Page 2: data and folds
# ------------------------------------------------------------------------------------
elif page.startswith("2"):
    st.title("Data and validation folds")
    split = data["dash_split_summary"].copy()
    split["decline rate"] = split["decline_rate"].map(lambda v: pct(v, 2))
    split["rows"] = split["n_rows"].map(lambda v: f"{int(v):,}")
    split["counties"] = split["n_counties"].map(lambda v: f"{int(v):,}")
    split["declines"] = split["n_declines"].map(lambda v: f"{int(v):,}")
    st.subheader("The modeling table by period")
    st.dataframe(split[["split", "rows", "counties", "declines", "decline rate"]], hide_index=True, width="stretch")
    st.caption("Train runs through 2021-Q3, Test covers 2022-Q1 to 2026-Q1, and one embargo quarter sits "
               "between them. The unassigned row is the latest quarter, which belongs to neither.")

    st.subheader("Share of counties that decline, and the mortgage rate")
    q = data["dash_quarterly_rate"].sort_values("quarter")
    fig = make_subplots(rows=2, cols=1, shared_xaxes=True, row_heights=[0.62, 0.38], vertical_spacing=0.08,
                        subplot_titles=("Share of counties with a decline of more than 2% (%)",
                                        "30-year mortgage rate at the quarter before (%)"))
    for sp, color in [("train", "#1f77b4"), ("embargo", "#7f7f7f"), ("test", "#d62728"), ("unassigned", "#bbbbbb")]:
        s = q[q["split"] == sp]
        if len(s):
            fig.add_trace(go.Scatter(x=s["quarter"], y=100 * s["decline_rate"], mode="lines+markers", name=sp,
                                     line=dict(color=color)), row=1, col=1)
    fig.add_trace(go.Scatter(x=q["quarter"], y=q["mortgage_rate_level"], mode="lines", name="mortgage rate",
                             line=dict(color="black"), showlegend=False), row=2, col=1)
    fig.update_layout(height=620)
    st.plotly_chart(fig, width="stretch")
    st.caption("Quarters are label quarters. The decline share swings between very low and very high "
               "years, which is why every result is reported per fold or per quarter.")

    st.subheader("The 11 validation folds")
    fo = data["dash_fold_overview"].sort_values("fold_id").copy()
    fo["validation year"] = 2010 + fo["fold_id"]
    fig_f = px.bar(fo, x="validation year", y="val_rate_pct", text=fo["val_rate_pct"].map(lambda v: f"{v:.2f}%"),
                   labels={"val_rate_pct": "Decline rate in the validation year (%)"}, height=380)
    fig_f.update_traces(marker_color="#1f77b4", textposition="outside")
    fig_f.update_xaxes(dtick=1)
    st.plotly_chart(fig_f, width="stretch")
    lo_f, hi_f = fo.loc[fo["val_rate_pct"].idxmin()], fo.loc[fo["val_rate_pct"].idxmax()]
    st.caption(f"Validation decline rates run from {lo_f['val_rate_pct']:.2f}% ({int(lo_f['validation year'])}, "
               f"{int(lo_f['val_declines'])} declines) to {hi_f['val_rate_pct']:.2f}% ({int(hi_f['validation year'])}). "
               "Each fold trains on all earlier years and validates on the next year.")
    show = fo[["fold_id", "validation year", "train_rows", "train_declines", "val_rows", "val_declines", "val_rate_pct"]].copy()
    show["val_rate_pct"] = show["val_rate_pct"].map(lambda v: f"{v:.2f}%")
    st.dataframe(show.rename(columns={"fold_id": "fold", "train_rows": "training rows", "train_declines": "training declines",
                                      "val_rows": "validation rows", "val_declines": "validation declines",
                                      "val_rate_pct": "validation decline rate"}), hide_index=True, width="stretch")

    st.subheader("Rates outside the training range, per fold")
    fr = data["dash_fold_range_check"].sort_values("fold_id").copy()
    fr["validation year"] = 2010 + fr["fold_id"]
    long = fr.melt(id_vars="validation year", value_vars=["mortgage_rate_level_pct_outside", "mortgage_rate_roc_pct_outside"],
                   var_name="feature", value_name="share of validation rows outside (%)")
    long["feature"] = long["feature"].map({"mortgage_rate_level_pct_outside": "rate level",
                                           "mortgage_rate_roc_pct_outside": "12-month rate change"})
    fig_r = px.bar(long, x="validation year", y="share of validation rows outside (%)", color="feature",
                   barmode="group", height=360)
    fig_r.update_xaxes(dtick=1)
    st.plotly_chart(fig_r, width="stretch")
    st.caption("Tree models cannot predict beyond the values they saw in training, so rows outside "
               "the training range are a risk for them.")

# ------------------------------------------------------------------------------------
# Page 3: models on validation
# ------------------------------------------------------------------------------------
elif page.startswith("3"):
    st.title("Models on the 11 validation folds")
    st.caption("Three model families, three feature steps, fixed settings, nothing tuned. "
               "The Test period plays no part on this page.")
    summary = data["phase5_step_summary"].copy()
    best = summary[summary["is_recommended"].astype(str).str.lower().isin(["true", "1"])].iloc[0]
    st.info(f"Recommended on validation: **{fl(best['family'])}**, **{sl(best['step']).lower()}**, with a "
            f"mean ROC-AUC of {best['mean_roc_auc']:.4f} and a mean PR-AUC of {best['mean_pr_auc']:.4f}. "
            "It has the highest average ROC-AUC across the folds.")

    st.subheader("Average over the 11 folds")
    t = summary.sort_values("mean_roc_auc", ascending=False).copy()
    t["family"], t["step"] = t["family"].map(fl), t["step"].map(sl)
    for c in ["mean_roc_auc", "std_roc_auc", "mean_pr_auc", "std_pr_auc"]:
        t[c] = t[c].map(lambda v: f"{v:.4f}")
    t["average base rate"] = t["mean_base_rate_pct"].map(lambda v: f"{v:.2f}%")
    st.dataframe(t[["family", "step", "mean_roc_auc", "std_roc_auc", "mean_pr_auc", "std_pr_auc", "average base rate"]]
                 .rename(columns={"mean_roc_auc": "mean ROC-AUC", "std_roc_auc": "std", "mean_pr_auc": "mean PR-AUC",
                                  "std_pr_auc": "std (PR)"}), hide_index=True, width="stretch")

    st.subheader("Fold by fold")
    cc1, cc2 = st.columns(2)
    metric = cc1.radio("Metric", ["ROC-AUC", "PR-AUC"], horizontal=True)
    step_choice = cc2.selectbox("Feature step", ["All steps"] + [sl(s) for s in STEP_LABELS], index=1)
    fs = data["phase5_fold_scores"].copy()
    fs["validation year"] = 2010 + fs["fold_id"]
    fs["family_label"], fs["step_label"] = fs["family"].map(fl), fs["step"].map(sl)
    if step_choice != "All steps":
        fs = fs[fs["step_label"] == step_choice]
    ycol = "roc_auc" if metric == "ROC-AUC" else "pr_auc"
    fig = px.line(fs, x="validation year", y=ycol, color="family_label", line_dash="step_label", markers=True,
                  labels={ycol: metric, "family_label": "family", "step_label": "step"}, height=470)
    if metric == "PR-AUC":
        base = fs.drop_duplicates("fold_id").sort_values("fold_id")
        fig.add_trace(go.Scatter(x=base["validation year"], y=base["base_rate"], mode="lines+markers",
                                 name="base rate (what chance gives)", line=dict(color="black", dash="dot")))
    st.plotly_chart(fig, width="stretch")
    fo3 = data["dash_fold_overview"]
    low3 = fo3.loc[fo3["val_declines"].idxmin()]
    st.caption("PR-AUC has to be read against the base rate of the same year, shown by the dotted line. "
               f"The {2010 + int(low3['fold_id'])} fold has only {int(low3['val_declines'])} declines, so its scores are noisy.")

    st.subheader("Does adding the rate help? (validation)")
    vb = data["phase5_bootstrap_deltas"].copy()
    vb["family"], vb["comparison"] = vb["family"].map(fl), vb["comparison"].map(COMPARISON_LABELS)
    vb["change"] = vb["point_delta"].map(lambda v: f"{v:+.4f}")
    vb["95% interval"] = [fmt_interval(a, b) for a, b in zip(vb["ci_lo"], vb["ci_hi"])]
    st.dataframe(vb[["family", "comparison", "change", "95% interval", "verdict"]], hide_index=True, width="stretch")
    st.caption("Bootstrap over the 44 validation quarters. A step helps only if the interval excludes zero and "
               f"the gain is at least +{MIN_GAIN:.2f}.")

# ------------------------------------------------------------------------------------
# Page 4: Test and decision rules
# ------------------------------------------------------------------------------------
elif page.startswith("4"):
    st.title("The Test period and how to use the predictions")
    st.caption("Every choice was made on the validation folds, and the nine models were scored on Test with frozen models "
               f"({N_TEST_QUARTERS} quarters, base rate {pct(TEST_BASE_RATE, 2)}).")

    st.subheader("Test scores")
    ts = test_scores.copy()
    ts["label"] = ts["family"].map(fl) + ": " + ts["step"].map(sl)
    ts["err_plus"], ts["err_minus"] = ts["test_roc_ci_hi"] - ts["test_roc_auc"], ts["test_roc_auc"] - ts["test_roc_ci_lo"]
    fig = go.Figure()
    fig.add_trace(go.Scatter(y=ts["label"], x=ts["test_roc_auc"], mode="markers", name="Test ROC-AUC (95% interval)",
                             error_x=dict(type="data", symmetric=False, array=ts["err_plus"], arrayminus=ts["err_minus"]),
                             marker=dict(color="#d62728", size=10)))
    fig.add_trace(go.Scatter(y=ts["label"], x=ts["val_mean_roc_auc"], mode="markers", name="Validation average",
                             marker=dict(color="black", size=9, symbol="diamond")))
    fig.update_layout(height=520, xaxis=dict(range=[0.75, 0.95], title="ROC-AUC"), yaxis=dict(autorange="reversed"))
    st.plotly_chart(fig, width="stretch")
    show = ts[["family", "step", "test_roc_auc", "test_pr_auc", "test_brier", "mean_predicted", "val_mean_roc_auc"]].copy()
    show["family"], show["step"] = show["family"].map(fl), show["step"].map(sl)
    show["mean_predicted"] = show["mean_predicted"].map(lambda v: pct(v, 2))
    for c in ["test_roc_auc", "test_pr_auc", "test_brier", "val_mean_roc_auc"]:
        show[c] = show[c].map(lambda v: f"{v:.4f}")
    st.dataframe(show.rename(columns={"test_roc_auc": "Test ROC-AUC", "test_pr_auc": "Test PR-AUC", "test_brier": "Brier",
                                      "mean_predicted": f"mean predicted (actual {pct(TEST_BASE_RATE, 2)})",
                                      "val_mean_roc_auc": "validation mean ROC-AUC"}), hide_index=True, width="stretch")
    with st.expander("Does the rate help on Test? And the families against each other"):
        tb = data["phase6_test_deltas"].copy()
        tb["family"], tb["comparison"] = tb["family"].map(fl), tb["comparison"].map(COMPARISON_LABELS)
        tb["change"] = tb["point_delta"].map(lambda v: f"{v:+.4f}")
        tb["95% interval"] = [fmt_interval(a, b) for a, b in zip(tb["ci_lo"], tb["ci_hi"])]
        st.dataframe(tb[["family", "comparison", "change", "95% interval", "verdict"]], hide_index=True, width="stretch")
        fd = data["phase6_family_deltas"].copy()
        fd["step"] = fd["step"].map(sl)
        fd["difference"] = fd["point_delta"].map(lambda v: f"{v:+.4f}")
        fd["95% interval"] = [fmt_interval(a, b) for a, b in zip(fd["ci_lo"], fd["ci_hi"])]
        st.dataframe(fd[["step", "comparison", "difference", "95% interval", "interval_excludes_zero"]],
                     hide_index=True, width="stretch")

    st.subheader("Decision rules: validation and Test side by side")
    cc1, cc2 = st.columns(2)
    rule = cc1.radio("Decision rule", RULES)
    model_options = [f"{fl(f)}: {sl(s)}" for f in FAMILY_LABELS for s in STEP_LABELS]
    default_idx = model_options.index(f"{fl(REC_FAMILY)}: {sl(REC_STEP)}")
    model_choice = cc2.selectbox("Model", model_options, index=default_idx)
    fam_key = [k for k, v in FAMILY_LABELS.items() if model_choice.startswith(v + ":")][0]
    step_key = [k for k, v in STEP_LABELS.items() if model_choice.endswith(": " + v)][0]
    if rule.startswith("F1"):
        thr = thresholds[(thresholds["family"] == fam_key) & (thresholds["step"] == step_key)].iloc[0]["threshold"]
        st.caption(f"Flag every county whose predicted probability is at least **{thr:.4f}**, the cut-off that "
                   "maximizes F1 on the validation predictions. It is applied unchanged to Test.")
    else:
        st.caption("In every quarter, flag the counties with the highest predicted probability, as many as this "
                   "share of that quarter's counties. The rule depends only on the ranking.")
    cv, ct = st.columns(2)
    for col, split, title in [(cv, "validation", "Validation (2010-2020)"), (ct, "test", "Test (2022-2026)")]:
        r = rule_row(split, fam_key, step_key, rule)
        col.markdown(f"**{title}**")
        m1, m2, m3, m4 = col.columns(4)
        m1.metric("Flagged", pct(r["flagged_share"]))
        m2.metric("Precision", pct(r["precision"]))
        m3.metric("Recall", pct(r["recall"]))
        m4.metric("Lift", f"{r['lift']:.1f}x")
        z = [[int(r["tn"]), int(r["fp"])], [int(r["fn"]), int(r["tp"])]]
        cm = px.imshow(z, x=["not flagged", "flagged"], y=["did not decline", "declined"], text_auto=",d",
                       color_continuous_scale="Blues", height=300, aspect="auto")
        cm.update_layout(coloraxis_showscale=False, margin=dict(t=20, b=10))
        col.plotly_chart(cm, width="stretch", key=f"confusion_{split}")
    st.caption("Precision is the share of flagged counties that declined, recall the share of all declines that "
               "were flagged, and lift is precision divided by the base rate. Test has more declines than "
               "validation, so precision is higher there for any rule: compare lift, not precision.")
    allr = rules[(rules["family"] == fam_key) & (rules["step"] == step_key)].copy()
    allr["rule"] = pd.Categorical(allr["rule"], RULES, ordered=True)
    allr["flagged"] = allr["flagged_share"].map(pct)
    for c in ["precision", "recall"]:
        allr[c] = allr[c].map(lambda v: f"{v:.3f}")
    allr["lift"] = allr["lift"].map(lambda v: f"{v:.1f}")
    st.dataframe(allr[["split", "rule", "tp", "fp", "fn", "tn", "precision", "recall", "flagged", "lift"]]
                 .sort_values(["split", "rule"], ascending=[False, True]), hide_index=True, width="stretch")

    st.subheader("Calibration: does a predicted probability mean what it says?")
    cal = data["phase6_calibration"]
    figc = go.Figure()
    top = float(max(cal["mean_predicted"].max(), cal["actual_rate"].max()))
    figc.add_trace(go.Scatter(x=[0, top], y=[0, top], mode="lines", name="perfect calibration",
                              line=dict(color="gray", dash="dash")))
    for sp, color in [("validation", "#1f77b4"), ("test", "#d62728")]:
        s = cal[cal["split"] == sp]
        figc.add_trace(go.Scatter(x=s["mean_predicted"], y=s["actual_rate"], mode="lines+markers", name=sp,
                                  line=dict(color=color)))
    figc.update_layout(height=430, xaxis_title="mean predicted probability (per decile)",
                       yaxis_title="share that actually declined")
    st.plotly_chart(figc, width="stretch")
    st.caption(f"Recommended model ({fl(REC_FAMILY)}, {sl(REC_STEP).lower()}). Points above the dashed line mean "
               "the model under-predicts. On Test the probabilities are too low in every decile, on validation "
               "they are too high at the top, so the models are better used to rank counties than to read a "
               "probability.")
    ca = data["phase6_calibration_all"].copy()
    ca_val_actual = float(ca["val_actual_pct"].iloc[0])
    ca["family"], ca["step"] = ca["family"].map(fl), ca["step"].map(sl)
    for c in ["val_mean_pred_pct", "test_mean_pred_pct"]:
        ca[c] = ca[c].map(lambda v: f"{v:.2f}%")
    ca["test_brier"] = ca["test_brier"].map(lambda v: f"{v:.4f}")
    ca["deciles under-predicted"] = ca["test_deciles_underconfident"].astype(int).astype(str) + " of " + ca["test_deciles"].astype(int).astype(str)
    st.dataframe(ca[["family", "step", "val_mean_pred_pct", "test_mean_pred_pct", "test_brier", "deciles under-predicted"]]
                 .rename(columns={"val_mean_pred_pct": f"validation mean predicted (actual {ca_val_actual:.2f}%)",
                                  "test_mean_pred_pct": f"Test mean predicted (actual {pct(TEST_BASE_RATE, 2)})",
                                  "test_brier": "Test Brier"}), hide_index=True, width="stretch")

    st.subheader("Stability over time: each Test quarter")
    mq = st.selectbox("Model for the quarterly view", model_options, index=default_idx, key="qmodel")
    fam_q = [k for k, v in FAMILY_LABELS.items() if mq.startswith(v + ":")][0]
    step_q = [k for k, v in STEP_LABELS.items() if mq.endswith(": " + v)][0]
    pq = per_quarter[(per_quarter["family"] == fam_q) & (per_quarter["step"] == step_q)].sort_values("quarter")
    figq = make_subplots(specs=[[{"secondary_y": True}]])
    figq.add_trace(go.Bar(x=pq["quarter"], y=pq["roc_auc"], name="ROC-AUC", marker_color="#1f77b4"), secondary_y=False)
    figq.add_trace(go.Scatter(x=pq["quarter"], y=pq["base_rate_pct"], name="share that declined (%)", mode="lines+markers",
                              line=dict(color="black")), secondary_y=True)
    figq.update_yaxes(title_text="ROC-AUC", range=[0.5, 1.0], secondary_y=False)
    figq.update_yaxes(title_text="share that declined (%)", range=[0, float(pq["base_rate_pct"].max()) * 1.15], secondary_y=True)
    figq.update_xaxes(tickmode="array", tickvals=list(pq["quarter"]), ticktext=[qlabel(q) for q in pq["quarter"]], tickangle=-45)
    figq.update_layout(height=450)
    st.plotly_chart(figq, width="stretch")
    few = pq[pq["positives"] < 50]
    note = ""
    if len(few):
        note = (f" {len(few)} quarter(s) have fewer than 50 declines, so their scores are noisy: "
                + ", ".join(qlabel(q) for q in few["quarter"]) + ".")
    st.caption(f"ROC-AUC from {pq['roc_auc'].min():.3f} to {pq['roc_auc'].max():.3f} (median {pq['roc_auc'].median():.3f})." + note)
    shq = pq[["quarter", "n", "positives", "base_rate_pct", "roc_auc", "pr_auc", "top10_recall", "top10_precision"]].copy()
    shq["quarter"] = shq["quarter"].map(qlabel)
    for c in ["roc_auc", "pr_auc", "top10_recall", "top10_precision"]:
        shq[c] = shq[c].map(lambda v: f"{v:.3f}")
    shq["base_rate_pct"] = shq["base_rate_pct"].map(lambda v: f"{v:.2f}%")
    st.dataframe(shq.rename(columns={"n": "counties", "positives": "declines", "base_rate_pct": "base rate",
                                     "top10_recall": "top 10% recall", "top10_precision": "top 10% precision"}),
                 hide_index=True, width="stretch")

    st.subheader("Were Test rates outside what the models saw in Train?")
    rq = data["dash_test_range_by_quarter"].sort_values("quarter")
    longq = rq.melt(id_vars="quarter", value_vars=["mortgage_rate_level_pct_outside", "mortgage_rate_roc_pct_outside"],
                    var_name="feature", value_name="share of Test rows outside the Train range (%)")
    longq["feature"] = longq["feature"].map({"mortgage_rate_level_pct_outside": "rate level",
                                           "mortgage_rate_roc_pct_outside": "12-month rate change"})
    longq["quarter"] = longq["quarter"].map(qlabel)
    st.plotly_chart(px.bar(longq, x="quarter", y="share of Test rows outside the Train range (%)", color="feature",
                           barmode="group", height=360), width="stretch")
    rc = data["phase6_range_check"].copy()
    for c in ["train_min", "train_max", "test_min", "test_max"]:
        rc[c] = rc[c].map(lambda v: f"{v:.3f}")
    rc["test_pct_outside_train_range"] = rc["test_pct_outside_train_range"].map(lambda v: f"{v:.1f}%")
    st.dataframe(rc, hide_index=True, width="stretch")

# ------------------------------------------------------------------------------------
# Page 5: limits and method
# ------------------------------------------------------------------------------------
else:
    st.title("Limits and method")
    st.subheader("How the results were made")
    st.markdown(
        "- **Everything runs in SQL up to the modeling table.** Loading, joining, the time split, the validation folds, "
        "the labels and the features are built in PostgreSQL.\n"
        "- **Models were chosen on validation only.** Three families, three feature steps, fixed settings. The baseline "
        "was locked before any rate feature was fitted.\n"
        "- **Test was scored with frozen models.** The decision cut-off was found on validation and written to a "
        "file before Test was scored, and the Test scores were locked in a second file. Test was also scored in "
        "earlier, retired versions, so it is not a fresh draw, and nothing was chosen from Test results.\n"
        "- **Uncertainty comes from resampling whole quarters,** because counties in one quarter share the same rate "
        "environment.")

    st.subheader("Integrity check: this dashboard against the locked files")
    TIGHT, RF_BASELINE, RF_TEST = 1e-6, 1e-3, 1e-2   # team decisions (docs/merge_rules_phase5_6.md)
    checks = []   # (label, largest gap, allowed text, all within tolerance)
    tl = LOCK_DIR / "phase6_test_lock.json"
    if tl.exists():
        lock = json.loads(tl.read_text(encoding="utf-8"))["models"]
        pairs = []
        for r in test_scores.itertuples():
            ref = lock[f"{r.family}|{r.step}"]
            allowed = RF_TEST if r.family == "random_forest" else TIGHT
            gap = max(abs(ref["roc_auc"] - r.test_roc_auc), abs(ref["pr_auc"] - r.test_pr_auc),
                      abs(ref["brier"] - r.test_brier))
            pairs.append((gap, allowed))
        checks.append(("Test scores (ROC-AUC, PR-AUC, Brier) equal docs/phase6_test_lock.json",
                       max(g for g, _ in pairs), "1e-6; random forest 1e-2", all(g <= a for g, a in pairs)))
    thl = LOCK_DIR / "phase6_thresholds_lock.json"
    if thl.exists():
        lock = json.loads(thl.read_text(encoding="utf-8"))["thresholds"]
        gap = max(abs(lock[f"{r.family}|{r.step}"]["threshold"] - r.threshold) for r in thresholds.itertuples())
        checks.append(("F1 thresholds equal docs/phase6_thresholds_lock.json", gap, "1e-6", gap <= TIGHT))
    bl = LOCK_DIR / "phase5_baseline_lock.json"
    if bl.exists():
        lock = json.loads(bl.read_text(encoding="utf-8"))["families"]
        fs = data["phase5_fold_scores"]
        pairs = [(abs(lock[f]["mean_roc_auc"] - fs[(fs["family"] == f) & (fs["step"] == "baseline")]["roc_auc"].mean()),
                  RF_BASELINE if f == "random_forest" else TIGHT) for f in lock]
        checks.append(("Baseline validation scores equal docs/phase5_baseline_lock.json",
                       max(g for g, _ in pairs), "1e-6; random forest 1e-3", all(g <= a for g, a in pairs)))
    if not checks:
        st.info("The lock files were not found in docs/, so the check could not run.")
    for label, gap, allowed_text, ok in checks:
        (st.success if ok else st.error)(f"{label}: largest gap {gap:.1e} (allowed {allowed_text})")

    st.subheader("Limits to keep in mind")
    fo5 = data["dash_fold_overview"]
    low5 = fo5.loc[fo5["val_declines"].idxmin()]
    st.markdown(
        f"- **Test has {N_TEST_QUARTERS} quarters,** so its intervals are wide. The rate is one national number per "
        "quarter, so the evidence about it rests on the number of quarters, not on the number of county rows.\n"
        "- **One hiking cycle.** Test contains the 2022-23 rate-hiking cycle. The result is about that cycle and the "
        "years after it, not about rate cycles in general.\n"
        "- **Probabilities are not stable across periods.** They are too low on Test and too high on validation, so the "
        "models are better used to rank counties than to read a probability. A probability cut-off does not carry over "
        "when the base rate moves, while the top-X% rules always flag the intended share.\n"
        "- **Settings were fixed, not tuned,** and no recalibration was applied.\n"
        "- **The recommended model was chosen on validation.** On Test the families are close, and histogram gradient "
        "boosting scores slightly higher at baseline. The choice was not changed because of Test.\n"
        f"- **Small folds and quarters are noisy.** The {2010 + int(low5['fold_id'])} fold has only {int(low5['val_declines'])} declines.\n"
        "- **\"No gain\" is not \"no relationship\".** It says the rate adds nothing measurable beyond a county's own "
        "price momentum, which is the question the project asks.")
    st.caption("Data sources: Zillow ZHVI (county, middle tier) and FRED MORTGAGE30US. The data files are not part of the "
               "repository, and both sources have their own terms of use.")
