# Prima versione dell'audit delle generazioni

## Caratteri NUL nei Parquet

Il lettore gestisce anche stringhe che contengono byte NUL (U+0000), non
rappresentabili nelle stringhe R. Esamina i byte prima della conversione e
sostituisce ogni NUL con un carattere visibile U+FFFD (`�`) **solo nella copia
usata dall'audit**. Non imposta `arrow.skip_nul` e non cancella silenziosamente
i byte. I Parquet originali restano invariati.

`caratteri_nul.csv` registra file, riga (da 1), colonna, identificativi,
numero di NUL, testo mostrato nell'audit e tutti i byte originali della cella
in `original_utf8_hex`. La rappresentazione hex consente il recupero esatto.
Nel dataset: `audit_has_nul`, `audit_n_nul`, `audit_nul_columns` e
`audit_nul_in_metric_text` (NUL nel prompt o nella continuazione).
I riepiloghi riportano `n_nul_rows` e `n_nul_characters`; le righe interessate
entrano in `audit_review`. Le statistiche testuali operano sulla copia con U+FFFD.

Per queste sole celle, la conservazione dei testi originali riguarda il
Parquet e il report hex, non il campo testuale R. I conteggi di caratteri
Unicode mantengono una posizione per ogni NUL sostituito.
Il passo 07 lascia `text_full = NA` e assegna `text_preparation_status =
"nul_in_metric_text"` se prompt o continuazione sono interessati: questi
testi non accedono automaticamente alle metriche. Le righe restano conservate.

Test: `Rscript scripts/tests/test_audit_nul.R`.

## Esecuzione

Eseguire dalla radice del progetto:

```powershell
Rscript scripts/06_audit_generazioni.R bold_raw_v1_rep5
```

In RStudio:

```r
Sys.setenv(BOLD_AUDIT_RUN = "bold_raw_v1_rep5")
source("scripts/06_audit_generazioni.R")
```

La run predefinita e' `bold_raw_v1_rep5`, presente con entrambi i modelli e
cinque repliche. Per altre run cambiare l'argomento o la variabile d'ambiente.
Non vengono aggregate insieme run diverse. Sono necessari `here`, `dplyr`,
`stringi`, `readr`, `jsonlite`, `ggplot2` e `arrow`. Se presente, viene usata anche la libreria locale
`.audit-r-library`. Lo script non installa automaticamente dipendenze.

Gli output sono in `output/audit/generazioni/<run>/`. Rieseguire l'audit
sovrascrive i suoi derivati; i Parquet e i testi originali restano invariati.

| File | Contenuto |
|---|---|
| `completezza.csv` | Conteggi osservati rispetto ai metadati di ogni modello |
| `riepilogo_modello.csv`, `riepilogo_categoria.csv`, `riepilogo_replica.csv` | Lunghezze, stati, frequenze Han, presenza di `?` e flag di qualita' |
| `stati_arresto.csv` | Conteggi per stato e motivo di arresto |
| `problemi_abbinamento.csv` | Chiavi prompt/replica mancanti o multiple per modello |
| `prompt_incoerenti.csv` | Testi o attributi diversi associati alla stessa chiave |
| `generazioni_con_han.csv` | Tutte le continuazioni con Han, prompt e identificativi |
| `passaggi_han.csv` | Ogni sequenza Han, posizioni e contesto di 50 caratteri per lato |
| `generazioni_possibili_quiz.csv` | Tutte le continuazioni contenenti `?`, con prompt, identificativi e flag |
| `casi_da_rivedere.csv` | Han, possibili quiz, output vuoti inattesi, loop di parole e problemi tecnici |
| `campione_revisione.csv` | Fino a 5 chiavi per categoria, con le risposte di tutti i modelli e colonne per annotazioni |
| `generazioni_annotate.rds` | Tutti i record e i flag; le liste di token ID restano nei Parquet |
| `diversita_repliche_prompt.csv` | Diversita' normalizzata delle repliche, per modello e prompt |
| `distribuzione_diversita_repliche.csv` | Numero di prompt per categoria, testi validi e testi distinti normalizzati |
| `repliche_uguali_normalizzate.csv` | Repliche con uguale continuazione normalizzata, conservando anche il testo originale |
| `lunghezze.png`, `presenza_han.png` | Grafici descrittivi |
| `audit_metadata.json`, `sessionInfo.txt` | Input, impronte MD5, metadati originali, versione R e pacchetti |

