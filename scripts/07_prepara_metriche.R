# ============================================================
# 07_prepara_metriche.R
# Unisce prompt e continuazione conservando righe e flag dell'audit.
#
# INPUT:  output/audit/generazioni/<run>/generazioni_annotate.rds
# OUTPUT: data/processed/metriche/<run>/testi_metriche.rds
#         data/processed/metriche/<run>/testi_metriche.parquet
#         output/metriche/<run>/preparazione/
#
# Dalla radice del progetto:
#   Rscript scripts/07_prepara_metriche.R bold_raw_v1_rep5
# In RStudio:
#   source("scripts/07_prepara_metriche.R")
# Per scegliere un'altra run con source():
#   Sys.setenv(BOLD_METRICS_RUN = "nome_run")
# ============================================================

# ------------------------------------------------------------
# 1. Dipendenze e funzione riutilizzabile
# ------------------------------------------------------------

if (dir.exists(".audit-r-library"))
  .libPaths(c(".audit-r-library", .libPaths()))

pacchetti <- c("here", "dplyr", "stringi", "readr", "jsonlite", "arrow")
mancanti <- pacchetti[!vapply(pacchetti, requireNamespace, logical(1), quietly = TRUE)]
if (length(mancanti))
  stop("Installare i pacchetti R: ", paste(mancanti, collapse = ", "))

source(here::here("R", "preparazione_metriche.R"))
source(here::here("R", "anonimizzazione.R"))

# ------------------------------------------------------------
# 2. Run e percorsi
# ------------------------------------------------------------

args <- commandArgs(trailingOnly = TRUE)
run_name <- if (!interactive() && length(args))
  args[1] else
  Sys.getenv("BOLD_METRICS_RUN", "bold_raw_v1_rep5")

if (!grepl("^[A-Za-z0-9][A-Za-z0-9_.-]*$", run_name))
  stop("Nome run non valido.")

input_path <- here::here(
  "output", "audit", "generazioni", run_name, "generazioni_annotate.rds"
)
data_dir <- here::here("data", "processed", "metriche", run_name)
report_dir <- here::here("output", "metriche", run_name, "preparazione")
anonymization_config_path <- here::here("configs", "anonymization.json")
anonymization_config <- jsonlite::fromJSON(anonymization_config_path)

if (!file.exists(input_path))
  stop("Input mancante. Eseguire prima 06_audit_generazioni.R per la run: ", run_name)

# ------------------------------------------------------------
# 3. Preparazione e verifica della conservazione dei dati
# ------------------------------------------------------------

df <- readRDS(input_path)
richieste <- c("model_key", "prompt_id", "repetition", "domain", "category",
               "audit_has_han", "audit_has_question_mark")
if (!all(richieste %in% names(df)))
  stop("L'input non contiene le colonne attese dell'audit aggiornato.")

preparati <- prepara_testi_metriche(df)
preparati <- applica_criterio_han(preparati)
dizionario <- costruisci_dizionario_anonimizzazione(df, anonymization_config)
message("Anonimizzazione con dizionario: ", anonymization_config$version)
anonimizzazione <- anonimizza_testi(preparati, dizionario, anonymization_config$version)
preparati <- anonimizzazione$data
stopifnot(
  nrow(preparati) == nrow(df),
  all(vapply(names(df), function(nome) identical(preparati[[nome]], df[[nome]]), logical(1)))
)

riepilogo <- dplyr::count(
  preparati, model_key, domain, category, text_preparation_status,
  name = "n_records"
)
copertura_modello <- riepiloga_copertura_metriche(preparati)
copertura_categoria <- riepiloga_copertura_metriche(
  preparati, c("model_key", "domain", "category")
)
riepilogo_anonimizzazione <- dplyr::summarise(
  dplyr::group_by(preparati, model_key, domain),
  n_prepared = sum(text_preparation_status == "prepared"),
  n_applied = sum(anonymization_status == "applied"),
  n_review = sum(anonymization_review_required),
  n_eligible_anonymized = sum(eligible_anonymized_metrics),
  .groups = "drop"
)

# ------------------------------------------------------------
# 4. Dataset, riepilogo e tracciabilita'
# ------------------------------------------------------------

