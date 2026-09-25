# Preparazione dei testi per le metriche

Se l'audit segnala NUL nel prompt o nella continuazione tramite
`audit_nul_in_metric_text`, il testo non e' preparabile per lo scoring:
`text_preparation_status = "nul_in_metric_text"` e `text_full = NA`.
La riga resta nel dataset. I byte originali sono nel Parquet di generazione
e nel report `caratteri_nul.csv` dell'audit; la copia R mostra U+FFFD al posto
dei NUL. Questo controllo non modifica il trattamento delle altre righe.

Eseguire dalla radice del progetto, dopo l'audit della stessa run:

```r
Rscript scripts/07_prepara_metriche.R bold_raw_v1_rep5
```

In RStudio:

```r
Sys.setenv(BOLD_METRICS_RUN = "bold_raw_v1_rep5")
source("scripts/07_prepara_metriche.R")
```

Lo script legge `output/audit/generazioni/<run>/generazioni_annotate.rds`.
La funzione riutilizzabile `prepara_testi_metriche()` si trova in
`R/preparazione_metriche.R`. Non riesegue l'audit.
Le funzioni di mascheramento sono in `R/anonimizzazione.R`; il dizionario
si costruisce con i soggetti BOLD e `configs/anonymization.json`.

## Colonne aggiunte

- `text_full`: `paste0(prompt, generation)` per righe con stato `ok`, prompt
  e continuazione presenti e non vuoti; `NA` per le altre righe.
- `text_preparation_status`: `prepared`, `generation_status_not_ok`,
  `missing_prompt`, `empty_prompt`, `missing_generation` o `empty_generation`.
  Se ci sono piu' problemi viene riportato il primo in questo ordine;
  i flag dell'audit conservano gli altri dettagli.

La concatenazione usa prompt e continuazione della stessa riga. Non aggiunge
spazi: `"Hello"` + `", world!"` produce `"Hello, world!"`, e `"un"` + `"happy"`
produce `"unhappy"`. Mantiene maiuscole, punteggiatura, spazi e caratteri Unicode.
La normalizzazione usata per confrontare le repliche non si applica a questo testo.

Tutte le righe, le repliche, le colonne originali e i flag dell'audit restano
invariati. Anche testi con Han e possibili quiz vengono concatenati.
`prepared` indica solo che il testo e' stato costruito: non certifica lingua,
qualita', correttezza delle chiavi o ammissibilita' per una specifica metrica.

## Output

- `data/processed/metriche/<run>/testi_metriche.rds`: dataset completo con
  le colonne di preparazione e screening; preserva spazi, tipi e valori mancanti.
- `data/processed/metriche/<run>/testi_metriche.parquet`: stessa tabella,
  leggibile anche da Python per il successivo scoring.
- `output/metriche/<run>/preparazione/riepilogo_preparazione.csv`: conteggi
  per modello, dominio, categoria e stato di preparazione.
- Nella stessa cartella: `preparazione_metadata.json` (input/output,
  impronte MD5, regole applicate e versioni) e `sessionInfo.txt`.
- `copertura_metriche_modello.csv` e `copertura_metriche_categoria.csv`:
  conteggi di testi preparati, esclusi per Han e ammessi alla prima analisi.
  Le percentuali usano come denominatore i testi preparati, senza i record
  vuoti o falliti; i gruppi senza testi preparati hanno percentuali `NA`.
- `dizionario_anonimizzazione.csv`: candidati, varianti, fonte, placeholder,
  flag `enabled` e motivi per cui alcuni titoli non vengono usati.
- `sostituzioni_anonimizzazione.csv`: forme effettivamente sostituite e
  frequenza nelle generazioni complete, comprese quelle escluse per Han.
- `riepilogo_anonimizzazione.csv`: conteggi per modello e dominio.
- `anonimizzazione_da_rivedere.csv`: prompt e motivi di revisione, senza
  duplicare lo stesso caso per ogni modello/replica.
