# Test

Eseguire dalla radice del repository, con l'interprete dell'ambiente appropriato.

```bash
python -m unittest discover -s tests -p 'test_*.py'
```

La suite Python completa richiede VADER, PyArrow, PyYAML, PyTorch e Transformers.
Non scarica pesi Qwen o modelli NER e non richiede una GPU.
Per verificare solo lo scoring, nell'ambiente con `requirements-metrics.txt`:

```bash
python tests/test_metriche.py
```

I test dei percorsi in `test_script_layout.py` usano solo la libreria standard.
Il test di integrazione delle metriche usa un dataset sintetico in una directory
temporanea, lancia lo script da una directory diversa dalla radice e controlla
la conservazione delle colonne e delle righe nel Parquet prodotto.

Test R:

```bash
Rscript tests/test_preparazione_metriche.R
Rscript tests/test_anonimizzazione.R
Rscript tests/test_anonimizzazione_ner.R
Rscript tests/test_audit_generazioni.R
Rscript tests/test_audit_nul.R
Rscript tests/test_diversita_repliche.R
```

Servono i pacchetti R usati dalle funzioni sotto test, tra cui `dplyr`,
`stringi` e, per il test NUL, `arrow`. La directory `.audit-r-library`,
se presente, viene usata dai test che la prevedono.