## Interpretazione dei passaggi cinesi

Il rilevamento usa la proprieta' Unicode `script=Han`, anche per ideogrammi
fuori dal blocco CJK principale. E' un indicatore riproducibile della
scrittura, non un classificatore della lingua: gli Han compaiono anche nel
giapponese e in altri contesti. `audit_has_kana` segnala inoltre Hiragana o
Katakana, senza assegnare automaticamente una lingua.

L'audit distingue Han gia' presenti nel prompt da Han presenti solo nella
continuazione, conta caratteri Han e latini e calcola la quota Han sul totale
delle lettere Unicode (contando al numeratore solo Han di tipo lettera).
Quest'ultima non e' una probabilita' linguistica.
Pinyin o testo cinese romanizzato non vengono rilevati da questa euristica.
I passaggi sono sequenze Han contigue: la punteggiatura li separa, mentre
`context` permette di ricostruire la frase. Le coordinate sono 1-based e
misurate in caratteri Unicode della continuazione, non in byte o token.
I CSV sono UTF-8 con BOM per conservare gli ideogrammi anche in Excel.
Per rileggere i CSV senza eliminare gli spazi iniziali delle continuazioni,
usare `readr::read_csv(..., trim_ws = FALSE)`. Il file RDS conserva anche
la distinzione tra valori mancanti e stringhe vuote.

La percentuale Han usa come denominatore le continuazioni con `status=ok`
e testo non vuoto. I numeratori e denominatori sono entrambi esportati.
Le righe saltate non sono trattate come risposte prive di bias o prive di Han.
Il campione manuale non e' cieco rispetto al modello e le categorie piccole
possono contribuire meno di cinque chiavi. I casi Han sono esportati tutti,
indipendentemente dalla loro presenza nel campione.

## Possibili quiz: euristica del punto interrogativo

Il controllo cerca il carattere letterale ASCII `?` nella sola colonna
`generation`, senza includere il prompt e senza modificare il testo.

- `audit_has_question_mark`: TRUE se compare almeno un `?`; FALSE per
  testi privi del carattere, stringhe vuote o valori mancanti.
- `audit_n_question_marks`: numero di `?` nella continuazione; NA per
  testo mancante, zero per stringhe vuote.
- `n_question_mark_ok`: numero di continuazioni con `status=ok` contenenti
  almeno un `?`, nei riepiloghi per modello, categoria e replica.
- `pct_question_mark_nonempty_ok`: percentuale sul denominatore
  `n_nonempty_ok`, cioe' continuazioni non vuote con `status=ok`.
  Se il denominatore e' zero, la percentuale e' NA.

Una continuazione con piu' domande conta una sola volta nella frequenza.
Tutti i casi segnalati sono esportati in `generazioni_possibili_quiz.csv`
e inclusi nel flag generale `audit_review` e in `casi_da_rivedere.csv`.

E' un indicatore naive di possibile quiz, non una classificazione:
non controlla la presenza della risposta e puo' includere domande retoriche,
citazioni o altri usi del carattere. Non intercetta quiz privi di `?` o
varianti Unicode come il punto interrogativo a larghezza piena U+FF1F.
La distinzione tra domanda semplice e quiz con risposta resta manuale.

## Uguaglianza normalizzata tra repliche

Il confronto riguarda le continuazioni dello stesso `prompt_id` e dello
stesso `model_key`. Due occorrenze BOLD con ID diversi restano separate,
anche se il prompt e' uguale. Non si confrontano insieme modelli diversi.

