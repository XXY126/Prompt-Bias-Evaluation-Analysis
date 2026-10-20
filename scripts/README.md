# Guida agli script

Eseguire i comandi dalla radice del repository. `python` indica l'interprete
dell'ambiente adatto allo step; su macOS/Linux può chiamarsi `python3`.
I percorsi di `data/`, `output/` e `configs/` non sono cambiati.

## Analisi di generazioni esistenti

Per la run `bold_raw_v1_rep5`, il percorso completo è:

```bash
Rscript scripts/audit/audit_generazioni.R bold_raw_v1_rep5
Rscript scripts/metriche/01_prepara_testi.R bold_raw_v1_rep5
Rscript scripts/metriche/02_prepara_ner.R bold_raw_v1_rep5
python scripts/metriche/03_esegui_ner.py --run bold_raw_v1_rep5
Rscript scripts/metriche/04_combina_anonimizzazione.R bold_raw_v1_rep5
python scripts/metriche/05_misura_metriche.py --run bold_raw_v1_rep5
```

L'audit richiede le generazioni originali della run. Se un passaggio è già
completato e i suoi output sono coerenti, partire dal successivo. Non eseguire
questa sequenza soltanto per verificare l'installazione: alcuni step riscrivono
i propri output derivati e il NER richiede inferenza e un modello installato.

Nella tabella, `M` è `data/processed/metriche/<run>/` e `N` è
`output/metriche/<run>/anonimizzazione_ner/`.

| Script | Input principale | Output principale |
| --- | --- | --- |
| `audit/audit_generazioni.R` | `data/generated/<run>/` e JSON BOLD | `output/audit/generazioni/<run>/generazioni_annotate.rds` |
| `metriche/01_prepara_testi.R` | `generazioni_annotate.rds` | `M/testi_metriche.rds` e `.parquet` |
| `metriche/02_prepara_ner.R` | `M/testi_metriche.rds` | `N/input_ner.parquet`, `N/input_metadata.json` |
| `metriche/03_esegui_ner.py` | `N/input_ner.parquet` | `N/entita_ner.parquet`, `N/ner_metadata.json` |
| `metriche/04_combina_anonimizzazione.R` | `M/testi_metriche.rds`, input/entità NER e metadati | `M/testi_metriche_anonimizzati.rds` e `.parquet` |
| `metriche/05_misura_metriche.py` | `M/testi_metriche_anonimizzati.parquet` | `M/punteggi_<version>.parquet`, copertura e metadati in `output/metriche/<run>/<version>/` |

**Se manca il Parquet per le metriche:** lo produce `04_combina_anonimizzazione.R`.
Se manca anche `testi_metriche.rds`, partire da `01_prepara_testi.R`.
Si possono riutilizzare risultati NER esistenti solo se corrispondono ai testi
ricostruiti: lo step 04 verifica gli hash. In caso di incompatibilità,
rieseguire 02 e 03 prima di 04; non disabilitare i controlli di provenienza.

Il pilota NER in `esperimenti/` è facoltativo e non è un prerequisito del NER
completo. Dettagli: [preparazione](../docs/preparazione_metriche.md),
[NER](../docs/anonimizzazione_ner.md), [scoring](../docs/misurazione_metriche.md).

Lo scoring implementa VADER e gender unigram. Toxicity, regard, psycholinguistic
norms, Gender-Wavg e Gender-Max restano non supportati.

## Prompt e nuove generazioni

- `dati/01_caricamento_dati.R`: JSON originali → `01_bold_raw.rds`.
- `audit/audit_prompt.R` e `audit/analisi_problemi_tecnici.R`: diagnostica del
  dataset grezzo, senza eliminare prompt; report in `output/audit/`.
