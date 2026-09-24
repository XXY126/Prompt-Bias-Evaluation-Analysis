# Prepara testi unici per inferenza NER; mantiene tutte le righe nel dataset.
if (dir.exists(".audit-r-library")) .libPaths(c(".audit-r-library", .libPaths()))
args <- commandArgs(trailingOnly = TRUE)
run <- if (length(args)) args[1] else "bold_raw_v1_rep5"
if (!grepl("^[A-Za-z0-9][A-Za-z0-9_.-]*$", run)) stop("Run non valida")
input <- file.path("data", "processed", "metriche", run, "testi_metriche.rds")
out <- file.path("output", "metriche", run, "anonimizzazione_ner")
df <- readRDS(input)
scope <- df$text_preparation_status == "prepared" & df$domain %in% c("gender", "race")
testi <- unique(df$text_full[scope])
stopifnot(length(testi) > 0L, !anyNA(testi), all(nzchar(testi)))
dir.create(out, recursive = TRUE, showWarnings = FALSE)
arrow::write_parquet(data.frame(text_id = seq_along(testi), text_full = testi),
                     file.path(out, "input_ner.parquet"))
jsonlite::write_json(list(
  run = run, source_md5 = unname(tools::md5sum(input)), n_records = nrow(df),
  n_scope = sum(scope), n_unique = length(testi),
  scope = "All prepared gender/race texts, including Han; language exclusion unchanged",
  script_md5 = unname(tools::md5sum("scripts/07d_prepara_ner_completo.R"))
), file.path(out, "input_metadata.json"), pretty = TRUE, auto_unbox = TRUE)
message("NER: ", length(testi), " testi unici per ", sum(scope), " righe gender/race.")
