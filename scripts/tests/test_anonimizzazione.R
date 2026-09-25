# Rscript scripts/tests/test_anonimizzazione.R
if (dir.exists(".audit-r-library")) .libPaths(c(".audit-r-library", .libPaths()))
source("R/preparazione_metriche.R")
source("R/anonimizzazione.R")
config <- jsonlite::fromJSON("configs/anonymization.json")
config$person_aliases <- list()
df <- data.frame(
  model_key = "base", prompt_id = paste0("p", 1:9), repetition = 1L,
  domain = c("gender", "profession", "profession", "political_ideology", "religious_ideology", "race", "gender", "gender", "profession"),
  category = "test",
  subject = c("Alice_White", "Nurse_practitioner", "Jewellery", "Left-wing_terrorism", "Judaism", "Guitar_Hero", "Alice_White", "Alice_White", "Midwife"),
  prompt = c("Alice White is", "A nurse practitioner", "Jewellery is", "Left-wing terrorism is", "Judaism is", "Guitar Hero is", "Alice White", "", "The midwife"),
  generation = c(" kind. Alice White said she is not bad.", " helps nurses and nursesharks.", " beautiful.", " violent. Do not turn left.", " discussed by Jews; Jewishness differs.", " a game.", " \u4f60\u597d", NA, " works with midwives."),
  status = c(rep("ok", 7), "skipped_empty_prompt", "ok"),
  audit_has_han = c(rep(FALSE, 6), TRUE, FALSE, FALSE)
)
prepared <- applica_criterio_han(prepara_testi_metriche(df))
dict <- costruisci_dizionario_anonimizzazione(df, config)
r <- anonimizza_testi(prepared, dict, config$version)
a <- r$data
stopifnot(
  a$text_anonymized[1] == "Person is kind. Person said she is not bad.",
  a$anonymization_n_replacements[1] == 2L,
  a$text_anonymized[2] == "A XYZ helps XYZ and nursesharks.",
  a$text_anonymized[3] == a$text_full[3], a$anonymization_review_required[3],
  a$text_anonymized[4] == "XYZ terrorism is violent. Do not turn left.",
  a$text_anonymized[5] == "XYZ is discussed by XYZ; Jewishness differs.",
  a$text_anonymized[6] == a$text_full[6], a$anonymization_review_required[6],
  !a$eligible_anonymized_metrics[7], is.na(a$text_anonymized[8]),
  a$text_anonymized[9] == "The XYZ works with XYZ.",
  all(vapply(names(prepared), function(n) identical(prepared[[n]], a[[n]]), logical(1))),
  sum(r$replacements$n_replacements) == sum(a$anonymization_n_replacements, na.rm = TRUE)
)

# Regex letterali, accenti e confini Unicode; nessuna sostituzione di sottostringhe.
pattern <- pattern_alias(c("A. R. Rahman", "Jos\u00e9 Smith", "C++"))
stopifnot(identical(stringi::stri_replace_all_regex(
  c("A. R. Rahman's", "Ax Rz Rahman", "Jos\u00e9 Smith", "XJos\u00e9 Smith", "C++"), pattern, "Person"),
  c("Person's", "Ax Rz Rahman", "Person", "XJos\u00e9 Smith", "Person")))
stopifnot(stringi::stri_detect_regex("A\\EB", pattern_alias("A\\EB")))
# I prefissi condivisi non cambiano la priorita' degli alias sovrapposti.
alias <- c("Nurse", "nurse practitioner", "Nursery worker", "A", "Alice White", "Alice White Jr.")
literal <- alias[order(-stringi::stri_length(alias), alias)]
naive <- paste0("(?<![\\p{L}\\p{N}_])(?:", paste0("\\Q", literal, "\\E", collapse="|"), ")(?![\\p{L}\\p{N}_])")
frasi <- c("NURSE practitioner and Nurse", "Alice White Jr. and Alice White", "A nursery worker")
opzioni <- stringi::stri_opts_regex(case_insensitive=TRUE)
stopifnot(identical(stringi::stri_extract_all_regex(frasi, naive, opts_regex=opzioni),
                    stringi::stri_extract_all_regex(frasi, pattern_alias(alias), opts_regex=opzioni)))

# Alias abbreviati solo sul soggetto esplicito; il testo generato non crea alias.
config$person_aliases <- list(list(domain="gender", subject="Alice_White", alias="White"))
extra <- df[c(1,1), ]
extra$prompt_id <- c("x", "y")
extra$subject <- c("Alice_White", "Mary_Brown")
extra$prompt <- c("Alice White is", "Mary Brown is")
extra$generation <- c(" White. New Person Name appeared.", " White.")
d <- costruisci_dizionario_anonimizzazione(extra, config)
stopifnot(!"New Person Name" %in% d$alias)
b <- anonimizza_testi(applica_criterio_han(prepara_testi_metriche(extra)), d, config$version)$data
stopifnot(b$text_anonymized[1] == "Person is Person. New Person Name appeared.",
          b$text_anonymized[2] == "Person is White.")
# Piu' modelli/repliche non cambiano il dizionario.
altro <- df; altro$model_key <- "post"; altro$repetition <- 2L
config$person_aliases <- list()
stopifnot(identical(dict, costruisci_dizionario_anonimizzazione(rbind(df, altro), config)))
# Un cognome residuo viene segnalato; non si cambia la parola comune brown.
residui <- df[c(1,1), ]
residui$subject <- "Mary_Brown"
residui$prompt <- "Mary Brown is"
residui$generation <- c(" Brown, with brown hair.", " a woman with brown hair.")
d <- costruisci_dizionario_anonimizzazione(residui, config)
b <- anonimizza_testi(applica_criterio_han(prepara_testi_metriche(residui)),d,config$version)$data
stopifnot(identical(b$anonymization_residual_name_candidate,c(TRUE,FALSE)),
          !b$eligible_anonymized_metrics[1], b$eligible_anonymized_metrics[2],
          b$text_anonymized[1] == "Person is Brown, with brown hair.")
cat("OK: nomi, ruoli, ideologie, confini, alias, Han, dati preservati e revisione.\n")
