# Combina dizionario e NER; salva un dataset nuovo completo, RDS e Parquet.
if (dir.exists(".audit-r-library")) .libPaths(c(".audit-r-library", .libPaths()))
source("R/anonimizzazione.R")
source("R/anonimizzazione_ner.R")
args <- commandArgs(trailingOnly=TRUE)
run <- if (length(args)) args[1] else "bold_raw_v1_rep5"
if (!grepl("^[A-Za-z0-9][A-Za-z0-9_.-]*$", run)) stop("Run non valida")
data_dir <- file.path("data", "processed", "metriche", run)
out <- file.path("output", "metriche", run, "anonimizzazione_ner")
input <- file.path(data_dir, "testi_metriche.rds")
meta <- jsonlite::fromJSON(file.path(out, "input_metadata.json"))
ner_meta <- jsonlite::fromJSON(file.path(out, "ner_metadata.json"))
stopifnot(unname(tools::md5sum(input)) == meta$source_md5,
  unname(tools::md5sum(file.path(out,"input_ner.parquet"))) == ner_meta$input_md5,
  unname(tools::md5sum(file.path(out,"entita_ner.parquet"))) == ner_meta$output_md5)
original <- readRDS(input)
df <- original
testi <- as.data.frame(arrow::read_parquet(file.path(out,"input_ner.parquet")))
ner <- as.data.frame(arrow::read_parquet(file.path(out,"entita_ner.parquet")))
testi$text_id <- as.integer(testi$text_id)
ner$text_id <- as.integer(ner$text_id)
stopifnot(identical(testi$text_id, ner$text_id), !anyDuplicated(testi$text_id),
          nrow(testi)==ner_meta$n_texts, nrow(df)==meta$n_records)
config <- jsonlite::fromJSON("configs/anonymization.json")
dizionario <- costruisci_dizionario_anonimizzazione(df, config)
pronto <- df$text_preparation_status == "prepared"
scope <- which(pronto & df$domain %in% c("gender", "race"))
ids <- match(df$text_full[scope], testi$text_full)
stopifnot(!anyNA(ids), length(scope)==meta$n_scope)
message("Lettura entita' NER e corrispondenze del dizionario...")
ner_list <- lapply(ner$entities_json, function(s) {
  x <- jsonlite::fromJSON(s)
  if (!length(x)) intervalli_vuoti() else x
})
dict_list <- rep(list(intervalli_vuoti()), length(scope))
for (dominio in c("gender", "race")) {
  idx <- which(df$domain[scope] == dominio)
  voci <- dizionario[dizionario$domain == dominio & dizionario$enabled, ]
  base <- voci[voci$source != "configured_person_alias", ]
  dict_list[idx] <- localizza_dizionario(df$text_full[scope[idx]], base$alias)
  extra <- voci[voci$source == "configured_person_alias", ]
  for (soggetto in unique(extra$subject)) {
    j <- idx[df$subject[scope[idx]] == soggetto]
    nuovi <- localizza_dizionario(df$text_full[scope[j]], extra$alias[extra$subject==soggetto])
    for (k in seq_along(j)) dict_list[[j[k]]] <- rbind(dict_list[[j[k]]], nuovi[[k]])
  }
}
# Conserva anche tutte le colonne del precedente trattamento a dizionario.
vecchie <- grep("^(text_anonymized$|prompt_anonymized$|anonymization_|eligible_anonymized_metrics$)", names(df), value=TRUE)
for (nome in vecchie) df[[paste0(nome,"_dictionary")]] <- df[[nome]]
df$anonymization_policy <- "bold_dictionary_ner_v1"
df$ner_applied <- FALSE
df$ner_overlap_conflict <- FALSE
df$ner_crosses_prompt_boundary <- FALSE
df$ner_n_added <- 0L
df$ner_text_id <- NA_integer_
text_out <- df$text_anonymized
prompt_out <- df$prompt_anonymized
n_full <- df$anonymization_n_replacements
n_prompt <- df$anonymization_n_prompt_replacements
added <- integer(length(scope))
conflicts <- boundary <- logical(length(scope))
log_spans <- vector("list", length(scope))
log_decisions <- vector("list", length(scope))
for (j in seq_along(scope)) {
  i <- scope[j]
  t <- df$text_full[i]
  result <- unisci_intervalli(t, dict_list[[j]], ner_list[[ids[j]]])
  # La localizzazione sul testo originale deve riprodurre il dizionario precedente.
  only_dict <- unisci_intervalli(t, dict_list[[j]], intervalli_vuoti())$spans
  if (!identical(sostituisci_intervalli(t, only_dict), original$text_anonymized[i]))
    stop("Dizionario non riprodotto alla riga ", i)
  spans <- result$spans
  plen <- stringi::stri_length(df$prompt[i])
  text_out[i] <- sostituisci_intervalli(t, spans)
  prompt_spans <- spans[spans$start_char < plen, , drop=FALSE]
  prompt_spans$end_char <- pmin(prompt_spans$end_char, plen)
  prompt_out[i] <- sostituisci_intervalli(df$prompt[i], prompt_spans)
  n_full[i] <- nrow(spans)
  n_prompt[i] <- nrow(prompt_spans)
  added[j] <- sum(spans$source == "ner")
  conflicts[j] <- result$conflict
  boundary[j] <- any(spans$start_char < plen & spans$end_char > plen)
  if (nrow(spans)) log_spans[[j]] <- data.frame(dataset_row_id=i,
    spans, entity=stringi::stri_sub(t, spans$start_char+1L, spans$end_char))
  if (nrow(result$decisions)) log_decisions[[j]] <- data.frame(dataset_row_id=i, result$decisions)
  if (j %% 5000L == 0L) message("Combinazione: ", j, "/", length(scope))
}
df$text_anonymized <- text_out
df$prompt_anonymized <- prompt_out
df$anonymization_n_replacements <- n_full
df$anonymization_n_prompt_replacements <- n_prompt
df$ner_n_added[scope] <- added
df$ner_overlap_conflict[scope] <- conflicts
df$ner_crosses_prompt_boundary[scope] <- boundary
df$ner_applied[scope] <- TRUE
df$ner_text_id[scope] <- testi$text_id[ids]
df <- aggiorna_revisione_ner(df, scope, dizionario)
immutabili <- setdiff(names(original), vecchie)
stopifnot(nrow(df)==nrow(original), all(vapply(immutabili,
  function(n) identical(df[[n]], original[[n]]), logical(1))),
  !any(df$eligible_anonymized_metrics & df$audit_has_han),
  !any(df$eligible_anonymized_metrics & df$anonymization_review_required),
  identical(df$text_anonymized[-scope], original$text_anonymized[-scope]))
