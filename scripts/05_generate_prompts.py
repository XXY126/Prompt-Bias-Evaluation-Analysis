"""Genera continuazioni dei prompt BOLD con i modelli Qwen3 locali.

Il protocollo primario passa al tokenizer esattamente il testo del prompt:
non applica chat template, system prompt, istruzioni o esempi few-shot.
La condizione instruction_prefix aggiunge un prefisso testuale configurato.
I due modelli vengono caricati e scaricati dalla GPU uno alla volta.
"""

from __future__ import annotations

import argparse
import gc
import hashlib
import importlib.metadata
import json
import os
import platform
import random
import subprocess
import sys
import time
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Any, Iterable

import yaml

from sentence_completion import POLICY as SENTENCE_POLICY, make_sentence_stopper, trim_sentence


REPO_ROOT = Path(__file__).resolve().parent.parent
DEFAULT_MODELS_CONFIG = REPO_ROOT / "configs" / "models.yaml"
DEFAULT_GENERATION_CONFIG = REPO_ROOT / "configs" / "generation.yaml"


@dataclass(frozen=True)
class PromptOccurrence:
    prompt_id: str
    record_order: int
    dataset_row: int
    source_file: str
    domain: str
    category: str
    subject: str
    prompt_index: int
    prompt: str
    repetition: int


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Generazione BOLD raw o con prefisso testuale con Qwen3."
    )
    parser.add_argument(
        "--config",
        type=Path,
        default=DEFAULT_GENERATION_CONFIG,
        help="Configurazione dell'esperimento YAML.",
    )
    parser.add_argument(
        "--models-config",
        type=Path,
        default=DEFAULT_MODELS_CONFIG,
        help="Configurazione dei modelli YAML.",
    )
    parser.add_argument(
        "--models",
        nargs="+",
        help="Chiavi dei modelli da eseguire. Default: tutti quelli configurati.",
    )
    parser.add_argument(
        "--run-name",
        help="Nome alternativo della run, utile per pilot separati.",
    )
    parser.add_argument(
        "--limit",
        type=int,
        help="Usa solo le prime N occorrenze (pilot; non campiona casualmente).",
    )
    parser.add_argument(
        "--batch-size",
        type=int,
        help="Override della dimensione batch configurata.",
    )
    parser.add_argument(
        "--repetitions",
        type=int,
        help="Override del numero di generazioni per prompt.",
    )
    parser.add_argument(
        "--validate-only",
        action="store_true",
        help="Valida configurazione, prompt e snapshot senza caricare i modelli.",
    )
    return parser.parse_args()


def resolve_repo_path(path_value: str | Path) -> Path:
    path = Path(path_value)
    return path if path.is_absolute() else REPO_ROOT / path


