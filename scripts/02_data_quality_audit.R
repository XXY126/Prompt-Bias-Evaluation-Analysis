# ============================================================
# scripts/11_data_quality_audit.R
#
# Data Quality Audit del dataset BOLD PRIMA della pulizia.
#
# Descrive lo stato del dataset grezzo appiattito,
# identifica potenziali problemi tecnici e produce tabelle
# per l'ispezione manuale.
#
# NON modifica e NON elimina alcun prompt.
#
# INPUT:
#   data/processed/01_bold_raw.rds
#
# OUTPUT:
#   output/audit/*.csv
# ============================================================

source(here::here("R", "setup.R"))
source(here::here("R", "data_quality.R"))


# ------------------------------------------------------------
# Percorsi
# ------------------------------------------------------------

input_path <- here::here(
  "data",
  "processed",
  "01_bold_raw.rds"
)

output_dir <- here::here(
  "output",
  "audit"
)

dir.create(
  output_dir,
  recursive = TRUE,
  showWarnings = FALSE
)


# ------------------------------------------------------------
# Caricamento dataset
# ------------------------------------------------------------

df_raw <- readRDS(input_path)

verifica_schema_bold(df_raw)


# ------------------------------------------------------------
# Aggiunta flag di audit
# ------------------------------------------------------------

df_audit <- aggiungi_flag_qualita(df_raw)

# L'audit può aggiungere colonne, ma non deve modificare i prompt.
if (!identical(df_raw$prompt, df_audit$prompt)) {
  stop(
    "ERRORE: il Data Quality Audit ha modificato i prompt originali."
  )
}


# ------------------------------------------------------------
# 1. Overview del dataset
# ------------------------------------------------------------

dataset_summary <- riepilogo_dataset(
  df_raw,
  df_audit
)

print(dataset_summary)

readr::write_csv(
  dataset_summary,
  file.path(output_dir, "dataset_summary.csv")
)


# ------------------------------------------------------------
# 2. Missing e stringhe vuote
# ------------------------------------------------------------

missing_summary <- riepilogo_missing(df_raw)

print(missing_summary)

readr::write_csv(
  missing_summary,
  file.path(output_dir, "missing_summary.csv")
)


# ------------------------------------------------------------
# 3. Domini e categorie
# ------------------------------------------------------------

domain_category_counts <-
  riepilogo_domini_categorie(df_raw)

readr::write_csv(
  domain_category_counts,
  file.path(output_dir, "domain_category_counts.csv")
)

domini_attesi <- c(
  "gender",
  "race",
  "religion",
  "profession",
  "political"
)

domain_check <- controlla_domini(
  df_raw,
  domini_attesi
)

print(domain_check)

readr::write_csv(
  domain_check,
  file.path(output_dir, "domain_check.csv")
)


# ------------------------------------------------------------
# 4. Possibili inconsistenze nei nomi delle categorie
# ------------------------------------------------------------

category_variants <-
  trova_varianti_categoria(df_raw)

readr::write_csv(
  category_variants,
  file.path(output_dir, "category_name_variants.csv")
)


# ------------------------------------------------------------
# 5. Qualità dei prompt
# ------------------------------------------------------------

text_quality_summary <-
  riepilogo_flag_testo(df_audit)

print(text_quality_summary, n = Inf)

readr::write_csv(
  text_quality_summary,
  file.path(output_dir, "text_quality_summary.csv")
)


# ------------------------------------------------------------
# 6. Duplicati: fotografia preliminare
# ------------------------------------------------------------
# Qui vengono solo conteggiati.
# Within-category e cross-category saranno studiati
# nello script dedicato alla duplicate analysis.

duplicate_summary <-
  riepilogo_duplicati(df_audit)

print(duplicate_summary)

readr::write_csv(
  duplicate_summary,
  file.path(output_dir, "duplicate_summary.csv")
)


# ------------------------------------------------------------
# 7. Casi da ispezionare
# ------------------------------------------------------------

technical_issues <-
  estrai_errori_tecnici(df_audit)

manual_review <-
  estrai_revisione_manuale(df_audit)

readr::write_csv(
  technical_issues,
  file.path(output_dir, "technical_issues.csv")
)

readr::write_csv(
  manual_review,
  file.path(output_dir, "manual_review.csv")
)


# ------------------------------------------------------------
# Riepilogo finale
# ------------------------------------------------------------

n_errori_tecnici <- sum(
  df_audit$flag_errore_tecnico,
  na.rm = TRUE
)

n_revisione_manuale <- sum(
  df_audit$flag_revisione_manuale,
  na.rm = TRUE
)

cat("\n========== DATA QUALITY AUDIT ==========\n")

cat(
  "Prompt totali:",
  nrow(df_raw),
  "\n"
)

cat(
  "Prompt con almeno un probabile errore tecnico:",
  n_errori_tecnici,
  "(",
  round(100 * n_errori_tecnici / nrow(df_raw), 3),
  "%)\n"
)

cat(
  "Prompt con almeno un flag da revisione manuale:",
  n_revisione_manuale,
  "(",
  round(100 * n_revisione_manuale / nrow(df_raw), 3),
  "%)\n"
)

cat(
  "Caratteri di controllo:\n",
  "  - tab:", sum(df_audit$ha_tab, na.rm = TRUE), "\n",
  "  - newline:", sum(df_audit$ha_newline, na.rm = TRUE), "\n",
  "  - carriage return:", sum(df_audit$ha_carriage_return, na.rm = TRUE), "\n"
)

cat(
  "Prompt con caratteri non-ASCII (informativo):",
  sum(df_audit$ha_non_ascii, na.rm = TRUE),
  "\n"
)

cat(
  "Prompt con spazio finale (informativo):",
  sum(df_audit$ha_spazio_finale, na.rm = TRUE),
  "\n"
)

cat("========================================\n")

cat(
  "\nAudit completato.\n",
  "Nessun prompt è stato modificato o eliminato.\n",
  "Risultati salvati in: ",
  output_dir,
  "\n",
  sep = ""
)
