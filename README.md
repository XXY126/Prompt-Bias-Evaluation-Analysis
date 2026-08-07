# BOLD Bias Analysis in Language Models

## Visione Generale
Questo progetto è finalizzato alla misurazione, analisi e verifica del bias sociale e concettuale all'interno di modelli di linguaggio (LLM). Sfruttando il dataset **BOLD** (*Bias in Open-Ended Language Generation*), il sistema applica avanzate tecniche di Elaborazione del Linguaggio Naturale (NLP) per esaminare la struttura dei prompt d'ingresso ed elaborare una valutazione quantitativa del comportamento dei modelli selezionati.

---

## Il Dataset BOLD
Il dataset BOLD fornisce una vasta gamma di prompt strutturati e categorizzati per analizzare l'equità e gli stereotipi nella generazione aperta del testo. I contesti di riferimento principali includono:
* **Genere** (identità e rappresentazione)
* **Professione** (associazione di ruolo e ambito lavorativo)
* **Religione** (rappresentazione dei sistemi di credo)
* **Razza e Etnia** (equità espressiva e associazione semantica)
* **Ideologia Politica** (bilanciamento e neutralità del discorso)

---

## Obiettivi del Progetto

1. **Analisi NLP dei Prompt:** Elaborazione e caratterizzazione linguistica dei prompt del dataset BOLD per identificare costrutti sintattici e semantici suscettibili di innescare risposte viziate.
2. **Generazione e Testing dei Modelli:** Somministrazione sistematica dei prompt a modelli di linguaggio target per raccogliere le relative generazioni di testo.
3. **Misurazione e Audit del Bias:** Valutazione delle risposte dei modelli mediante metriche di NLP (analisi del sentiment, tossicità, distanza semantica e variabilità lessicale) per verificare la presenza di discriminazioni o asimmetrie sistematiche.
4. **Benchmarking:** Confronto delle prestazioni e dei livelli di sicurezza (*safety*) tra diverse architetture o versioni di modelli testati.

---

## Flusso di Lavoro Logico

```text
[Dataset BOLD] ──> [Analisi & Pre-processing NLP] ──> [Prompting Modelli Target] ──> [Valutazione Metrica del Bias] ──> [Report & Visualizzazione]
```