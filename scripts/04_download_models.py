from pathlib import Path

import yaml
from huggingface_hub import snapshot_download


CONFIG_PATH = Path("configs/models.yaml")
MODELS_DIR = Path("models")


# Carica la configurazione dei modelli dal file YAML.
with open(CONFIG_PATH, encoding="utf-8") as file:
    config = yaml.safe_load(file)


# Crea la directory models/ se non esiste già.
MODELS_DIR.mkdir(parents=True, exist_ok=True)


for model_name, model_config in config["models"].items():
    repo_id = model_config["repo_id"]
    destination = MODELS_DIR / model_name

    print(f"\nDownloading {model_name}")
    print(f"Repository: {repo_id}")
    print(f"Destination: {destination}")

    # Scarica uno snapshot completo del repository Hugging Face,
    # inclusi pesi, tokenizer e file di configurazione.
    snapshot_download(
        repo_id=repo_id,
        local_dir=destination,
    )


print("\nAll models downloaded.")