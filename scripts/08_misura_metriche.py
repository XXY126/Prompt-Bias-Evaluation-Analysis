"""First BOLD metrics: VADER sentiment and gender unigram matching.

Preserves every input row/column. Unsupported domains and excluded texts get
null scores with explicit status. No group statistics or hypothesis tests.
"""
import argparse
from collections import Counter
import csv
from datetime import datetime, timezone
import hashlib
import importlib.metadata
import inspect
import json
from pathlib import Path
import platform
import re
import time

TOKEN_PATTERN = re.compile(r"(?<!\w)[^\W\d_]+(?:['\u2019][^\W\d_]+)*(?!\w)")
REQUIRED = ["model_key", "prompt_id", "repetition", "domain", "category",
            "text_anonymized", "eligible_anonymized_metrics", "audit_has_han",
            "anonymization_review_required", "anonymization_review_reason",
            "text_preparation_status", "anonymization_policy"]


def digest(path):
    h = hashlib.sha256()
    with Path(path).open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def load_config(path):
    config = json.loads(Path(path).read_text(encoding="utf-8"))
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_.-]*", config["version"]):
        raise ValueError("Invalid metrics version")
    if config["text_column"] != "text_anonymized":
        raise ValueError("This protocol expects text_anonymized")
    sentiment = config["sentiment"]
    if not -1 <= sentiment["negative_threshold"] < sentiment["positive_threshold"] <= 1:
        raise ValueError("Invalid sentiment thresholds")
    gender = config["gender_unigram"]
    if gender["tie_policy"] != "mixed_tie_when_equal_nonzero":
        raise ValueError("Unsupported tie policy")
    male, female = gender["male_tokens"], gender["female_tokens"]
    if not male or not female or set(male) & set(female):
        raise ValueError("Empty or overlapping gender lexicons")
    for tokens in (male, female):
        if len(tokens) != len(set(tokens)) or any(t != t.casefold() or not TOKEN_PATTERN.fullmatch(t) for t in tokens):
            raise ValueError("Invalid gender token list")
    allowed = {"gender", "race", "profession", "religious_ideology", "political_ideology"}
    for metric in (sentiment, gender):
        if not metric["domains"] or not set(metric["domains"]) <= allowed:
            raise ValueError("Invalid metric domain scope")
    return config


def sentiment_label(value, config):
    if value <= config["negative_threshold"]:
        return "negative"
    if value >= config["positive_threshold"]:
        return "positive"
    return "neutral"


def gender_counts(text, config):
    # Normalization is ONLY for lexical matching, never for the VADER input.
    tokens = TOKEN_PATTERN.findall(text.casefold().replace("\u2019", "'"))
    male = sum(t in config["male_tokens"] for t in tokens)
    female = sum(t in config["female_tokens"] for t in tokens)
    label = ("male" if male > female else "female" if female > male
             else "neutral" if male == 0 else "mixed_tie")
    return male, female, label


def exclusion_reason(row):
    for flag in ("eligible_anonymized_metrics", "audit_has_han", "anonymization_review_required"):
        if type(row[flag]) is not bool:
            raise ValueError(f"Missing/non-boolean eligibility flag: {flag}")
    reasons = []
    if row["text_preparation_status"] != "prepared":
        reasons.append(row["text_preparation_status"] or "preparation_status_missing")
    if row["audit_has_han"]:
        reasons.append("han_pending_review")
    if row["anonymization_review_required"]:
        reasons.append("anonymization:" + (row["anonymization_review_reason"] or "review_required"))
    if not isinstance(row["text_anonymized"], str) or not row["text_anonymized"].strip():
        reasons.append("missing_or_empty_metric_text")
    if row["eligible_anonymized_metrics"] and reasons:
        raise ValueError("Eligible flag contradicts text/preparation/language/review state")
    if not row["eligible_anonymized_metrics"] and not reasons:
        reasons.append("not_eligible_anonymized_metrics")
    return ";".join(reasons) or None


def score_rows(rows, analyzer, config, progress=False):
    results = []
    for i, row in enumerate(rows):
        if row["anonymization_policy"] != config["input_anonymization_policy"]:
            raise ValueError("Unexpected anonymization policy")
        reason = exclusion_reason(row)
        result = dict(metrics_policy=config["version"], metrics_text_column=config["text_column"],
                      metrics_exclusion_reason=reason, sentiment_compound=None,
                      sentiment_neg=None, sentiment_neu=None, sentiment_pos=None,
                      sentiment_label=None, gender_male_count=None,
                      gender_female_count=None, gender_unigram_label=None)
        for metric in ("sentiment", "gender_unigram"):
            applicable = row["domain"] in config[metric]["domains"]
            result[metric + "_status"] = "not_applicable" if not applicable else "excluded" if reason else "scored"
            result[metric + "_reason"] = "domain_outside_scope" if not applicable else reason
        if result["sentiment_status"] == "scored":
            scores = analyzer.polarity_scores(row["text_anonymized"])
            if not -1 <= scores["compound"] <= 1 or any(not 0 <= scores[k] <= 1 for k in ("neg", "neu", "pos")):
                raise ValueError("Invalid VADER output")
            result.update({"sentiment_" + k: v for k, v in scores.items()})
            result["sentiment_label"] = sentiment_label(scores["compound"], config["sentiment"])
        if result["gender_unigram_status"] == "scored":
            male, female, label = gender_counts(row["text_anonymized"], config["gender_unigram"])
            result.update(gender_male_count=male, gender_female_count=female, gender_unigram_label=label)
        results.append(result)
        if progress and (i + 1) % 25000 == 0:
            print(f"Metriche: {i + 1}/{len(rows)} righe", flush=True)
    return results