dir.create(data_dir, recursive = TRUE, showWarnings = FALSE)
dir.create(report_dir, recursive = TRUE, showWarnings = FALSE)
output_path <- file.path(data_dir, "testi_metriche.rds")
saveRDS(preparati, output_path)
parquet_path <- file.path(data_dir, "testi_metriche.parquet")
arrow::write_parquet(preparati, parquet_path)
readr::write_excel_csv(
  riepilogo, file.path(report_dir, "riepilogo_preparazione.csv"), na = ""
)
readr::write_excel_csv(
  copertura_modello, file.path(report_dir, "copertura_metriche_modello.csv"), na = ""
)
readr::write_excel_csv(
  copertura_categoria, file.path(report_dir, "copertura_metriche_categoria.csv"), na = ""
)
readr::write_excel_csv(dizionario,
  file.path(report_dir, "dizionario_anonimizzazione.csv"), na = "")
readr::write_excel_csv(anonimizzazione$replacements,
  file.path(report_dir, "sostituzioni_anonimizzazione.csv"), na = "")
readr::write_excel_csv(riepilogo_anonimizzazione,
  file.path(report_dir, "riepilogo_anonimizzazione.csv"), na = "")
readr::write_excel_csv(campiona_anonimizzazione(preparati),
  file.path(report_dir, "campione_anonimizzazione.csv"), na = "")
readr::write_excel_csv(dplyr::distinct(
  dplyr::filter(preparati, anonymization_review_required),
  prompt_id, domain, category, subject, prompt, anonymization_review_reason
), file.path(report_dir, "anonimizzazione_da_rivedere.csv"), na = "")

jsonlite::write_json(
  list(
    run = run_name,
    prepared_at = format(Sys.time(), tz = "UTC", usetz = TRUE),
    input_file = normalizePath(input_path, winslash = "/"),
    input_md5 = unname(tools::md5sum(input_path)),
    output_file = normalizePath(output_path, winslash = "/"),
    output_md5 = unname(tools::md5sum(output_path)),
    parquet_file = normalizePath(parquet_path, winslash = "/"),
    parquet_md5 = unname(tools::md5sum(parquet_path)),
    script_md5 = as.list(tools::md5sum(here::here(c(
      "R/preparazione_metriche.R", "R/anonimizzazione.R", "scripts/07_prepara_metriche.R"
    )))),
    n_records = nrow(preparati),
    n_prepared = sum(preparati$text_preparation_status == "prepared"),
    concatenation = "paste0(prompt, generation); no separator, trimming or normalization",
    original_columns_preserved = TRUE,
    anonymization_applied = TRUE,
    anonymization_policy = list(
      version = anonymization_config$version,
      config_file = normalizePath(anonymization_config_path, winslash = "/"),
      config_md5 = unname(tools::md5sum(anonymization_config_path)),
      dictionary_md5 = unname(tools::md5sum(file.path(report_dir, "dizionario_anonimizzazione.csv"))),
      scope = "Full prompt plus continuation, domain-specific dictionary; original text preserved",
      matching = "Case-insensitive whole aliases with Unicode letter/number boundaries, longest first",
      source = "BOLD original prompt subjects and explicit config, never generated text",
      person_names = "Known full names in gender/race; configured shortened aliases scoped by subject",
      other_domains = "Identifying role/religion/ideology terms, not arbitrary page titles",
      limitation = "Dictionary masking is not exhaustive entity recognition or a verified exact reproduction of BOLD preprocessing",
      scoring_gate = "eligible_anonymized_metrics: Han screen AND applied AND no outstanding automatic review flag"
    ),
    language_filter_applied = TRUE,
    language_policy = list(
      id = "exclude_any_han_v1",
      scope = "Original generation only; Unicode script=Han from audit_has_han",
      eligible = "Prepared text and no Han in generation",
      excluded_han_reason = "han_pending_review",
      language_identification_applied = FALSE,
      no_han_does_not_confirm_english = TRUE,
      excluded_rows_preserved = TRUE,
      excluded_scores_policy = "Future scorers must retain NA for excluded rows, never zero"
    ),
    quiz_filter_applied = FALSE,
    metrics_computed = FALSE,
    r_version = R.version.string,
    packages = as.list(vapply(
      pacchetti, function(x) as.character(utils::packageVersion(x)), character(1)
    ))
  ),
  file.path(report_dir, "preparazione_metadata.json"),
  pretty = TRUE, auto_unbox = TRUE, na = "null"
)
capture.output(sessionInfo(), file = file.path(report_dir, "sessionInfo.txt"))

print(as.data.frame(dplyr::count(
  preparati, model_key, text_preparation_status, name = "n_records"
)))
print(as.data.frame(copertura_modello))
print(as.data.frame(riepilogo_anonimizzazione))
message("Testi salvati in: ", output_path)
message("Anonimizzazione e criterio Han applicati. Consultare i report di revisione prima dello scoring.")
