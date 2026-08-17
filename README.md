# Progetto BOLD — Bias Analysis (Statistica e Analisi dei Dati, Tipologia 1)

## Struttura del progetto

```
progetto_bold/
├── progetto_bold.Rproj        # apri SEMPRE questo file in RStudio (imposta la working directory)
├── data/
│   ├── raw/prompts/           # JSON originali di BOLD (scaricati da GitHub, NON modificare)
│   └── processed/             # output intermedi .rds tra uno step e l'altro
├── R/                         # funzioni riutilizzabili (NON eseguire direttamente)
│   ├── caricamento.R
│   ├── pulizia_testo.R
│   └── eda_statistica.R
├── scripts/                   # script eseguibili, IN ORDINE NUMERATO
│   ├── 00_setup.R
│   ├── 01_caricamento_dati.R
│   ├── 02_pulizia_prompt.R
│   └── 03_eda_statistica.R
├── output/
│   ├── figures/                # grafici esportati (.png)
│   └── tables/                 # tabelle esportate (.csv)
└── README.md
```

## Come eseguire il progetto

1. Scarica i file JSON di BOLD da https://github.com/amazon-science/bold
   e posizionali in `data/raw/prompts/` (nomi file: `gender_prompt.json`,
   `race_prompt.json`, `religious_ideology_prompt.json`,
   `profession_prompt.json`, `political_ideology_prompt.json`)

2. Apri `progetto_bold.Rproj` in RStudio (fondamentale: questo imposta
   automaticamente la working directory sulla radice del progetto,
   necessario per far funzionare `here::here()`)

3. Esegui gli script in `scripts/` **in ordine numerico**:
   ```r
   source("scripts/01_caricamento_dati.R")
   source("scripts/02_pulizia_prompt.R")
   source("scripts/03_eda_statistica.R")
   ```
   Oppure aprili singolarmente in RStudio ed eseguili con `Ctrl+Invio` /
   `Cmd+Invio` blocco per blocco.

4. Ogni script legge l'output `.rds` dello script precedente da
   `data/processed/` e produce a sua volta un nuovo `.rds` per lo
   script successivo — non serve rieseguire tutto da capo ogni volta.

## Convenzioni

- **`R/`** contiene solo *definizioni di funzioni*, mai codice che le esegue
  direttamente. Se trovi un bug in una funzione, correggilo lì: si propaga
  automaticamente a tutti gli script che la usano.
- **`scripts/`** contiene il codice che *esegue* le funzioni di `R/` e
  produce output (dataset intermedi, grafici, tabelle). Ogni script fa
  una cosa sola (caricamento, pulizia, EDA, ecc.).
- I dataset intermedi in `data/processed/` sono numerati come gli script
  che li producono, per rendere ovvia la corrispondenza.
- Duplicati, outlier e troncamenti sospetti nel testo vengono **flaggati,
  non rimossi automaticamente** — la decisione di eliminarli o tenerli va
  presa consapevolmente ispezionando i CSV in `output/tables/` e
  documentata nel report finale (coerente con OB1 della spec del corso).

## Prossimi step (da aggiungere)

- `scripts/04_generazione_gpt2.R` — generazione continuazioni con GPT-2
- `scripts/05_generazione_modello_offline.R` — generazione con modello
  offline aggiuntivo (es. Mistral-7B quantizzato, sul fisso con RTX 3080)
- `scripts/06_classificazione_toxicbert.R` — classificazione tossicità
  (via reticulate, richiama `unitary/toxic-bert` da Python)
- `scripts/07_prompt_sintetici_llm.R` — generazione prompt sintetici
  "più difficili" (OB2) e validazione statistica vs prompt reali
- `scripts/08_analisi_comparativa.R` — confronto finale tra modelli,
  categorie, prompt reali vs sintetici