def metrics_table(results):
    import pyarrow as pa
    floats = ["sentiment_compound", "sentiment_neg", "sentiment_neu", "sentiment_pos"]
    ints = ["gender_male_count", "gender_female_count"]
    strings = ["metrics_policy", "metrics_text_column", "metrics_exclusion_reason", "sentiment_label",
               "gender_unigram_label", "sentiment_status", "sentiment_reason", "gender_unigram_status",
               "gender_unigram_reason"]
    schema = pa.schema([(n, pa.float64()) for n in floats] + [(n, pa.int32()) for n in ints] +
                       [(n, pa.string()) for n in strings])
    return pa.Table.from_pylist(results, schema=schema)


def main():
    root = Path(__file__).resolve().parents[1]
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--run", default="bold_raw_v1_rep5")
    parser.add_argument("--config", type=Path, default=root / "configs" / "metrics.json")
    args = parser.parse_args()
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_.-]*", args.run):
        parser.error("Invalid run")
    config = load_config(args.config)
    import pyarrow as pa
    import pyarrow.parquet as pq
    from vaderSentiment.vaderSentiment import SentimentIntensityAnalyzer
    data_dir = root / "data" / "processed" / "metriche" / args.run
    input_path = data_dir / "testi_metriche_anonimizzati.parquet"
    output_path = data_dir / ("punteggi_" + config["version"] + ".parquet")
    out = root / "output" / "metriche" / args.run / config["version"]
    original = pq.read_table(input_path)
    if not set(REQUIRED) <= set(original.column_names) or original.num_rows == 0:
        raise ValueError("Missing input columns or empty dataset")
    rows = original.select(REQUIRED).to_pylist()
    keys = [(r["model_key"], r["prompt_id"], r["repetition"]) for r in rows]
    if any(any(v is None for v in key) for key in keys) or len(set(keys)) != len(keys):
        raise ValueError("Missing or duplicate model/prompt/repetition keys; inspect the audit")
    analyzer = SentimentIntensityAnalyzer()
    start = time.perf_counter()
    results = score_rows(rows, analyzer, config, progress=True)
    elapsed = time.perf_counter() - start
    scored = metrics_table(results)
    merged = original
    for name in scored.column_names:
        if name in original.column_names:
            raise ValueError(f"Metric column already present: {name}")
        merged = merged.append_column(name, scored[name])
    assert merged.select(original.column_names).equals(original)
    temp = output_path.with_suffix(".tmp.parquet")
    pq.write_table(merged, temp)
    loaded = pq.read_table(temp)
    if not loaded.equals(merged):
        raise ValueError("Parquet round-trip mismatch")
    temp.replace(output_path)
    out.mkdir(parents=True, exist_ok=True)
    counts = Counter((metric, r["model_key"], r["domain"], r["category"],
                      s[metric + "_status"], s[metric + "_reason"] or "")
                     for r, s in zip(rows, results) for metric in ("sentiment", "gender_unigram"))
    with (out / "copertura_metriche.csv").open("w", encoding="utf-8-sig", newline="") as f:
        writer = csv.writer(f)
        writer.writerow(["metric", "model_key", "domain", "category", "status", "reason", "n_records"])
        writer.writerows([*key, value] for key, value in sorted(counts.items()))
    package_dir = Path(inspect.getfile(SentimentIntensityAnalyzer)).parent
    provenance = {str(p.name): digest(p) for p in package_dir.glob("*.txt")}
    provenance["vaderSentiment.py"] = digest(inspect.getfile(SentimentIntensityAnalyzer))
    metadata = dict(run=args.run, config=config, input_file=str(input_path), input_sha256=digest(input_path),
                    output_file=str(output_path), output_sha256=digest(output_path),
                    config_sha256=digest(args.config), script_sha256=digest(__file__),
                    created_at=datetime.now(timezone.utc).isoformat(), scoring_seconds=elapsed,
                    rows=len(rows), original_columns_preserved=True, parquet_roundtrip_verified=True,
                    sentiment_scored=sum(s["sentiment_status"] == "scored" for s in results),
                    gender_unigram_scored=sum(s["gender_unigram_status"] == "scored" for s in results),
                    python=platform.python_version(), pyarrow=pa.__version__,
                    vader_version=importlib.metadata.version("vaderSentiment"), vader_files_sha256=provenance,
                    pending_metrics=["toxicity", "regard", "psycholinguistic_norms", "gender_wavg", "gender_max"],
                    limitations=["Automatic language/anonymization eligibility, not manually validated",
                                 "Full anonymized prompt+continuation; not a verified exact BOLD preprocessing replica",
                                 "Positive unigram ties kept separately as mixed_tie; paper underspecifies this case",
                                 "Quiz detection flag preserved; no score inversion; no model comparisons yet"])
    (out / "metriche_metadata.json").write_text(json.dumps(metadata, ensure_ascii=False, indent=2), encoding="utf-8")
    print(f"Completato in {elapsed:.1f} s: sentiment={metadata['sentiment_scored']}, "
          f"gender_unigram={metadata['gender_unigram_scored']}", flush=True)
    print(f"Punteggi: {output_path}")


if __name__ == "__main__":
    main()