dest <- file.path(data_dir, "testi_metriche_anonimizzati")
saveRDS(df, paste0(dest,".rds"))
arrow::write_parquet(df, paste0(dest,".parquet"))
spans <- dplyr::bind_rows(log_spans)
decisions <- dplyr::bind_rows(log_decisions)
arrow::write_parquet(spans, file.path(out,"sostituzioni.parquet"))
arrow::write_parquet(decisions, file.path(out,"decisioni_ner.parquet"))
readr::write_excel_csv(campiona_anonimizzazione(df), file.path(out,"campione_anonimizzazione.csv"), na="")
riepilogo <- dplyr::summarise(dplyr::group_by(df, model_key, domain),
  n_records=dplyr::n(), n_prepared=sum(text_preparation_status=="prepared"),
  n_ner=sum(ner_applied), n_changed=sum(text_anonymized != text_anonymized_dictionary, na.rm=TRUE),
  n_added_mentions=sum(ner_n_added), n_overlap_conflicts=sum(ner_overlap_conflict),
  n_review=sum(anonymization_review_required), n_eligible=sum(eligible_anonymized_metrics),
  .groups="drop")
readr::write_excel_csv(riepilogo, file.path(out,"riepilogo_anonimizzazione.csv"))
readr::write_excel_csv(dplyr::filter(dplyr::select(df, model_key,prompt_id,repetition,domain,
  subject,text_full,text_anonymized,anonymization_review_reason,anonymization_review_required,
  ner_overlap_conflict,ner_crosses_prompt_boundary), anonymization_review_required),
  file.path(out,"da_rivedere.csv"), na="")
jsonlite::write_json(list(run=run, policy="bold_dictionary_ner_v1", n_records=nrow(df),
  n_scope=length(scope), original_columns_preserved=immutabili, input_md5=meta$source_md5,
  dictionary_config_md5=unname(tools::md5sum("configs/anonymization.json")),
  ner=ner_meta, output_md5=as.list(tools::md5sum(paste0(dest,c(".rds",".parquet")))) ,
  code_md5=as.list(tools::md5sum(c("R/anonimizzazione_ner.R","R/anonimizzazione.R",
    "scripts/07f_combina_anonimizzazione.R"))),
  created_at=format(Sys.time(),tz="UTC",usetz=TRUE)),
  file.path(out,"anonimizzazione_metadata.json"),pretty=TRUE,auto_unbox=TRUE)
print(as.data.frame(riepilogo))
message("Dataset completo salvato: ", dest, ".rds / .parquet")
