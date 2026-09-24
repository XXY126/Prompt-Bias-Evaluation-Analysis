"""Time a CPU NER pilot on original full texts; export reviewable PERSON previews.

Does not combine dictionaries or change metric eligibility. Offsets refer to
text_full, are zero-based Unicode character indices, with an exclusive end.
"""
import argparse
import csv
import hashlib
import importlib.metadata
import json
from pathlib import Path
import platform
import re
import time


def person_preview(text, entities):
    """Replace PERSON spans only, preserving all characters outside those spans."""
    spans = sorted((e for e in entities if e["label"] == "PERSON"),
                   key=lambda e: e["start_char"])
    parts, cursor = [], 0
    for ent in spans:
        start, end = ent["start_char"], ent["end_char"]
        if not (cursor <= start < end <= len(text)) or text[start:end] != ent["entity"]:
            raise ValueError("Invalid, overlapping or inconsistent entity offsets")
        parts.extend((text[cursor:start], "Person"))
        cursor = end
    return "".join(parts) + text[cursor:]


def write_csv(path, rows, fields):
    with path.open("w", encoding="utf-8-sig", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=fields, extrasaction="ignore")
        writer.writeheader()
        writer.writerows(rows)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--run", default="bold_raw_v1_rep5")
    parser.add_argument("--model", default="en_core_web_sm")
    parser.add_argument("--batch-size", type=int, default=64)
    args = parser.parse_args()
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_.-]*", args.run) or args.batch_size < 1:
        parser.error("Invalid run or batch size")
    root = Path(__file__).resolve().parents[1]
    out = root / "output" / "metriche" / args.run / "pilota_ner"
    input_path = out / "campione_input.parquet"
    if not input_path.exists():
        parser.error("Run scripts/07b_campione_ner.R first")

    import pyarrow as pa
    import pyarrow.parquet as pq

    rows = pq.read_table(input_path).to_pylist()
    sample_metadata = json.loads((out / "campione_metadata.json").read_text(encoding="utf-8"))
    if not rows or any(not isinstance(r["text_full"], str) or not r["text_full"] for r in rows):
        raise ValueError("Empty or invalid input texts")
    start = time.perf_counter()
    import spacy
    import_seconds = time.perf_counter() - start
    spacy.require_cpu()
    start = time.perf_counter()
    nlp = spacy.load(args.model, exclude=["tok2vec", "tagger", "parser", "attribute_ruler", "lemmatizer"])
    load_seconds = time.perf_counter() - start
    if nlp.pipe_names != ["ner"]:
        raise ValueError("Pilot expects a standalone NER pipeline (en_core_web_sm)")
    # Warm-up excluded from timed sample; no sample content is consumed here.
    start = time.perf_counter()
    nlp("Alice Smith met John Brown in London.")
    warmup_seconds = time.perf_counter() - start
    by_text = {}
    timings = {}
    for kind in ("random", "diagnostic"):
        texts = list(dict.fromkeys(r["text_full"] for r in rows
                                   if r["sample_kind"] == kind and r["text_full"] not in by_text))
        start = time.perf_counter()
        for doc in nlp.pipe(texts, batch_size=args.batch_size, n_process=1):
            by_text[doc.text] = [dict(entity=e.text, label=e.label_,
                                      start_char=e.start_char, end_char=e.end_char) for e in doc.ents]
        elapsed = time.perf_counter() - start
        timings[kind] = dict(unique_texts=len(texts), seconds=elapsed)
        print(f"{kind}: {len(texts)} testi in {elapsed:.2f} s", flush=True)

    results, entity_rows = [], []
    for row in rows:
        entities = by_text[row["text_full"]]
        result = dict(row)
        result.update(text_ner_person_preview=person_preview(row["text_full"], entities),
                      ner_person_count=sum(e["label"] == "PERSON" for e in entities),
                      review_false_positives="", review_missed_people="", review_notes="")
        results.append(result)
        for ent in entities:
            entity_rows.append(dict(pilot_row_id=row["pilot_row_id"], **ent,
                                    replaced_in_preview=ent["label"] == "PERSON"))
    pq.write_table(pa.Table.from_pylist(results), out / "risultati.parquet")
    write_csv(out / "confronto_testi.csv", results, list(results[0]))
    write_csv(out / "entita.csv", entity_rows,
              ["pilot_row_id", "entity", "label", "start_char", "end_char", "replaced_in_preview"])
    speed = timings["random"]["unique_texts"] / timings["random"]["seconds"]
    metadata = dict(
        model=args.model, model_version=nlp.meta["version"], spacy_version=spacy.__version__,
        device="cpu", batch_size=args.batch_size, n_process=1, pipeline=nlp.pipe_names,
        python=platform.python_version(), import_seconds=import_seconds,
        load_seconds=load_seconds, warmup_seconds=warmup_seconds, inference=timings,
        texts_per_second=speed,
        estimated_scope_inference_seconds=sample_metadata["scope_unique_texts"] / speed,
        estimate_note="Rough inference-only estimate for eligible gender/race, excluding I/O and startup; depends on text length and CPU load. No claim for other domains.",
        scope_unique_texts=sample_metadata["scope_unique_texts"], rows=len(results),
        rows_with_person=sum(r["ner_person_count"] > 0 for r in results),
        person_mentions=sum(r["ner_person_count"] for r in results),
        policy="NER-only PERSON preview; dictionary comparison separate; no eligibility changes",
        input_sha256=hashlib.sha256(input_path.read_bytes()).hexdigest(),
        script_sha256=hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
        packages={d.metadata["Name"]: d.version for d in importlib.metadata.distributions()},
    )
    (out / "tempi_metadata.json").write_text(json.dumps(metadata, ensure_ascii=False, indent=2), encoding="utf-8")
    print(f"Stima inferenza sul perimetro: {metadata['estimated_scope_inference_seconds'] / 60:.1f} minuti")
    print(f"Report: {out}")


if __name__ == "__main__":
    main()