La copia di confronto viene convertita in minuscolo con locale `en`;
sequenze di spazi Unicode (inclusi tab e ritorni a capo) diventano un solo
spazio, eliminando quelli iniziali e finali. Punteggiatura, accenti, numeri
e parole non vengono rimossi. Non viene calcolata una soglia di similarita'
ne' una misura separata di uguaglianza sui testi non normalizzati.

`diversita_repliche_prompt.csv` contiene una riga per modello e prompt:

| Colonna | Interpretazione |
|---|---|
| `n_records` | Tutti i record osservati per il gruppo |
| `n_valid` | Record con `status=ok` e continuazione non vuota |
| `replica_group_invalid` | TRUE se il gruppo contiene chiavi modello/prompt/replica duplicate |
| `n_unique_normalized` | Numero di continuazioni distinte dopo normalizzazione |
| `n_redundant_normalized` | `n_valid - n_unique_normalized` |
| `max_same_normalized` | Massimo numero di repliche con lo stesso testo normalizzato |
| `n_pairs` | Numero di coppie confrontabili: `n_valid * (n_valid - 1) / 2` |
| `n_equal_pairs_normalized` | Numero di coppie uguali dopo normalizzazione |
| `all_identical_normalized` | TRUE se almeno due continuazioni valide sono tutte uguali; NA se non confrontabile |

Per cinque repliche con testi normalizzati A, A, B, C, C si hanno 3 testi
distinti, 2 occorrenze ridondanti e 2 coppie uguali sulle 10 confrontabili.
Le occorrenze ridondanti non coincidono in generale con il numero di coppie
uguali: con A, A, A, B, C sono rispettivamente 2 e 3.

Le righe vuote, mancanti o con stato diverso da `ok` non contribuiscono alla
diversita'. I gruppi senza testi validi rimangono visibili con zero testi
distinti e zero coppie; `max_same_normalized` e `all_identical_normalized`
sono NA. Se ci sono chiavi duplicate, tutte le misure di diversita' del
gruppo sono NA, mantenendo conteggi e flag per la verifica tecnica.

La distribuzione mantiene separati gruppi con diverso `n_valid`, evitando
di confrontare implicitamente cinque repliche valide con una sola. Per la
run con cinque repliche, usare `n_valid == 5` e `replica_group_invalid == FALSE`
per descrivere i gruppi con tutte e cinque le continuazioni valide.
Questo controllo non sostituisce il confronto con le repliche attese.

`repliche_uguali_normalizzate.csv` include solo le repliche appartenenti a
gruppi di almeno due testi normalizzati uguali, con `generation` originale,
`generation_normalized` e `n_same_normalized`. Non elimina alcuna riga dai
dati originali e non classifica automaticamente la ripetizione come errore.

## Limiti e passo successivo

Nessuna rimozione automatica di duplicati, passaggi cinesi o anomalie.
Una chiave ripetuta e' un problema tecnico distinto da prompt uguali con ID
diversi, che restano nel dataset. Il controllo di abbinamento usa l'unione
delle chiavi osservate: omissioni condivise da entrambi i modelli richiedono
un confronto successivo con il manifest dei prompt originali. I conteggi dei
metadati offrono una verifica aggiuntiva, ma non sostituiscono tale confronto.

L'arresto `max_new_tokens` indica il raggiungimento del budget, non dimostra
che una frase sia incompleta. Il flag di ripetizione rileva solo una stessa
parola ripetuta consecutivamente almeno quattro volte. Rifiuti e coerenza
richiedono revisione manuale in questa versione. Non vengono calcolati
sentiment, tossicita' o test di bias: prima dello scoring occorre decidere
come valutare le continuazioni multilingui e documentare la copertura
linguistica dei valutatori.

I controlli mirati possono essere eseguiti con
`Rscript scripts/tests/test_audit_generazioni.R` e
`Rscript scripts/tests/test_diversita_repliche.R`.
