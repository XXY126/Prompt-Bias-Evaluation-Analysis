# ============================================================
# 02_pulizia_prompt.R
#
# STEP 2 della pipeline: ispezione e pulizia del campo "prompt".
# Applica solo correzioni automatiche sicure (markup, spazi,
# caratteri di controllo). Duplicati, outlier e troncamenti
# sospetti vengono SOLO flaggati, non rimossi: la decisione
# va presa consapevolmente e documentata nel report (vedi OB1).
#
# INPUT:  data/processed/01_bold_raw.rds
# OUTPUT: data/processed/02_bold_pulito.rds
#         output/tables/campione_coerenza_manuale.csv
#         output/tables/prompt_anomalie_testuali.csv
# ============================================================

source(here::here("scripts", "00_setup.R"))
source(here::here("R", "pulizia_testo.R"))

# --- Caricamento output dello step precedente ---
df <- readRDS(here("data", "processed", "01_bold_raw.rds"))

# --- Pipeline di pulizia completa ---
df <- pulisci_prompt_completo(df)

# --- Riepilogo a console ---
riepilogo_qualita_testo(df)

# --- Campione stratificato per revisione manuale di coerenza ---
# (3 prompt casuali per ogni combinazione dominio-categoria: verifica
# che il contenuto sia effettivamente pertinente alla categoria dichiarata)
set.seed(42)
campione_coerenza <- df %>%
  dplyr::group_by(dominio, categoria) %>%
  dplyr::slice_sample(n = 3) %>%
  dplyr::ungroup()

write.csv(
  campione_coerenza,
  here("output", "tables", "campione_coerenza_manuale.csv"),
  row.names = FALSE
)

# --- Export dei soli prompt con anomalie, per ispezione manuale mirata ---
df %>%
  dplyr::filter(flag_qualita_strutturale | ultima_parola_sospetta | is_duplicato_cross_categoria) %>%
  dplyr::select(
    dominio, categoria, prompt, prompt_per_generazione, prompt_pulito,
    is_duplicato_cross_categoria, outlier_lunghezza,
    ultima_parola_sospetta, flag_qualita_strutturale
  ) %>%
  write.csv(
    here("output", "tables", "prompt_anomalie_testuali.csv"),
    row.names = FALSE
  )

# --- Salvataggio output intermedio ---
output_path <- here("data", "processed", "02_bold_pulito.rds")
saveRDS(df, output_path)

message("Dataset pulito e annotato salvato in: ", output_path)
message("Ricorda: ispeziona manualmente i CSV esportati in output/tables/ ",
        "prima di decidere se rimuovere duplicati/outlier per gli step successivi.")
