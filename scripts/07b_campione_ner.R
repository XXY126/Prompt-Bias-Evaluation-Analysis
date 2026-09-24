# Pilota NER: campione riproducibile, senza modificare il dataset delle metriche.
# Rscript scripts/07b_campione_ner.R [run] [n=1000]
if (dir.exists(".audit-r-library"))
  .libPaths(c(".audit-r-library", .libPaths()))
args <- commandArgs(trailingOnly = TRUE)
run <- if (length(args)) args[1] else "bold_raw_v1_rep5"
n <- if (length(args) >= 2) suppressWarnings(as.integer(args[2])) else 1000L
if (!grepl("^[A-Za-z0-9][A-Za-z0-9_.-]*$", run) || is.na(n) || n < 1)
  stop("Run o numerosita' non valida.")
input <- file.path("data", "processed", "metriche", run, "testi_metriche.rds")
out <- file.path("output", "metriche", run, "pilota_ner")
df <- readRDS(input)
cols <- c("model_key", "prompt_id", "record_id", "repetition", "domain", "category",
          "subject", "prompt", "generation", "text_full", "text_anonymized",
          "eligible_english_metrics", "audit_has_han", "audit_has_question_mark",
          "anonymization_residual_name_candidate", "anonymization_review_required")
stopifnot(all(cols %in% names(df)))
scope <- df[df$domain %in% c("gender", "race") & df$eligible_english_metrics, cols]
stopifnot(nrow(scope) > 0, !anyNA(scope$text_full), !any(scope$audit_has_han))
set.seed(42)
selected <- sort(sample.int(nrow(scope), min(n, nrow(scope))))
sample <- scope[selected, , drop = FALSE]
sample$sample_kind <- "random"
# Esempio gia' discusso: diagnostico separato dal campione e dalla stima dei tempi.
waylon <- which(scope$subject == "Waylon_Payne" &
                  grepl("Monte Hellman", scope$text_full, fixed = TRUE))
extra <- head(setdiff(waylon, selected), 1)
if (length(extra)) {
  diagnostic <- scope[extra, , drop = FALSE]
  diagnostic$sample_kind <- "diagnostic"
  sample <- rbind(sample, diagnostic)
}
sample$pilot_row_id <- seq_len(nrow(sample))
dir.create(out, recursive = TRUE, showWarnings = FALSE)
arrow::write_parquet(sample, file.path(out, "campione_input.parquet"))
jsonlite::write_json(list(
  run = run, seed = 42, requested_n = n, random_n = length(selected),
  diagnostic_n = length(extra), scope_n = nrow(scope),
  scope_unique_texts = length(unique(scope$text_full)),
  scope = "gender/race; eligible_english_metrics (prepared, no Han; English unverified)",
  sampling = "simple random sample of rows without replacement; original repetitions retained",
  scope_counts = as.data.frame(table(scope$model_key, scope$domain)),
  input = input, input_md5 = unname(tools::md5sum(input)),
  script_md5 = unname(tools::md5sum("scripts/07b_campione_ner.R")),
  created_at = format(Sys.time(), tz = "UTC", usetz = TRUE)
), file.path(out, "campione_metadata.json"), pretty = TRUE, auto_unbox = TRUE)
message("Campione NER: ", length(selected), " casuali + ", length(extra),
        " diagnostici; popolazione: ", nrow(scope), ". Output: ", out)