def load_yaml(path: Path) -> dict[str, Any]:
    with path.open(encoding="utf-8") as file:
        value = yaml.safe_load(file)
    if not isinstance(value, dict):
        raise ValueError(f"Il file YAML non contiene un oggetto: {path}")
    return value


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as file:
        for chunk in iter(lambda: file.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def sha256_json(value: Any) -> str:
    canonical = json.dumps(
        value, ensure_ascii=False, sort_keys=True, separators=(",", ":")
    )
    return hashlib.sha256(canonical.encode("utf-8")).hexdigest()


def stable_prompt_id(
    source_file: str,
    category: str,
    subject: str,
    prompt_index: int,
    prompt: str,
) -> str:
    identity = [source_file, category, subject, prompt_index, prompt]
    return sha256_json(identity)[:20]


def domain_from_filename(filename: str) -> str:
    stem = Path(filename).stem
    return stem.removesuffix("_prompt")


def build_model_input(prompt: str, experiment_config: dict[str, Any]) -> str:
    """Mantiene il prompt BOLD alla fine dell'input, senza modificarlo."""
    mode = experiment_config.get("prompt_mode")
    prefix = experiment_config.get("instruction_prefix", "")
    if mode == "raw":
        if prefix != "":
            raise ValueError("prompt_mode raw non consente instruction_prefix.")
        return prompt
    if mode == "instruction_prefix":
        if not isinstance(prefix, str) or not prefix.strip():
            raise ValueError("instruction_prefix richiede un prefisso testuale non vuoto.")
        return prefix + prompt
    raise ValueError("prompt_mode deve essere raw oppure instruction_prefix.")


def load_prompt_occurrences(
    prompt_dir: Path,
    repetitions: int,
    limit: int | None,
) -> tuple[list[PromptOccurrence], dict[str, str], int]:
    if repetitions < 1:
        raise ValueError("repetitions deve essere almeno 1.")
    if limit is not None and limit < 1:
        raise ValueError("limit deve essere almeno 1.")

    prompt_files = sorted(prompt_dir.glob("*.json"))
    if not prompt_files:
        raise FileNotFoundError(f"Nessun JSON trovato in {prompt_dir}")

    base_occurrences: list[dict[str, Any]] = []
    source_hashes: dict[str, str] = {}

    for path in prompt_files:
        source_hashes[path.name] = sha256_file(path)
        with path.open(encoding="utf-8") as file:
            data = json.load(file)

        if not isinstance(data, dict):
            raise ValueError(f"La radice di {path.name} deve essere un oggetto JSON.")

        for category, subjects in data.items():
            if not isinstance(subjects, dict):
                raise ValueError(
                    f"{path.name}/{category}: atteso un oggetto di soggetti."
                )
            for subject, prompts in subjects.items():
                if not isinstance(prompts, list):
                    raise ValueError(
                        f"{path.name}/{category}/{subject}: attesa una lista."
                    )
                for prompt_index, prompt in enumerate(prompts, start=1):
                    if not isinstance(prompt, str):
                        raise ValueError(
                            f"{path.name}/{category}/{subject}/{prompt_index}: "
                            "il prompt non e' una stringa."
                        )
                    base_occurrences.append(
                        {
                            "source_file": path.name,
                            "domain": domain_from_filename(path.name),
                            "category": category,
                            "subject": subject,
                            "prompt_index": prompt_index,
                            "prompt": prompt,
                        }
                    )

    total_prompt_count = len(base_occurrences)
    if limit is not None:
        base_occurrences = base_occurrences[:limit]

    occurrences: list[PromptOccurrence] = []
    record_order = 0
    for dataset_row, item in enumerate(base_occurrences, start=1):
        prompt_id = stable_prompt_id(
            item["source_file"],
            item["category"],
            item["subject"],
            item["prompt_index"],
            item["prompt"],
        )
        for repetition in range(1, repetitions + 1):
            record_order += 1
            occurrences.append(
                PromptOccurrence(
                    prompt_id=prompt_id,
                    record_order=record_order,
                    dataset_row=dataset_row,
                    repetition=repetition,
                    **item,
                )
            )

    return occurrences, source_hashes, total_prompt_count


def validate_model_snapshot(model_key: str, model_config: dict[str, Any]) -> Path:
    if "repo_id" not in model_config or "local_path" not in model_config:
        raise ValueError(
            f"Il modello {model_key} richiede repo_id e local_path in models.yaml."
        )

    model_path = resolve_repo_path(model_config["local_path"])
    required = [
        model_path / "config.json",
        model_path / "tokenizer_config.json",
        model_path / "model.safetensors.index.json",
    ]
    missing = [str(path) for path in required if not path.is_file()]
    shards = sorted(model_path.glob("*.safetensors"))
    if not shards:
        missing.append(str(model_path / "*.safetensors"))
    if missing:
        raise FileNotFoundError(
            f"Snapshot incompleto per {model_key}: " + ", ".join(missing)
        )
    return model_path


def huggingface_commit(model_path: Path) -> str | None:
    metadata = (
        model_path
        / ".cache"
        / "huggingface"
        / "download"
        / "config.json.metadata"
    )
    if not metadata.is_file():
        return None
    first_line = metadata.read_text(encoding="utf-8").splitlines()[0].strip()
    return first_line or None


def model_manifest(model_path: Path) -> dict[str, Any]:
    shards = sorted(model_path.glob("*.safetensors"))
    return {
        "huggingface_commit": huggingface_commit(model_path),
        "config_sha256": sha256_file(model_path / "config.json"),
        "index_sha256": sha256_file(model_path / "model.safetensors.index.json"),
        "weight_files": [
            {"name": path.name, "bytes": path.stat().st_size} for path in shards
        ],
    }


def git_state() -> dict[str, Any]:
    try:
        commit = subprocess.run(
            ["git", "rev-parse", "HEAD"],
            cwd=REPO_ROOT,
            capture_output=True,
            text=True,
            check=True,
        ).stdout.strip()
        dirty = bool(
            subprocess.run(
                ["git", "status", "--porcelain"],
                cwd=REPO_ROOT,
                capture_output=True,
                text=True,
                check=True,
            ).stdout.strip()
        )
        return {"commit": commit, "dirty": dirty}
    except (FileNotFoundError, subprocess.CalledProcessError):
        return {"commit": None, "dirty": None}


def package_versions(names: Iterable[str]) -> dict[str, str | None]:
    versions: dict[str, str | None] = {}
    for name in names:
        try:
            versions[name] = importlib.metadata.version(name)
        except importlib.metadata.PackageNotFoundError:
            versions[name] = None
    return versions


def atomic_json_dump(value: Any, path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + ".tmp")
    with temporary.open("w", encoding="utf-8", newline="\n") as file:
        json.dump(value, file, ensure_ascii=False, indent=2)
        file.write("\n")
    os.replace(temporary, path)


def atomic_parquet_dump(records: list[dict[str, Any]], path: Path, pandas: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    ordered = sorted(records, key=lambda row: row["record_order"])
    dataframe = pandas.DataFrame(ordered)
    temporary = path.with_suffix(path.suffix + ".tmp")
    dataframe.to_parquet(temporary, index=False, engine="pyarrow")
    os.replace(temporary, path)


def load_checkpoint(path: Path, pandas: Any) -> dict[str, dict[str, Any]]:
    if not path.is_file():
        return {}
    dataframe = pandas.read_parquet(path)
    if "record_id" not in dataframe.columns:
        raise ValueError(f"Checkpoint senza record_id: {path}")
    if dataframe["record_id"].duplicated().any():
        raise ValueError(f"record_id duplicati nel checkpoint: {path}")
    records = dataframe.to_dict(orient="records")
    for row in records:
        for column in ["input_token_ids", "generated_token_ids"]:
            token_ids = row.get(column)
            if hasattr(token_ids, "tolist"):
                row[column] = token_ids.tolist()
        if pandas.isna(row.get("generation")):
            row["generation"] = None
    return {row["record_id"]: row for row in records}


def record_id(model_key: str, occurrence: PromptOccurrence) -> str:
    return f"{model_key}:{occurrence.prompt_id}:r{occurrence.repetition:03d}"


def batch_seed(base_seed: int, batch_index: int) -> int:
    return base_seed + batch_index


def set_batch_seed(seed: int, numpy: Any, torch: Any) -> None:
    random.seed(seed)
    numpy.random.seed(seed % (2**32))
    torch.manual_seed(seed)
    torch.cuda.manual_seed_all(seed)


def dtype_from_name(name: str, torch: Any) -> Any:
    mapping = {
        "bfloat16": torch.bfloat16,
        "float16": torch.float16,
        "float32": torch.float32,
    }
    if name not in mapping:
        raise ValueError(f"compute_dtype non supportato: {name}")
    return mapping[name]


def load_runtime() -> dict[str, Any]:
    os.environ.setdefault("TOKENIZERS_PARALLELISM", "false")
    try:
        import numpy
        import pandas
        import torch
        from transformers import AutoModelForCausalLM, AutoTokenizer
        from transformers import BitsAndBytesConfig
        from transformers import StoppingCriteria, StoppingCriteriaList
    except ImportError as error:
        raise RuntimeError(
            "Dipendenze Python mancanti. Installa requirements.txt "
            "nell'ambiente dedicato."
        ) from error

    return {
        "numpy": numpy,
        "pandas": pandas,
        "torch": torch,
        "AutoModelForCausalLM": AutoModelForCausalLM,
        "AutoTokenizer": AutoTokenizer,
        "BitsAndBytesConfig": BitsAndBytesConfig,
        "StoppingCriteria": StoppingCriteria,
        "StoppingCriteriaList": StoppingCriteriaList,
    }


def build_signature(
    model_key: str,
    model_config: dict[str, Any],
    model_path: Path,
    experiment_config: dict[str, Any],
    generation_config: dict[str, Any],
    runtime_config: dict[str, Any],
    quantization_config: dict[str, Any],
    source_hashes: dict[str, str],
    run_name: str,
    limit: int | None,
) -> tuple[str, dict[str, Any]]:
    payload = {
        "implementation_sha256": sha256_file(Path(__file__).resolve()),
        "model_key": model_key,
        "repo_id": model_config["repo_id"],
        "training_stage": model_config.get("training_stage"),
        "model_manifest": model_manifest(model_path),
        "run_name": run_name,
        "prompt_mode": experiment_config["prompt_mode"],
        "repetitions": experiment_config["repetitions"],
        "base_seed": experiment_config["base_seed"],
        "limit": limit,
        "generation": generation_config,
        "runtime": runtime_config,
        "quantization": quantization_config,
        "source_sha256": source_hashes,
    }
    if experiment_config["prompt_mode"] == "instruction_prefix":
        payload["instruction_prefix"] = experiment_config["instruction_prefix"]
    if generation_config.get("sentence_stop"):
        payload["sentence_implementation_sha256"] = sha256_file(
            Path(__file__).with_name("sentence_completion.py")
        )
    return sha256_json(payload), payload


def validate_resume_metadata(metadata_path: Path, signature: str) -> None:
    if not metadata_path.is_file():
        return
    with metadata_path.open(encoding="utf-8") as file:
        previous = json.load(file)
    previous_signature = previous.get("experiment_signature")
    if previous_signature != signature:
        raise RuntimeError(
            f"La configurazione non coincide con la run esistente in "
            f"{metadata_path.parent}. Usa un nuovo --run-name."
        )


def detect_completion(
    generated_ids: list[int], eos_token_ids: set[int]
) -> tuple[int, str]:
    for index, token_id in enumerate(generated_ids):
        if token_id in eos_token_ids:
            return index, "eos_token"
    return len(generated_ids), "max_new_tokens"


def generate_model(
    model_key: str,
    model_config: dict[str, Any],
    model_path: Path,
    occurrences: list[PromptOccurrence],
    source_hashes: dict[str, str],
    experiment_config: dict[str, Any],
    generation_config: dict[str, Any],
    runtime_config: dict[str, Any],
    quantization_settings: dict[str, Any],
    output_root: Path,
    run_name: str,
    limit: int | None,
    runtime: dict[str, Any],
) -> None:
    numpy = runtime["numpy"]
    pandas = runtime["pandas"]
    torch = runtime["torch"]
    AutoModelForCausalLM = runtime["AutoModelForCausalLM"]
    AutoTokenizer = runtime["AutoTokenizer"]
    BitsAndBytesConfig = runtime["BitsAndBytesConfig"]

    if not torch.cuda.is_available():
        raise RuntimeError("CUDA non e' disponibile: la generazione richiede la GPU NVIDIA.")

    compute_dtype_name = quantization_settings["compute_dtype"]
    compute_dtype = dtype_from_name(compute_dtype_name, torch)
    if compute_dtype is torch.bfloat16 and not torch.cuda.is_bf16_supported():
        raise RuntimeError(
            "La configurazione richiede bfloat16, ma la GPU/runtime non lo supporta."
        )

    signature, signature_payload = build_signature(
        model_key,
        model_config,
        model_path,
        experiment_config,
        generation_config,
        runtime_config,
        quantization_settings,
        source_hashes,
        run_name,
        limit,
    )

    model_output_dir = output_root / run_name / model_key
    checkpoint_path = model_output_dir / "generations.parquet"
    metadata_path = model_output_dir / "metadata.json"
    validate_resume_metadata(metadata_path, signature)

    records_by_id = load_checkpoint(checkpoint_path, pandas)
    valid_ids = {record_id(model_key, occurrence) for occurrence in occurrences}
    unexpected_ids = set(records_by_id) - valid_ids
    if unexpected_ids:
        raise RuntimeError(
            f"Il checkpoint contiene {len(unexpected_ids)} record inattesi. "
            "Usa un nuovo --run-name."
        )

    metadata: dict[str, Any] = {
        "status": "loading_model",
        "experiment_signature": signature,
        "protocol": signature_payload,
        "records_expected": len(occurrences),
        "records_completed": len(records_by_id),
        "created_or_resumed_at": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
        "software": {
            "python": platform.python_version(),
            "platform": platform.platform(),
            "packages": package_versions(
                [
                    "torch",
                    "transformers",
                    "accelerate",
                    "bitsandbytes",
                    "pandas",
                    "pyarrow",
                    "PyYAML",
                ]
            ),
        },
        "git": git_state(),
        "gpu": {
            "name": torch.cuda.get_device_name(0),
            "cuda_runtime": torch.version.cuda,
        },
    }
    atomic_json_dump(metadata, metadata_path)

    print(f"\n[{model_key}] Caricamento da {model_path}")
    torch.cuda.reset_peak_memory_stats()
    tokenizer = None
    model = None
    try:
        bnb_config = BitsAndBytesConfig(
            load_in_4bit=bool(quantization_settings["load_in_4bit"]),
            bnb_4bit_quant_type=quantization_settings["quant_type"],
            bnb_4bit_use_double_quant=bool(quantization_settings["double_quant"]),
            bnb_4bit_compute_dtype=compute_dtype,
        )
        tokenizer = AutoTokenizer.from_pretrained(
            model_path,
            local_files_only=True,
            use_fast=True,
        )
        tokenizer.padding_side = "left"
        if tokenizer.pad_token_id is None:
            tokenizer.pad_token = tokenizer.eos_token

        model = AutoModelForCausalLM.from_pretrained(
            model_path,
            local_files_only=True,
            device_map={"": 0},
            quantization_config=bnb_config,
            dtype=compute_dtype,
            low_cpu_mem_usage=True,
            attn_implementation=runtime_config["attention_implementation"],
        )
        model.eval()
    except BaseException as error:
        metadata["status"] = "failed"
        metadata["error"] = f"{type(error).__name__}: {error}"
        metadata["failed_at"] = time.strftime("%Y-%m-%dT%H:%M:%S%z")
        atomic_json_dump(metadata, metadata_path)
        del model
        del tokenizer
        gc.collect()
        torch.cuda.empty_cache()
        raise

    input_device = model.get_input_embeddings().weight.device
    eos_value = model.generation_config.eos_token_id
    if isinstance(eos_value, int):
        eos_token_ids = {eos_value}
    elif eos_value is None:
        eos_token_ids = {tokenizer.eos_token_id}
    else:
        eos_token_ids = set(eos_value)

    batch_size = int(runtime_config["batch_size"])
    checkpoint_every = int(runtime_config["checkpoint_every_batches"])
    total_batches = (len(occurrences) + batch_size - 1) // batch_size
    metadata["status"] = "generating"
    metadata["model_memory_bytes"] = int(model.get_memory_footprint())
    atomic_json_dump(metadata, metadata_path)

    try:
        for batch_index, start in enumerate(range(0, len(occurrences), batch_size)):
            batch = occurrences[start : start + batch_size]
            batch_ids = [record_id(model_key, occurrence) for occurrence in batch]
            if all(item_id in records_by_id for item_id in batch_ids):
                print(
                    f"[{model_key}] Batch {batch_index + 1}/{total_batches}: "
                    "gia' presente"
                )
                continue

            seed = batch_seed(int(experiment_config["base_seed"]), batch_index)
            set_batch_seed(seed, numpy, torch)
            new_records: list[dict[str, Any]] = []
            nonempty = [
                (occurrence, item_id)
                for occurrence, item_id in zip(batch, batch_ids, strict=True)
                if occurrence.prompt.strip()
            ]
            empty = [
                (occurrence, item_id)
                for occurrence, item_id in zip(batch, batch_ids, strict=True)
                if not occurrence.prompt.strip()
            ]

            elapsed = 0.0
            if nonempty:
                prompts = [
                    build_model_input(occurrence.prompt, experiment_config)
                    for occurrence, _ in nonempty
                ]
                encoded = tokenizer(
                    prompts,
                    add_special_tokens=False,
                    padding=True,
                    return_attention_mask=True,
                    return_tensors="pt",
                )
                encoded = {
                    key: value.to(input_device) for key, value in encoded.items()
                }
                padded_input_length = encoded["input_ids"].shape[1]
                input_lengths = encoded["attention_mask"].sum(dim=1).tolist()
                input_token_rows = encoded["input_ids"].tolist()

                sentence_stopper = None
                extra_generation = {}
                if generation_config.get("sentence_stop") == SENTENCE_POLICY:
                    sentence_stopper = make_sentence_stopper(
                        tokenizer, [occ.prompt for occ, _ in nonempty],
                        padded_input_length, torch, runtime["StoppingCriteria"],
                    )
                    extra_generation = {
                        "stopping_criteria": runtime["StoppingCriteriaList"]([sentence_stopper]),
                        "num_return_sequences": 1,
                        "num_beams": 1,
                    }

                torch.cuda.synchronize()
                started = time.perf_counter()
                with torch.inference_mode():
                    output_ids = model.generate(
                        **encoded,
                        do_sample=bool(generation_config["do_sample"]),
                        temperature=float(generation_config["temperature"]),
                        top_k=int(generation_config["top_k"]),
                        top_p=float(generation_config["top_p"]),
                        repetition_penalty=float(
                            generation_config["repetition_penalty"]
                        ),
                        max_new_tokens=int(generation_config["max_new_tokens"]),
                        pad_token_id=tokenizer.pad_token_id,
                        eos_token_id=sorted(eos_token_ids),
                        use_cache=True,
                        **extra_generation,
                    )
                torch.cuda.synchronize()
                elapsed = time.perf_counter() - started

                new_token_rows = output_ids[:, padded_input_length:].tolist()
                for row_index, (
                    (occurrence, item_id),
                    input_length,
                    padded_input_ids,
                    token_ids,
                ) in enumerate(zip(
                    nonempty,
                    input_lengths,
                    input_token_rows,
                    new_token_rows,
                    strict=True,
                )):
                    input_length = int(input_length)
                    input_token_ids = padded_input_ids[-input_length:]
                    decoded_prompt = tokenizer.decode(
                        input_token_ids,
                        skip_special_tokens=False,
                        clean_up_tokenization_spaces=False,
                    )
                    model_input = build_model_input(occurrence.prompt, experiment_config)
                    roundtrip_matches = decoded_prompt == model_input
                    sentence_stopped = (sentence_stopper is not None and
                                        sentence_stopper.stop_lengths[row_index] is not None)
                    if sentence_stopped:
                        # Exclude padding appended while other batch rows continue.
                        token_ids = token_ids[:sentence_stopper.stop_lengths[row_index]]
                    generated_token_count, finish_reason = detect_completion(
                        token_ids, eos_token_ids
                    )
                    content_token_ids = token_ids[:generated_token_count]
                    generation = tokenizer.decode(
                        content_token_ids,
                        skip_special_tokens=True,
                        clean_up_tokenization_spaces=False,
                    )
                    row = asdict(occurrence)
                    row.update(
                        {
                            "record_id": item_id,
                            "model_key": model_key,
                            "repo_id": model_config["repo_id"],
                            "training_stage": model_config.get("training_stage"),
                            "prompt_mode": experiment_config["prompt_mode"],
                            "model_input": model_input,
                            "batch_index": batch_index,
                            "batch_seed": seed,
                            "input_tokens": input_length,
                            "input_token_ids": input_token_ids,
                            "decoded_input": decoded_prompt,
                            "tokenizer_roundtrip_matches": roundtrip_matches,
                            "generated_tokens": generated_token_count,
                            "generated_token_ids": content_token_ids,
                            "finish_reason": finish_reason,
                            "generation": generation,
                            "batch_elapsed_seconds": elapsed,
                            "status": "ok",
                        }
                    )
                    if generation_config.get("sentence_stop") == SENTENCE_POLICY:
                        raw_generation = generation
                        generation, sentence_end_char = trim_sentence(occurrence.prompt, raw_generation)
                        stop_reason = "sentence_end" if sentence_stopped and finish_reason != "eos_token" else finish_reason
                        row.update({
                            "generation_raw": raw_generation,
                            "generation": generation,
                            "generation_stop_reason": stop_reason,
                            "generation_hit_token_limit": generated_token_count >= int(generation_config["max_new_tokens"]),
                            "finish_reason": "sentence_end" if sentence_end_char is not None else finish_reason,
                            "sentence_complete": sentence_end_char is not None,
                            "sentence_stop_policy": SENTENCE_POLICY,
                            "sentence_end_char": sentence_end_char,
                            "sentence_trimmed_chars": len(raw_generation) - len(generation),
                        })
                    new_records.append(row)

            for occurrence, item_id in empty:
                row = asdict(occurrence)
                row.update(
                    {
                        "record_id": item_id,
                        "model_key": model_key,
                        "repo_id": model_config["repo_id"],
                        "training_stage": model_config.get("training_stage"),
                        "prompt_mode": experiment_config["prompt_mode"],
                        "model_input": None,
                        "batch_index": batch_index,
                        "batch_seed": seed,
                        "input_tokens": 0,
                        "input_token_ids": [],
                        "decoded_input": "",
                        "tokenizer_roundtrip_matches": True,
                        "generated_tokens": 0,
                        "generated_token_ids": [],
                        "finish_reason": "not_generated_empty_prompt",
                        "generation": None,
                        "batch_elapsed_seconds": elapsed,
                        "status": "skipped_empty_prompt",
                    }
                )
                if generation_config.get("sentence_stop") == SENTENCE_POLICY:
                    row.update({
                        "generation_raw": None, "generation_stop_reason": "not_generated_empty_prompt",
                        "generation_hit_token_limit": False,
                        "sentence_complete": None, "sentence_stop_policy": SENTENCE_POLICY,
                        "sentence_end_char": None, "sentence_trimmed_chars": 0,
                    })
                new_records.append(row)

            for item_id in batch_ids:
                records_by_id.pop(item_id, None)
            records_by_id.update({row["record_id"]: row for row in new_records})

            completed = len(records_by_id)
            skipped = sum(
                row.get("status") == "skipped_empty_prompt"
                for row in records_by_id.values()
            )
            print(
                f"[{model_key}] Batch {batch_index + 1}/{total_batches}: "
                f"{completed}/{len(occurrences)} record, "
                f"{skipped} vuoti saltati, {elapsed:.2f}s"
            )
            if (batch_index + 1) % checkpoint_every == 0:
                atomic_parquet_dump(list(records_by_id.values()), checkpoint_path, pandas)
                metadata["records_completed"] = completed
                metadata["records_skipped_empty"] = skipped
                metadata["records_roundtrip_mismatch"] = sum(
                    row.get("tokenizer_roundtrip_matches") is False
                    for row in records_by_id.values()
                )
                metadata["last_checkpoint_at"] = time.strftime(
                    "%Y-%m-%dT%H:%M:%S%z"
                )
                atomic_json_dump(metadata, metadata_path)

        atomic_parquet_dump(list(records_by_id.values()), checkpoint_path, pandas)
        export_nested_json(
            occurrences,
            records_by_id,
            model_key,
            model_output_dir / "nested",
        )
        metadata["status"] = "complete"
        metadata["records_completed"] = len(records_by_id)
        metadata["records_skipped_empty"] = sum(
            row.get("status") == "skipped_empty_prompt"
            for row in records_by_id.values()
        )
        metadata["records_roundtrip_mismatch"] = sum(
            row.get("tokenizer_roundtrip_matches") is False
            for row in records_by_id.values()
        )
        metadata["completed_at"] = time.strftime("%Y-%m-%dT%H:%M:%S%z")
        metadata["peak_gpu_memory_bytes"] = int(torch.cuda.max_memory_allocated())
        atomic_json_dump(metadata, metadata_path)
    except BaseException as error:
        if records_by_id:
            atomic_parquet_dump(list(records_by_id.values()), checkpoint_path, pandas)
        metadata["status"] = "failed"
        metadata["records_completed"] = len(records_by_id)
        metadata["error"] = f"{type(error).__name__}: {error}"
        metadata["failed_at"] = time.strftime("%Y-%m-%dT%H:%M:%S%z")
        atomic_json_dump(metadata, metadata_path)
        raise
    finally:
        del model
        del tokenizer
        gc.collect()
        torch.cuda.empty_cache()


def export_nested_json(
    occurrences: list[PromptOccurrence],
    records_by_id: dict[str, dict[str, Any]],
    model_key: str,
    output_dir: Path,
) -> None:
    repetitions = sorted({occurrence.repetition for occurrence in occurrences})
    source_files = sorted({occurrence.source_file for occurrence in occurrences})

    for repetition in repetitions:
        for source_file in source_files:
            selected = [
                occurrence
                for occurrence in occurrences
                if occurrence.repetition == repetition
                and occurrence.source_file == source_file
            ]
            if not selected:
                continue

            nested: dict[str, dict[str, list[str | None]]] = {}
            for occurrence in selected:
                nested.setdefault(occurrence.category, {}).setdefault(
                    occurrence.subject, []
                )
                item_id = record_id(model_key, occurrence)
                record = records_by_id.get(item_id)
                generation = None if record is None else record.get("generation")
                nested[occurrence.category][occurrence.subject].append(generation)

            filename = f"{Path(source_file).stem}_rep{repetition:03d}.json"
            atomic_json_dump(nested, output_dir / filename)


def validate_configuration(
    generation_file: Path,
    models_file: Path,
    args: argparse.Namespace,
) -> tuple[
    dict[str, Any],
    dict[str, dict[str, Any]],
    list[PromptOccurrence],
    dict[str, str],
    int,
    str,
    Path,
]:
    config = load_yaml(generation_file)
    models_document = load_yaml(models_file)

    for section in ["experiment", "generation", "runtime", "quantization"]:
        if section not in config or not isinstance(config[section], dict):
            raise ValueError(f"Sezione mancante nella configurazione: {section}")

    build_model_input("", config["experiment"])
    if config["generation"].get("sentence_stop") not in (None, SENTENCE_POLICY):
        raise ValueError(f"sentence_stop deve essere assente oppure {SENTENCE_POLICY}.")
    if config["experiment"].get("empty_prompt_policy") != "preserve_and_skip":
        raise ValueError(
            "Questa versione richiede empty_prompt_policy: preserve_and_skip."
        )

    models = models_document.get("models")
    if not isinstance(models, dict) or not models:
        raise ValueError("Nessun modello configurato in models.yaml.")

    selected_keys = args.models or list(models)
    unknown = set(selected_keys) - set(models)
    if unknown:
        raise ValueError(f"Modelli non configurati: {', '.join(sorted(unknown))}")
    selected_models = {key: models[key] for key in selected_keys}

    if args.batch_size is not None:
        config["runtime"]["batch_size"] = args.batch_size
    if int(config["runtime"]["batch_size"]) < 1:
        raise ValueError("batch_size deve essere almeno 1.")
    if int(config["runtime"]["checkpoint_every_batches"]) < 1:
        raise ValueError("checkpoint_every_batches deve essere almeno 1.")

    if args.repetitions is not None:
        config["experiment"]["repetitions"] = args.repetitions
    repetitions = int(config["experiment"]["repetitions"])

    run_name = args.run_name or str(config["experiment"]["name"])
    if args.limit is not None and args.run_name is None:
        run_name = f"{run_name}_limit{args.limit}"

    prompt_dir = resolve_repo_path(config["experiment"]["prompt_dir"])
    output_root = resolve_repo_path(config["experiment"]["output_dir"])
    occurrences, source_hashes, total_prompt_count = load_prompt_occurrences(
        prompt_dir,
        repetitions,
        args.limit,
    )

    expected = int(config["experiment"]["expected_prompt_count"])
    if total_prompt_count != expected:
        raise ValueError(
            f"Attesi {expected} prompt, trovati {total_prompt_count}. "
            "Il dataset raw potrebbe essere cambiato."
        )

    for model_key, model_config in selected_models.items():
        validate_model_snapshot(model_key, model_config)

    return (
        config,
        selected_models,
        occurrences,
        source_hashes,
        total_prompt_count,
        run_name,
        output_root,
    )


def main() -> int:
    args = parse_args()
    generation_file = resolve_repo_path(args.config)
    models_file = resolve_repo_path(args.models_config)

    (
        config,
        selected_models,
        occurrences,
        source_hashes,
        total_prompt_count,
        run_name,
        output_root,
    ) = validate_configuration(generation_file, models_file, args)

    print("Validazione completata.")
    print(f"Prompt BOLD nel dataset: {total_prompt_count}")
    print(f"Record previsti nella run: {len(occurrences)}")
    print(f"Run: {run_name}")
    print(f"Modelli: {', '.join(selected_models)}")
    print(f"Output: {output_root / run_name}")
    print(f"Modalita' prompt: {config['experiment']['prompt_mode']} (nessun chat template)")
    if config["experiment"]["prompt_mode"] == "instruction_prefix":
        print("Prefisso:\n" + config["experiment"]["instruction_prefix"])
    empty_count = sum(not occurrence.prompt.strip() for occurrence in occurrences)
    print(f"Prompt vuoti conservati ma non generati: {empty_count}")

    if args.validate_only:
        return 0

    runtime = load_runtime()
    for model_key, model_config in selected_models.items():
        model_path = validate_model_snapshot(model_key, model_config)
        generate_model(
            model_key=model_key,
            model_config=model_config,
            model_path=model_path,
            occurrences=occurrences,
            source_hashes=source_hashes,
            experiment_config=config["experiment"],
            generation_config=config["generation"],
            runtime_config=config["runtime"],
            quantization_settings=config["quantization"],
            output_root=output_root,
            run_name=run_name,
            limit=args.limit,
            runtime=runtime,
        )

    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except KeyboardInterrupt:
        print("\nGenerazione interrotta dall'utente.", file=sys.stderr)
        raise SystemExit(130)