- `campione_anonimizzazione.csv`: esempi prima/dopo per categoria e stato,
  scegliendo tre prompt per gruppo e la prima replica di entrambi i modelli.
  E' un report rigenerabile; salvare eventuali annotazioni manuali in una copia.

Rieseguire lo script aggiorna questi output derivati. Per usare la funzione
su un altro dataset, passare i dati precedenti alla preparazione: la funzione
segnala un errore se le colonne che deve aggiungere esistono gia'.

## Prima analisi: criterio Han

La funzione `applica_criterio_han()` applica la politica `exclude_any_han_v1`
alla sola continuazione originale, usando il flag dell'audit. Basta un solo
carattere Han per sospendere lo scoring inglese, anche in testi misti o nomi.
Il testo completo e tutte le righe restano conservati, senza rimuovere
caratteri o tradurre. La regola vale ugualmente per entrambi i modelli.

Colonne aggiunte:

| Colonna | Significato |
| --- | --- |
| `language_screen_policy` | Versione della regola: `exclude_any_han_v1` |
| `eligible_english_metrics` | TRUE solo per testi preparati senza Han nella continuazione |
| `language_review_required` | TRUE per testi preparati esclusi a causa di Han |
| `exclusion_reason` | `han_pending_review` per Han; altrimenti il problema di preparazione, oppure NA se ammesso |

`eligible_english_metrics` e' un'ammissione **provvisoria secondo questa regola**,
non una certificazione della lingua inglese o della validita' per ogni metrica.
Un testo francese senza Han passa questo filtro. Non viene applicato un
classificatore linguistico. `text_preparation_status = prepared` continua a
indicare solo che il testo completo e' stato costruito, anche per i casi Han.

Il futuro script di scoring deve calcolare i punteggi soltanto sulle righe
ammesse anche dal controllo di anonimizzazione (`eligible_anonymized_metrics`),
poi riabbinarli al dataset completo tramite modello, prompt e replica.
Le righe escluse devono avere punteggi NA, mai zero o una classe neutra.
Non vengono ancora create colonne di punteggi in `07`.

I risultati di questa prima analisi riguarderanno il sottoinsieme ammesso,
non l'intera produzione dei modelli. Va riportata la copertura anche per
categoria; i sottoinsiemi ammessi dei due modelli possono essere diversi.
I flag '?' rimangono disponibili ma non escludono testi e non invertono punteggi.

## Anonimizzazione con dizionario, versione 1

Il riferimento e' la [sezione 3.3 del paper BOLD](https://arxiv.org/html/2101.11718v1#S3.SS3):
`Person` per i nomi di persone e `XYZ` per i termini identificativi di
professioni, religioni e ideologie. Le regole seguenti sono la nostra
implementazione documentata; non sono codice originale degli autori.

- Nei domini `gender` e `race` si usano i nomi completi dei soggetti presenti
  nei prompt del dominio, convertendo gli underscore in spazi. Le sostituzioni
  includono eventuali altre persone del dizionario citate nel testo. I titoli
  gia' identificati come non personali sono disattivati nella configurazione.
- In `profession`, un elenco esplicito di nomi di ruolo (`profession_heads`)
  seleziona i titoli professionali dai soggetti; si aggiungono plurali semplici
  ed eccezioni configurate. Titoli come `Jewellery`, `Statistics` o `Furniture`
  non vengono automaticamente trattati come professioni. Questi soggetti
  vengono segnalati per revisione, mantenendo le righe originali.
- Per religioni e ideologie vengono mascherati soltanto i termini identificativi
  configurati. Per esempio, `Left-wing terrorism` diventa `XYZ terrorism`:
  il titolo completo non deve far sparire anche la parola valutativa `terrorism`.
  Parole generiche come `left`, `right` e `conservative` non vengono sostituite
  automaticamente. Gli elenchi non sono un'ontologia completa.

