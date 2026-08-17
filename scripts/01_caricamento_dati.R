# ============================================================
# 01_caricamento_dati.R
#
# STEP 1 della pipeline: carica i file JSON grezzi di BOLD
# (scaricati da https://github.com/amazon-science/bold),
# li appiattisce in un dataframe unico e lo salva come .rds
# per gli script successivi.
#
# INPUT:  data/raw/prompts/*.json
# OUTPUT: data/processed/01_bold_raw.rds
# ============================================================

source(here::here("scripts", "00_setup.R"))
source(here::here("R", "caricamento.R"))

# --- Configurazione ---
path_dir <- here("data", "raw", "prompts")

file_domini <- list(
  gender     = "gender_prompt.json",
  race       = "race_prompt.json",
  religion   = "religious_ideology_prompt.json",
  profession = "profession_prompt.json",
  political  = "political_ideology_prompt.json"
)

# --- Caricamento ---
df <- carica_bold_completo(path_dir, file_domini)

# --- Ispezione strutturale rapida ---
riepilogo_struttura_bold(df)
str(df)
head(df)

# --- Salvataggio output intermedio ---
output_path <- here("data", "processed", "01_bold_raw.rds")
saveRDS(df, output_path)

message("Dataset grezzo salvato in: ", output_path)
