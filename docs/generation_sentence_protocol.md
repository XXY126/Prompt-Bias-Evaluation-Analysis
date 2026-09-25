# V3: completare la frase iniziata dal prompt

Configurazione: `configs/generation_english_sentence.yaml`.
Run: `bold_english_sentence_v3`. Una ripetizione per prompt e modello;
massimo 80 nuovi token. Il prefisso chiede inglese, completamento conciso
della frase iniziata, nessuna seconda frase, domanda o quiz.
I parametri di campionamento e quantizzazione restano quelli della v2.

## Comandi PowerShell dalla radice del progetto

```powershell
conda activate prompt-bias
python scripts/05_generate_prompts.py --config configs/generation_english_sentence.yaml --validate-only
python -X faulthandler -u scripts/05_generate_prompts.py --config configs/generation_english_sentence.yaml --limit 200 --models qwen3_8b_base
python -X faulthandler -u scripts/05_generate_prompts.py --config configs/generation_english_sentence.yaml --limit 200 --models qwen3_8b_post
```

Il pilot usa i primi 200 prompt per entrambi i modelli, non un campione
rappresentativo. Salva in `data/generated/bold_english_sentence_v3_limit200/`.
Per avviare l'intero dataset:

```powershell
python -X faulthandler -u scripts/05_generate_prompts.py --config configs/generation_english_sentence.yaml --models qwen3_8b_base
python -X faulthandler -u scripts/05_generate_prompts.py --config configs/generation_english_sentence.yaml --models qwen3_8b_post
```

Output completo: `data/generated/bold_english_sentence_v3/<model>/`.
Per riprendere dopo un'interruzione, ripetere il medesimo comando con stessi
codice/configurazione. Il codice del rilevatore di frasi entra nella firma
del checkpoint, oltre a quello dello script principale.

Audit del pilot e della run completa:

```powershell
& 'C:/Program Files/R/R-4.6.1/bin/Rscript.exe' scripts/06_audit_generazioni.R bold_english_sentence_v3_limit200
& 'C:/Program Files/R/R-4.6.1/bin/Rscript.exe' scripts/06_audit_generazioni.R bold_english_sentence_v3
```

## Regola di arresto e conservazione del testo

`scripts/sentence_completion.py` applica `english_sentence_v1` al prompt
BOLD piu' la continuazione, senza il prefisso istruttivo. Cerca una fine
frase che si trovi nella continuazione e non taglia su punti di abbreviazioni
configurate (Dr., Mr., ecc.), iniziali, acronimi, decimali, URL o ellissi.
Durante la generazione attende un minimo di testo successivo alla punteggiatura
per distinguere, ad esempio, `3.` da `3.5` e includere eventuali virgolette
di chiusura. Ogni elemento del batch si arresta indipendentemente dagli altri.
Una domanda puo' terminare la sequenza, ma resta una domanda nel testo e
viene segnalata dal normale audit: il codice non la trasforma in un'affermazione.

Il controllo e' euristico: non garantisce correttezza grammaticale o perfetta
segmentazione. Una abbreviazione alla vera fine di una frase puo' far perdere
quel confine. Al limite di token o a EOS si controlla anche la punteggiatura
finale senza richiedere testo successivo. In assenza di un confine riconosciuto,
si conserva tutto il testo prodotto e `sentence_complete = FALSE`.
Non vengono aggiunti punti artificiali e non si rigenerano automaticamente i casi falliti.

Il piccolo eccesso necessario al controllo viene conservato:

| Campo | Significato |
| --- | --- |
| `generation` | Continuazione fino al primo confine riconosciuto, o tutto il testo se non trovato |
| `generation_raw` | Intero testo decodificato prima del taglio |
| `generated_token_ids`, `generated_tokens` | Token effettivamente prodotti, riferiti a `generation_raw`, senza EOS/padding |
| `finish_reason` | `sentence_end` se riconosciuto, altrimenti EOS/limite come in precedenza |
| `generation_stop_reason` | Motivo di arresto del decoder prima del taglio finale |
| `generation_hit_token_limit` | TRUE se raggiunti 80 token, anche quando l'ultimo token conclude la frase |
| `sentence_complete` | Fine frase riconosciuta; non certifica lingua o grammatica |
| `sentence_end_char` | Posizione esclusiva da zero nella continuazione (caratteri Unicode), null se assente |
| `sentence_trimmed_chars` | Numero di caratteri prodotti ma esclusi dalla continuazione finale |
| `sentence_stop_policy` | Versione della regola |

Il limite puo' ancora troncare una frase: 80 e' un tetto, non una lunghezza
richiesta. I token ID del testo ritagliato non vengono inventati mediante
una nuova tokenizzazione. Il JSON nested contiene `generation`; per verificare
l'eccesso prodotto dal modello, usare `generation_raw` nel Parquet.

Nell'audit, `audit_sentence_incomplete` e `n_sentence_incomplete` segnalano
testi validamente generati ma senza fine frase riconosciuta. `audit_at_token_limit`
usa il flag del decoder della v3. I controlli Han e quiz continuano a operare
su `generation` (testo ritagliato); `generation_raw` resta disponibile per
valutare anche il rispetto delle istruzioni prima del taglio.

## Confronto con le run precedenti

La v3 cambia prefisso, lunghezza massima e regola di arresto: e' una condizione
separata e non una ripresa della v2 o una replica esatta del protocollo BOLD.
Le run precedenti sono conservate. Per riprendere un checkpoint creato prima
dell'aggiunta della regola di arresto, usare la copia originale dello script:

```powershell
python -X faulthandler -u scripts/05_generate_prompts_v2.py --config configs/generation_english_prose.yaml
```

Per la v1 usare lo stesso script archiviato con `configs/generation_english_prose_v1.yaml`.
Il suo contenuto mantiene la firma dell'implementazione precedente.

Test senza caricare i pesi Qwen:

```powershell
python scripts/tests/test_sentence_completion.py
python scripts/tests/test_generation_prefix.py
```

## Verifica iniziale

Eseguiti 8 prompt per modello nella run `bold_english_sentence_v3_limit8`:
fine frase riconosciuta in 6/8 Base e 8/8 post-trained; nessun output ha
raggiunto gli 80 token. I due casi Base non conclusi terminano con EOS.
Alcuni output Base contengono riempitivi a trattini bassi: il solo punto
finale non garantisce una frase valida. Anche il post-trained produce in
alcuni casi etichette come `Continuation:` o ripete il prompt prima del
punto finale. `sentence_complete` indica quindi solo un confine rilevato,
non il rispetto del formato richiesto. Questo pilot tecnico non misura
l'efficacia sull'intero dataset. Audit salvato nella relativa cartella.

Il primo tentativo ha completato Base e incontrato il problema nativo
`access violation` al caricamento del post-trained. Avviare quest'ultimo
in un nuovo processo ha completato la prova, senza modifiche alle librerie.
I comandi sopra eseguono quindi un modello per processo; e' una precauzione
pratica, non una diagnosi definitiva o una garanzia contro il crash di Windows.
