# Prova del riconoscimento di persone

Il pilota misura il tempo di un modello NER piccolo (`en_core_web_sm` 3.8.0,
spaCy 3.8, CPU) e produce esempi da controllare. Non modifica il dataset delle
metriche, il dizionario o i criteri di ammissibilita'.

## Esecuzione dalla radice del progetto (PowerShell)

L'ambiente Python e' separato da quello di Qwen. Installazione una sola volta:

```powershell
python -m venv .venv-ner
.\.venv-ner\Scripts\python.exe -m pip install -r requirements-ner.txt
```

Preparazione in R e inferenza in Python:

```powershell
& 'C:/Program Files/R/R-4.6.1/bin/Rscript.exe' scripts/07b_campione_ner.R bold_raw_v1_rep5 1000
.\.venv-ner\Scripts\python.exe scripts/07c_pilota_ner.py --run bold_raw_v1_rep5
```

R seleziona 1.000 righe casuali senza rimpiazzo (seed 42) tra i domini `gender`
e `race` con `eligible_english_metrics = TRUE`. L'assenza di Han non certifica
l'inglese. Quiz, righe in revisione per anonimizzazione e ripetizioni restano
campionabili. Nessuna deduplicazione dei dati: Python riusa il risultato solo
quando il testo completo e' identico, restituendo tutte le righe del campione.
Il caso Waylon Payne/Monte Hellman viene aggiunto come diagnostico se disponibile
e non gia' estratto; e' escluso dalla stima dei tempi del campione casuale.

Python analizza `text_full` originale (prompt + continuazione), in batch di 64
con un solo processo. Esegue solo il componente NER del modello indicato.
Registra tutte le entita', ma sostituisce solo quelle etichettate `PERSON` con
`Person` nella colonna sperimentale `text_ner_person_preview`.

Questa anteprima usa **solo NER**: il confronto con `text_anonymized`, che usa
il dizionario attuale, serve a capire i vantaggi e gli errori dei due metodi.
Non e' ancora la loro combinazione e non certifica l'anonimizzazione completa.
Nomi riconosciuti male possono lasciare persone visibili o eliminare altre parole.
Professioni, religioni e ideologie non sono oggetto di questo pilota.

## File e revisione

Directory: `output/metriche/bold_raw_v1_rep5/pilota_ner/`.

- `campione_input.parquet`, `campione_metadata.json`: campione, perimetro,
  numerosita', seed e hash dell'input.
- `confronto_testi.csv`, `risultati.parquet`: dati originali, anonimizzazione
  a dizionario e anteprima NER affiancate. `ner_person_count` conta le menzioni,
  non le persone distinte. `sample_kind` distingue casuali e diagnostico.
- `entita.csv`: una riga per menzione riconosciuta, inclusi gli altri tipi.
  `pilot_row_id` collega al confronto; `entity` e' il testo riconosciuto;
  `label` e' il tipo; `start_char` parte da zero e `end_char` e' esclusivo.
  Gli indici contano caratteri Unicode nel `text_full` originale, non byte e
  non posizioni nel testo sostituito. `replaced_in_preview` indica la sostituzione.
- `tempi_metadata.json`: caricamento, warm-up e inferenza separati, velocita',
  stima sul perimetro gender/race ammissibile, versioni dei pacchetti e hash.

Per la revisione **copiare prima** `confronto_testi.csv`: rilanciare il pilota
rigenera i report. Compilare `review_false_positives` con parole rimosse per
errore, `review_missed_people` con nomi rimasti, `review_notes` con altri dubbi.
Esaminare anche testi senza PERSON rilevate per individuare falsi negativi.
Il numero di PERSON rilevate non e' una misura di accuratezza: precisione e
richiamo richiedono annotazioni manuali delle menzioni corrette e mancanti.

La stima usa testi unici nel perimetro / testi al secondo nel campione casuale.
E' orientativa: esclude I/O e avvio, dipende da lunghezze e carico CPU e non va
estesa automaticamente agli altri domini o ai testi con Han.

Prima di integrare nelle metriche: verificare il campione, scegliere la regola
per combinare NER e dizionario e gestire le sovrapposizioni sugli indici del
testo originale; poi ricalcolare esplicitamente i flag di revisione.

Documentazione primaria: [modelli inglesi spaCy](https://spacy.io/models/en),
[pipeline e inferenza in batch](https://spacy.io/usage/processing-pipelines).

## Prima esecuzione (10 settembre 2026)

1.000 testi casuali elaborati in 4,24 secondi sulla CPU; caricamento del modello
0,40 secondi, import di spaCy 2,20 secondi. Stima di sola inferenza: 7,6 minuti
per 108.013 testi unici su 108.018 righe ammissibili gender/race.
Il diagnostico aggiuntivo porta il report a 1.001 righe.

Controllo esplorativo: il modello riconosce `Michael` nella continuazione su
Michael Zorek, dove il dizionario sostituisce solo il nome completo. Nel caso
Waylon Payne riconosce `Monte Hellman's` come PERSON (includendo impropriamente
il possessivo nell'intervallo sostituito) ma manca entrambe le menzioni di
Waylon Payne. Manca anche Alejandro Patino in un altro esempio.
Questi casi motivano l'integrazione con il dizionario e la verifica dei confini
delle entita'; non costituiscono una valutazione quantitativa dell'accuratezza.

Test sulla conservazione del testo e sugli indici:

```powershell
.\.venv-ner\Scripts\python.exe scripts/tests/test_pilota_ner.py
```
