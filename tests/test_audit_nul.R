if (dir.exists(".audit-r-library")) .libPaths(c(".audit-r-library", .libPaths()))
source("R/audit_generazioni.R")
source("R/preparazione_metriche.R")
df <- data.frame(prompt_id=letters[1:5],model_key="qwen3_8b_base",repetition=1L,
  domain="gender",category="test",subject="Example",prompt="Example ",
  generation=c("normal", "", NA, "placeholder", "placeholder"),
  status="ok",generated_tokens=5,finish_reason="eos_token")
bytes <- list(charToRaw("normal"),raw(0),NULL,
  c(charToRaw("a"),as.raw(0),charToRaw("b\u6f22?"),as.raw(0)),as.raw(0))
cols <- lapply(df,arrow::Array$create)
cols$generation <- arrow::Array$create(bytes,type=arrow::binary())$cast(arrow::utf8())
tab <- do.call(arrow::Table$create,cols)
path <- tempfile(fileext=".parquet")
arrow::write_parquet(tab,path)
before <- tools::md5sum(path)
option_before <- getOption("arrow.skip_nul")
r <- leggi_parquet_audit(path)
stopifnot(identical(before,tools::md5sum(path)),identical(option_before,getOption("arrow.skip_nul")),
  identical(r$data$generation,c("normal","",NA,"a\uFFFDb\u6f22?\uFFFD","\uFFFD")),
  identical(r$data$audit_n_nul,c(0L,0L,0L,2L,1L)),
  identical(which(r$data$audit_has_nul),4:5),nrow(r$nul_report)==2L,
  r$nul_report$original_utf8_hex[1]==paste0(format(bytes[[4]]),collapse=""))
flagged <- aggiungi_flag_generazioni(r$data)
stopifnot(all(flagged$audit_review[4:5]),flagged$audit_has_han[4],flagged$audit_has_question_mark[4])
prepared <- applica_criterio_han(prepara_testi_metriche(flagged))
stopifnot(all(prepared$text_preparation_status[4:5]=="nul_in_metric_text"),
  all(is.na(prepared$text_full[4:5])),!any(prepared$eligible_english_metrics[4:5]))
plain_path <- tempfile(fileext=".parquet")
arrow::write_parquet(df,plain_path)
plain <- leggi_parquet_audit(plain_path)
expected <- as.data.frame(arrow::read_parquet(plain_path))
stopifnot(all(vapply(names(expected),function(n) identical(plain$data[[n]],expected[[n]]),logical(1))),
  nrow(plain$nul_report)==0L,!any(plain$data$audit_has_nul))
cols$prompt <- arrow::Array$create(rep(list(c(charToRaw("x"),as.raw(0))),5),
                                 type=arrow::binary())$cast(arrow::utf8())
multi_path <- tempfile(fileext=".parquet")
arrow::write_parquet(do.call(arrow::Table$create,cols),multi_path)
multi <- leggi_parquet_audit(multi_path)
stopifnot(all(multi$data$audit_nul_in_metric_text),multi$data$audit_n_nul[4]==3L,
          grepl("prompt",multi$data$audit_nul_columns[4]),grepl("generation",multi$data$audit_nul_columns[4]))
cat("OK: NUL, UTF-8, celle vuote/NA, byte originali, input invariato ed esclusione dalle metriche.\n")
