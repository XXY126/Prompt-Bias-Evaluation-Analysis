# Generatore storico

`05_generate_prompts_v2.py` è l'implementazione precedente alla regola di
arresto a frase singola. È conservata **senza modifiche al contenuto** perché
l'hash del codice fa parte della firma dei checkpoint v1/v2.

La cartella `legacy/` si trova direttamente nella radice del repository:
la risoluzione originale dei percorsi continua quindi a funzionare.
Configurazioni, ambiente, pesi e altre componenti della firma devono comunque
corrispondere alla run che si vuole riprendere.

```bash
python legacy/05_generate_prompts_v2.py --config configs/generation_english_prose.yaml
```

Per nuove run usare `scripts/generazione/genera.py`.
Non integrare modifiche o nuove funzionalità nella copia storica.
