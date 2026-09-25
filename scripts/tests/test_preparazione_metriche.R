# Rscript scripts/tests/test_preparazione_metriche.R
if (dir.exists(".audit-r-library")) .libPaths(c(".audit-r-library", .libPaths()))
source("R/preparazione_metriche.R")

df <- data.frame(
  prompt = c("The doctor", "Hello", "un", "Text ", "Name", NA, "", "Text", "Text", "Text", "Text"),
  generation = c(" is kind.", ", world!", "happy", "\u4f60\u597d", "? False.", " result", " result", NA, "\t", " result", ""),
  status = c(rep("ok", 9), NA, "skipped_empty_prompt"),
  audit_has_han = c(FALSE, FALSE, FALSE, TRUE, rep(FALSE, 7)),
  audit_has_question_mark = c(rep(FALSE, 4), TRUE, rep(FALSE, 6))
)
r <- prepara_testi_metriche(df)
stopifnot(
  identical(r$text_full[1:5], c("The doctor is kind.", "Hello, world!", "unhappy", "Text \u4f60\u597d", "Name? False.")),
  all(is.na(r$text_full[6:11])),
  identical(r$text_preparation_status[6:11], c("missing_prompt", "empty_prompt", "missing_generation", "empty_generation", "generation_status_not_ok", "generation_status_not_ok")),
  nrow(r) == nrow(df),
  all(vapply(names(df), function(nome) identical(r[[nome]], df[[nome]]), logical(1))),
  nrow(prepara_testi_metriche(df[FALSE, ])) == 0L,
  inherits(try(prepara_testi_metriche(r), silent = TRUE), "try-error"),
  inherits(try(prepara_testi_metriche(df[setdiff(names(df), "prompt")]), silent = TRUE), "try-error")
)
h <- applica_criterio_han(r)
stopifnot(
  identical(h$eligible_english_metrics, c(TRUE, TRUE, TRUE, FALSE, TRUE, rep(FALSE, 6))),
  h$exclusion_reason[4] == "han_pending_review",
  h$language_review_required[4],
  is.na(h$exclusion_reason[5]), # '?' e False non sono criteri di esclusione.
  all(vapply(names(r), function(nome) identical(h[[nome]], r[[nome]]), logical(1))),
  nrow(applica_criterio_han(r[FALSE, ])) == 0L
)
missing_flag <- r
missing_flag$audit_has_han[1] <- NA
stopifnot(inherits(try(applica_criterio_han(missing_flag), silent = TRUE), "try-error"))

# La politica non deve presentare l'assenza di Han come prova di inglese.
lingue <- data.frame(
  prompt = "Text: ", generation = c("\u4f60\u597d", "English \u4f60\u597d", "Bonjour le monde", "\U00020000"),
  status = "ok", audit_has_han = c(TRUE, TRUE, FALSE, TRUE)
)
lingue <- applica_criterio_han(prepara_testi_metriche(lingue))
stopifnot(identical(lingue$eligible_english_metrics, c(FALSE, FALSE, TRUE, FALSE)))
h$model_key <- "test"
s <- riepiloga_copertura_metriche(h)
stopifnot(s$n_records == 11, s$n_prepared == 5, s$n_excluded_han == 1,
          s$n_eligible == 4, s$pct_excluded_han_prepared == 20)
z <- riepiloga_copertura_metriche(h[6:11, ])
stopifnot(z$n_prepared == 0, is.na(z$pct_excluded_han_prepared))
cat("OK: concatenazione, conservazione dei dati, criterio Han, quiz e denominatori.\n")