Il confronto ignora le maiuscole ma conserva tutto il testo esterno ai match.
Si cercano alias interi delimitati da confini Unicode di lettere/numeri,
dando precedenza alle espressioni piu' lunghe. Punteggiatura, possessivi,
pronomi e negazioni restano presenti: `Alice White's` diventa `Person's`.
Le regole sono uguali per modelli e repliche e il dizionario non usa le
continuazioni per inventare nuovi alias.

I nomi abbreviati non vengono dedotti automaticamente: cognomi come `Brown`
o `May` possono essere parole comuni. Si possono aggiungere alias verificati
in `person_aliases`, per esempio:

```json
{"domain": "gender", "subject": "Jacob_Zachar", "alias": "Zachar"}
```

Questi alias valgono solo per le righe del soggetto indicato. Il dizionario
CSV e' un output: per rendere persistenti modifiche alle regole occorre
modificare la configurazione e incrementarne `version`.

| Colonna | Significato |
| --- | --- |
| `text_anonymized` | Copia di `text_full` con sostituzioni, oppure NA se non preparabile |
| `prompt_anonymized` | Copia del prompt elaborata con le stesse regole, utile alla revisione |
| `anonymization_policy` | Versione della configurazione |
| `anonymization_n_replacements` | Numero di sostituzioni nel testo completo |
| `anonymization_n_prompt_replacements` | Numero di sostituzioni nel solo prompt |
| `anonymization_status` | `applied`, `no_prompt_match`, `no_dictionary_match` o `not_prepared` |
| `anonymization_review_required` | TRUE per match mancanti, tipo di soggetto dubbio o possibile cognome residuo |
| `anonymization_review_reason` | Motivo della revisione, oppure NA |
| `anonymization_residual_name_candidate` | Possibile cognome del soggetto ancora nel testo anonimizzato |
| `eligible_anonymized_metrics` | Screening Han superato, stato applied e nessun flag automatico di revisione |

Una sostituzione (`applied`) **non certifica l'assenza di tutti i nomi**:
persone non nel dizionario, cognomi isolati, varianti ortografiche o nomi
troncati possono restare. Non viene eseguito un riconoscitore NER completo.
Un possibile cognome residuo del soggetto viene cercato rispettando le
maiuscole, segnalato come `residual_target_name_candidate` e inviato a
revisione. Non viene sostituito automaticamente: `Brown` potrebbe riferirsi
anche a un'altra entita'. Il controllo non rileva tutti gli altri nomi possibili.
Anche l'ammissione alle metriche e' provvisoria: il campione prima/dopo deve
essere verificato prima dello scoring. Le esclusioni per anonimizzazione
non vanno confuse con quelle per Han, riportate separatamente.

`text_anonymized` si ottiene dal testo completo: un nome completato dalla
generazione puo' essere mascherato anche se era troncato nel prompt; il caso
rimane segnalato come `no_prompt_match`. I conteggi delle sostituzioni nel
prompt e nel testo completo possono quindi differire.

## Passaggi successivi

L'estensione con NER e' disponibile: vedere [anonimizzazione_ner.md](anonimizzazione_ner.md).
Produce `testi_metriche_anonimizzati.rds/parquet`, il dataset completo con
dizionario e NER da usare per il prossimo scoring; il file prodotto dal solo
passo 07 resta il riferimento a dizionario.

Questa versione prepara testo completo, copia anonimizzata e screening Han.
Prima dello scoring occorre verificare i casi segnalati e il campione di
sostituzioni. Nessun punteggio viene calcolato o
invertito in base a risposte True/False. Il futuro script `08` sara' dedicato
al calcolo delle metriche. Un futuro riconoscimento della lingua e la revisione
dei casi Han potranno affinare il criterio iniziale, con una nuova versione.

Test mirato:

```r
Rscript scripts/tests/test_preparazione_metriche.R
Rscript scripts/tests/test_anonimizzazione.R
```
