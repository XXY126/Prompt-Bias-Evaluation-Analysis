# Anonimizzazione completa: dizionario e NER

La versione `bold_dictionary_ner_v1` conserva tutte le righe di entrambi i
modelli e tutte le ripetizioni. Il dataset di partenza e le generazioni
originali non vengono sovrascritti.

## Perimetro

- `gender` e `race`: nomi noti dal dizionario piu' entita' `PERSON` trovate da
  spaCy `en_core_web_sm` 3.8.0 nel testo originale completo. Sostituzione: `Person`.
- Professioni, religioni e ideologie: il risultato del dizionario esistente
  viene conservato, con sostituzioni `XYZ` e relativi flag di revisione.
- Il NER viene eseguito anche sui testi gender/race contenenti Han; e' un
  modello inglese e non certifica il riconoscimento di nomi cinesi. Il filtro
  Han resta attivo, e queste righe restano escluse dalle metriche inglesi.
- Testi non preparabili restano presenti con testo completo anonimizzato NA.
  Domande, pronomi, negazioni e altri caratteri esterni alle entita' sono conservati.

## Abbinamento dei risultati

Gli indici delle due fonti si riferiscono sempre a `text_full` originale.
Gli intervalli del dizionario hanno precedenza. Un match NER gia' contenuto
in un match del dizionario e' coperto; se coincide esattamente, la provenienza
e' `dictionary+ner`. Un match NER separato aggiunge una sostituzione.
Un match NER che si sovrappone estendendo un match del dizionario viene scartato
e segnalato per revisione (`ner_dictionary_overlap`). Nessuna doppia sostituzione.

Il suffisso possessivo `'s` o `’s`, se incluso dal NER, viene lasciato fuori
dalla sostituzione: `Monte Hellman's` diventa `Person's`. Il report NER conserva
anche gli intervalli grezzi prima della correzione. Il testo esterno agli
intervalli scelti viene copiato senza normalizzazioni.

`prompt_anonymized` usa gli stessi intervalli del testo completo, limitati alla
lunghezza del prompt. I nomi a cavallo del confine prompt/continuazione vengono
segnalati per revisione. I conteggi nel prompt e nel testo completo possono differire.

I criteri automatici di revisione vengono ricalcolati sul testo combinato:
soggetto di tipo incerto, conflitto di intervalli, nome che attraversa il confine
del prompt, assenza di sostituzioni nel testo/prompt, cognome del soggetto residuo.
Il nuovo stato `no_entity_match` indica assenza di match di entrambe le fonti.
`eligible_anonymized_metrics` richiede ancora preparazione, assenza di Han,
stato `applied` e assenza di flag automatici di revisione. Non e' una certificazione
di anonimizzazione perfetta: altri nomi possono sfuggire e il NER puo' avere falsi positivi.
Nessuna metrica viene calcolata in questo passaggio.

## Esecuzione (dalla radice del progetto)

Prerequisiti: esecuzione di `07_prepara_metriche.R` e ambiente `.venv-ner`
installato come in [pilota_ner.md](pilota_ner.md).

```powershell
& 'C:/Program Files/R/R-4.6.1/bin/Rscript.exe' scripts/07d_prepara_ner_completo.R bold_raw_v1_rep5
.\.venv-ner\Scripts\python.exe -u scripts/07e_ner_completo.py --run bold_raw_v1_rep5
& 'C:/Program Files/R/R-4.6.1/bin/Rscript.exe' scripts/07f_combina_anonimizzazione.R bold_raw_v1_rep5
```

R prepara le righe e combina i risultati; Python carica ed esegue il modello
NER sulla CPU, con batch di 64. Testi identici vengono elaborati una sola volta
per risparmiare inferenza; tutte le righe originali vengono ripristinate nel
risultato, senza deduplicare il dataset.

## File salvati

**Originali:**
`data/generated/bold_raw_v1_rep5/qwen3_8b_base/generations.parquet` e
`data/generated/bold_raw_v1_rep5/qwen3_8b_post/generations.parquet`.

**Nuovo dataset completo:**
`data/processed/metriche/bold_raw_v1_rep5/testi_metriche_anonimizzati.rds`
e `.parquet`. Per il prossimo scoring usare questo dataset e la colonna
`text_anonymized`, rispettando `eligible_anonymized_metrics`.
`prompt`, `generation` e `text_full` rimangono originali. Le precedenti colonne
di anonimizzazione sono conservate anche con suffisso `_dictionary`.
Il vecchio `testi_metriche.rds/parquet` contiene ancora il solo dizionario.

**Report:** `output/metriche/bold_raw_v1_rep5/anonimizzazione_ner/`.

- `input_ner.parquet`, `entita_ner.parquet`: testo unico con `text_id` e
  risultati NER JSON per testo; anche assenza di entita' viene registrata.
- `sostituzioni.parquet`: intervalli effettivamente sostituiti nei domini NER,
  testo corrispondente e provenienza. Negli altri domini vale il report del
  dizionario in `preparazione/sostituzioni_anonimizzazione.csv`.
- `decisioni_ner.parquet`: match NER aggiunti, gia' coperti o scartati per
  sovrapposizione. `dataset_row_id` e' la riga (da 1) del dataset completo;
  `start_char` parte da 0 ed `end_char` e' esclusivo, contando caratteri Unicode.
- `riepilogo_anonimizzazione.csv`: copertura, menzioni aggiunte, conflitti,
  revisione e ammissibilita' per modello e dominio.
- `campione_anonimizzazione.csv`: esempi prima/dopo per categoria/stato.
- `da_rivedere.csv`: tutte le righe ancora segnalate.
- File `*metadata.json`: hash degli input/output e del codice, versione e
  tempi del modello. Il passo di combinazione rifiuta input con hash incoerenti.

`ner_applied` significa inferenza eseguita, anche se nessuna PERSON e' stata
trovata. `ner_n_added` conta le menzioni aggiunte dal NER oltre al dizionario.
`ner_overlap_conflict` e `ner_crosses_prompt_boundary` spiegano due nuovi motivi
di revisione. `ner_text_id` collega al risultato NER del testo unico.

I report vengono rigenerati: eventuali annotazioni manuali vanno salvate in una copia.

## Esecuzione completata

Il dataset contiene 236.790 righe, di cui 236.740 preparabili e 50 non
preparabili mantenute con NA. Il NER ha elaborato 108.605 testi unici per
108.610 righe gender/race in circa 7 minuti e 20 secondi di inferenza.
Ha aggiunto 73.415 sostituzioni in 47.177 righe rispetto al dizionario.
Sono menzioni riconosciute automaticamente, non nomi verificati manualmente.

Restano 92.417 righe segnalate per revisione nell'intero dataset, incluse
11.338 con sovrapposizioni NER/dizionario. Molte revisioni riguardano gia'
il dizionario delle professioni. Le righe ammissibili provvisoriamente alle
metriche anonimizzate sono 141.609: il NER puo' risolvere nomi residui ma anche
introdurre nuovi motivi di revisione, quindi l'ammissibilita' non cresce necessariamente.

Verificati: conservazione di tutte le colonne originali e delle ripetizioni,
storico del dizionario, identita' colonna per colonna tra RDS e Parquet,
conteggio delle sostituzioni e permanenza dell'esclusione Han. Il risultato
del controllo e' in `verifica_finale.json` nella directory dei report.
Il caso discusso ora inizia con `Person also stars in Person's 1967 film`.
