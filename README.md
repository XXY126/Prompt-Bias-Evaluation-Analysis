# Prompt-Bias-Evaluation-Analysis

Analisi delle generazioni dei modelli sul dataset BOLD per il progetto di
Statistica e Analisi dei Dati.

## Struttura

```text
R/                  funzioni R riutilizzabili e setup comune
scripts/
  dati/             caricamento, pulizia ed EDA dei prompt
  generazione/      generatore Qwen e supporto frase singola
  audit/            audit dei prompt e delle generazioni
  metriche/         preparazione, NER, anonimizzazione e scoring
  esperimenti/      pilota NER e generazione Ollama
  setup/            verifica ambiente GPU e download modelli
tests/              test Python e R
legacy/             generatore storico per riprendere checkpoint v1/v2
configs/            configurazioni degli esperimenti e delle metriche
data/               dati originali, generazioni e dataset intermedi
output/             report, copertura e metadati
docs/               protocolli e documentazione tecnica
```

**La guida operativa è [scripts/README.md](scripts/README.md)**: contiene
l'ordine dei passaggi, gli input/output e la corrispondenza con i vecchi nomi.
I numeri ordinano i passaggi all'interno di una cartella; non bisogna eseguire
tutti gli script del repository in sequenza.

## Da dove iniziare

Aprire `Prompt-Bias-Evaluation-Analysis.Rproj` in RStudio oppure eseguire i
comandi dalla radice del repository.

- Per analizzare i prompt: `scripts/dati/` e `scripts/audit/audit_prompt.R`.
- Per generare nuove continuazioni: [protocollo di generazione](docs/generation_protocol.md).
  Il generatore legge i JSON originali in `data/raw/prompts/`; non richiede
  la pulizia o l'EDA R.
- Per analizzare generazioni esistenti: [audit](docs/audit_generazioni.md),
  poi i cinque passaggi di `scripts/metriche/` descritti nella guida operativa.
- Per ricostruire un Parquet mancante: consultare la tabella input/output
  nella guida e partire dal primo prerequisito disponibile.

Le dipendenze restano separate: `requirements.txt` per la generazione CUDA,
`requirements-ner.txt` per il NER e `requirements-metrics.txt` per lo scoring.
Gli script R dichiarano i pacchetti richiesti; `R/setup.R` prepara l'ambiente
dei primi passaggi sui prompt. Non serve l'ambiente CUDA per VADER e unigram.

## Convenzioni e stato delle metriche

I file in `R/` contengono le funzioni condivise, con l'eccezione del setup.
Gli script eseguibili leggono gli input e producono dataset o report.
Le configurazioni rimangono in `configs/`.

Preparazione, audit e scoring conservano le osservazioni originali; i problemi
sono annotati con flag. I punteggi delle righe escluse sono null, non zero.
Gli output derivati possono essere rigenerati dagli script: consultare il
protocollo prima di rieseguire una run già presente.

Sono implementati **sentiment VADER** e **gender unigram matching**.
**Toxicity, regard, psycholinguistic norms, Gender-Wavg e Gender-Max non sono
ancora implementati**, e sono elencati nei metadati dello scoring.

Per eseguire i test vedere [tests/README.md](tests/README.md).
