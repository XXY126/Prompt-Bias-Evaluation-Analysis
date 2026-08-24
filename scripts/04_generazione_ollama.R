# ============================================================
# 04_generazione_ollama.R
#
# STEP 4 della pipeline: genera le continuazioni dei prompt BOLD
# usando due modelli offline eseguiti in locale tramite Ollama:
#   - qwen3:8b        (modello denso, ~8 miliardi di parametri)
#   - qwen3:30b-a3b    (modello MoE, ~30B totali / ~3B attivi per token)
#
# PREREQUISITI:
#   ollama pull qwen3:8b
#   ollama pull qwen3:30b-a3b
#
# INPUT:  data/processed/03_bold_eda.rds
# OUTPUT: data/processed/04_generazioni_qwen8b.rds
#         data/processed/04_generazioni_qwen30b.rds
#
# NOTA SUI TEMPI: la generazione su tutti i 23.679 prompt puo' richiedere
# da alcune ore (qwen3:8b) a molto piu' a lungo (qwen3:30b-a3b), a seconda
# della GPU disponibile. Lo script salva un checkpoint incrementale ogni
# 50 righe (parametro salva_ogni), quindi puo' essere interrotto e
# ripreso senza perdere il lavoro gia' fatto. Per un primo test rapido,
# usare prima il campione ridotto (sezione 0 sotto) prima di lanciare
# la generazione sull'intero dataset.
# ============================================================

source(here::here("scripts", "00_setup.R"))
source(here::here("R", "ollama_utils.R"))

df <- readRDS(here("data", "processed", "03_bold_eda.rds"))

# ============================================================
# STEP 0 — Test rapido su un campione ridotto 
# ============================================================

set.seed(42)
campione_test <- df %>% dplyr::slice_sample(n = 5)

cat("=== Test rapido su 5 prompt con qwen3:8b ===\n")
for (p in campione_test$prompt_per_generazione) {
  # stampa_tempo = FALSE qui perche' lo stampiamo noi in modo ordinato
  # subito dopo, con prompt e generazione gia' visibili
  esito <- genera_ollama(p, model = "qwen3:8b", max_tokens = 30, stampa_tempo = FALSE)
  tempo <- attr(esito, "tempo_secondi")

  cat("\nPrompt:", p)
  cat("\nGenerazione:", esito)
  cat(sprintf("\nTempo: %.2f secondi\n", tempo))
}

# ============================================================
# STEP 1 — Generazione completa con qwen3:8b (modello denso)
# ============================================================

# df_qwen8b <- genera_batch_ollama(
#   df = df,
#   colonna_prompt = "prompt_per_generazione",
#   model = "qwen3:8b",
#   output_path = here("data", "processed", "04_generazioni_qwen8b.rds"),
#   salva_ogni = 50,
#   max_tokens = 40,
#   temperature = 0.7,
#   top_p = 0.95,
#   seed = 42     # stesso seed userato per l'altro modello, per confronto equo
# )

# saveRDS(df_qwen8b, here("data", "processed", "04_generazioni_qwen8b.rds"))
# message("Generazione completata con qwen3:8b. Salvata in 04_generazioni_qwen8b.rds")

# ============================================================
# STEP 2 — Generazione completa con qwen3:30b-a3b (modello MoE)
# ============================================================
# NOTA: nonostante il MoE attivi solo ~3B parametri per token (quindi
# l'inferenza e' piu' leggera di un modello denso da 30B), il tempo di
# generazione puo' comunque essere piu' lungo di qwen3:8b a seconda
# della GPU. Verificare il test rapido sotto prima di lanciare il batch
# completo.

# cat("\n=== Test rapido su 5 prompt con qwen3:30b-a3b ===\n")
# for (p in campione_test$prompt_per_generazione) {
#   cat("\nPrompt:", p)
#   cat("\nGenerazione:", genera_ollama(p, model = "qwen3:30b-a3b", max_tokens = 30), "\n")
# }

# df_qwen30b <- genera_batch_ollama(
#   df = df,
#   colonna_prompt = "prompt_per_generazione",
#   model = "qwen3:30b-a3b",
#   output_path = here("data", "processed", "04_generazioni_qwen30b.rds"),
#   salva_ogni = 50,
#   max_tokens = 40,
#   temperature = 0.7,
#   top_p = 0.95,
#   seed = 42
# )

# saveRDS(df_qwen30b, here("data", "processed", "04_generazioni_qwen30b.rds"))
# message("Generazione completata con qwen3:30b-a3b. Salvata in 04_generazioni_qwen30b.rds")

# ============================================================
# STEP 3 — Generazione su TUTTI i file json dentro data/raw/prompts/,
#           output in json con la stessa struttura di ciascun file di
#           input (categoria -> persona -> lista), un file di output
#           per ogni combinazione file di input x modello, relazione
#           1:1 tra prompt e generazione
# ============================================================
# NOTA: qui NON si parte da 03_bold_eda.rds (che contiene già i prompt
# appiattiti in un dataframe), ma direttamente dai json BOLD originali
# in data/raw/prompts/, per poter restituire un output nella stessa
# forma annidata del rispettivo file di input. genera_json_ollama()
# appiattisce, genera e ricostruisce da sola (vedi commenti nella
# funzione in R/ollama_utils.R), un file di input alla volta.

cartella_prompt <- here("data", "raw", "prompts")
cartella_output <- here("data", "processed", "05_generazioni_json")

file_prompt <- list.files(cartella_prompt, pattern = "\\.json$", full.names = TRUE)

if (length(file_prompt) == 0) {
  stop("Nessun file .json trovato in ", cartella_prompt)
}

modelli <- c("qwen3:8b")

for (file_input in file_prompt) {
  for (modello in modelli) {
    cat(
      "\n=== Generazione per '", basename(file_input), "' con modello '",
      modello, "' ===\n", sep = ""
    )
    genera_json_ollama(
      input_path = file_input,
      output_dir = cartella_output,
      model = modello,
      salva_ogni = 50,
      max_tokens = 40,
      temperature = 0.7,
      top_p = 0.95,
      seed = 42
    )
  }
}

# Per ogni file "nome.json" dentro data/raw/prompts/, il risultato in
# data/processed/05_generazioni_json/ e':
#   nome_qwen38b.json             <- output finale, stessa struttura dell'input
#   nome_qwen38b_checkpoint.rds   <- checkpoint incrementale (dataframe appiattito)
#   nome_qwen330ba3b.json
#   nome_qwen330ba3b_checkpoint.rds

# ============================================================
# Riepilogo finale
# ============================================================

# cat("\n========== RIEPILOGO GENERAZIONE ==========\n")
# cat("Prompt totali processati:", nrow(df), "\n")
# cat("qwen3:8b — generazioni riuscite:", sum(!is.na(df_qwen8b$generazione)), "\n")
# cat("qwen3:8b — generazioni fallite (NA):", sum(is.na(df_qwen8b$generazione)), "\n")
# cat("qwen3:30b-a3b — generazioni riuscite:", sum(!is.na(df_qwen30b$generazione)), "\n")
# cat("qwen3:30b-a3b — generazioni fallite (NA):", sum(is.na(df_qwen30b$generazione)), "\n")
# cat("=============================================\n")