- `dati/02_pulizia_prompt.R`: `01_bold_raw.rds` → `02_bold_pulito.rds`.
- `dati/03_eda_statistica.R`: `02_bold_pulito.rds` → EDA, tabelle e grafici.
- `setup/verifica_ambiente.py`: diagnostica dell'ambiente di generazione CUDA.
- `setup/download_modelli.py`: scarica i modelli di `configs/models.yaml`.
- `generazione/genera.py`: genera dai JSON originali con la configurazione
  selezionata. `sentence_completion.py` è un modulo di supporto, non uno step.

```bash
python scripts/generazione/genera.py --validate-only
python scripts/generazione/genera.py --config configs/generation_english_sentence.yaml --validate-only
```

Le configurazioni distinguono raw, prefisso e frase singola; non occorre
creare una nuova copia del generatore per ogni esperimento. Consultare il
[protocollo](../docs/generation_protocol.md) prima di avviare inferenza.

## Esperimenti, storico e compatibilità

`esperimenti/ollama.R` conserva il precedente percorso Ollama.
`esperimenti/campione_ner.R` e `esperimenti/pilota_ner.py` servono a valutare
il NER su un campione. Non fanno parte della pipeline principale.

`../legacy/05_generate_prompts_v2.py` conserva esattamente il codice precedente
alla frase singola per i checkpoint v1/v2. Non è una seconda implementazione
da mantenere o estendere. Vedere [legacy/README.md](../legacy/README.md).

Il generatore attuale ha un nuovo hash perché è cambiato il calcolo della
radice del progetto. I dataset esistenti restano leggibili dall'analisi, ma
per riprendere checkpoint prodotti dal precedente `05_generate_prompts.py`
serve quella revisione originale del repository; per nuove generazioni usare
un nuovo `--run-name`. I controlli sulla firma restano attivi.

I vecchi comandi `scripts/07...` e `scripts/08...` sono sostituiti da quelli
qui documentati. I metadati e i log già prodotti conservano i percorsi storici:
non sono stati riscritti. Anche i nomi dei file dati rimangono invariati.

## Corrispondenza con i vecchi percorsi

| Prima | Ora |
| --- | --- |
| `scripts/00_setup.py` | `scripts/setup/verifica_ambiente.py` |
| `scripts/04_download_models.py` | `scripts/setup/download_modelli.py` |
| `scripts/01_caricamento_dati.R` | `scripts/dati/01_caricamento_dati.R` |
| `scripts/pulizia_prompt.R` | `scripts/dati/02_pulizia_prompt.R` |
| `scripts/03_eda_statistica.R` | `scripts/dati/03_eda_statistica.R` |
| `scripts/02_data_quality_audit.R` | `scripts/audit/audit_prompt.R` |
| `scripts/02a_technical_issues_analysis.R` | `scripts/audit/analisi_problemi_tecnici.R` |
| `scripts/06_audit_generazioni.R` | `scripts/audit/audit_generazioni.R` |
| `scripts/05_generate_prompts.py` | `scripts/generazione/genera.py` |
| `scripts/sentence_completion.py` | `scripts/generazione/sentence_completion.py` |
| `scripts/07_prepara_metriche.R` | `scripts/metriche/01_prepara_testi.R` |
| `scripts/07d_prepara_ner_completo.R` | `scripts/metriche/02_prepara_ner.R` |
| `scripts/07e_ner_completo.py` | `scripts/metriche/03_esegui_ner.py` |
| `scripts/07f_combina_anonimizzazione.R` | `scripts/metriche/04_combina_anonimizzazione.R` |
| `scripts/08_misura_metriche.py` | `scripts/metriche/05_misura_metriche.py` |
| `scripts/04_generazione_ollama.R` | `scripts/esperimenti/ollama.R` |
| `scripts/07b_campione_ner.R` | `scripts/esperimenti/campione_ner.R` |
| `scripts/07c_pilota_ner.py` | `scripts/esperimenti/pilota_ner.py` |
| `scripts/05_generate_prompts_v2.py` | `legacy/05_generate_prompts_v2.py` |

I test sono stati spostati da `scripts/tests/` a `tests/`; vedere [tests/README.md](../tests/README.md).
