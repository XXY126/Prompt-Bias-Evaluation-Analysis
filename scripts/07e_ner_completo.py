"""NER on all prepared gender/race texts. Original-text offsets, CPU, no generation."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import time


def clean_person_span(text, start, end):
    """Keep possessives outside the replacement, including curly apostrophes."""
    while start < end and text[start].isspace():
        start += 1
    while end > start and text[end - 1].isspace():
        end -= 1
    if re.search(r"['\u2019]s$", text[start:end], flags=re.IGNORECASE):
        end -= 2
    return start, end


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--run", default="bold_raw_v1_rep5")
    args = parser.parse_args()
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_.-]*", args.run):
        parser.error("Invalid run")
    import pyarrow as pa
    import pyarrow.parquet as pq
    import spacy
    root = Path(__file__).resolve().parents[1]
    out = root / "output" / "metriche" / args.run / "anonimizzazione_ner"
    input_path = out / "input_ner.parquet"
    rows = pq.read_table(input_path).to_pylist()
    spacy.require_cpu()
    start = time.perf_counter()
    nlp = spacy.load("en_core_web_sm", exclude=["tok2vec", "tagger", "parser", "attribute_ruler", "lemmatizer"])
    load_seconds = time.perf_counter() - start
    nlp("Alice Smith met John Brown.")
    records = []
    start = time.perf_counter()
    for i, doc in enumerate(nlp.pipe((r["text_full"] for r in rows), batch_size=64, n_process=1)):
        entities = []
        for ent in doc.ents:
            if ent.label_ != "PERSON":
                continue
            begin, end = clean_person_span(doc.text, ent.start_char, ent.end_char)
            if begin < end:
                entities.append(dict(start_char=begin, end_char=end, entity=doc.text[begin:end],
                                     raw_start_char=ent.start_char, raw_end_char=ent.end_char,
                                     raw_entity=ent.text))
        records.append(dict(text_id=rows[i]["text_id"], entities_json=json.dumps(entities, ensure_ascii=False)))
        if (i + 1) % 5000 == 0:
            print(f"NER {i + 1}/{len(rows)}; {time.perf_counter() - start:.1f} s", flush=True)
    seconds = time.perf_counter() - start
    result = out / "entita_ner.parquet"
    temp = out / "entita_ner.tmp.parquet"
    pq.write_table(pa.Table.from_pylist(records), temp)
    temp.replace(result)
    metadata = dict(model="en_core_web_sm", model_version=nlp.meta["version"],
                    spacy_version=spacy.__version__, pipeline=nlp.pipe_names, device="cpu",
                    batch_size=64, n_process=1, load_seconds=load_seconds,
                    inference_seconds=seconds, n_texts=len(records),
                    input_md5=hashlib.md5(input_path.read_bytes()).hexdigest(),
                    output_md5=hashlib.md5(result.read_bytes()).hexdigest(),
                    script_sha256=hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
                    offsets="zero-based Unicode character offsets; exclusive end; original text_full",
                    policy="PERSON only; trim outside whitespace and trailing possessive apostrophe-s")
    (out / "ner_metadata.json").write_text(json.dumps(metadata, indent=2), encoding="utf-8")
    print(f"Completato: {len(records)} testi in {seconds / 60:.2f} minuti", flush=True)


if __name__ == "__main__":
    main()
