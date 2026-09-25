# Mascheramento per il confronto BOLD. Il dizionario nasce dai prompt,
# mai dalle continuazioni o dai punteggi. Non e' un riconoscitore completo di entita'.

pattern_alias <- function(alias) {
  alias <- unique(alias[!is.na(alias) & nzchar(alias)])
  if (!length(alias)) return("(?!)")
  # Prima le espressioni piu' lunghe: nurse practitioner prima di nurse.
  alias <- alias[order(-stringi::stri_length(alias), alias)]
  quote_alias <- function(x)
    paste0("\\Q", stringi::stri_replace_all_fixed(x, "\\E", "\\E\\\\E\\Q"), "\\E")
  # Raggruppa prefissi comuni: evita di provare migliaia di alternative
  # a ogni parola del testo. Mantiene la precedenza degli alias piu' lunghi.
  prefissi <- function(x) {
    x <- unique(x)
    if (length(x) == 1L) return(quote_alias(x))
    primi <- stringi::stri_sub(x, 1, 2)
    chiavi <- stringi::stri_trans_casefold(primi)
    rami <- vapply(unique(chiavi), function(k) {
      indici <- which(chiavi == k)
      paste0(quote_alias(primi[indici[1]]), prefissi(stringi::stri_sub(x[indici], 3)))
    }, character(1))
    paste0("(?:", paste(rami, collapse = "|"), ")")
  }
  paste0("(?<![\\p{L}\\p{N}_])", prefissi(alias), "(?![\\p{L}\\p{N}_])")
}

plurale_professione <- function(termine) {
  # Varianti trasparenti del nome professionale; le eccezioni sono configurabili.
  dplyr::case_when(
    grepl("midwife$", termine, ignore.case = TRUE) ~ sub("wife$", "wives", termine, ignore.case = TRUE),
    grepl("man$", termine, ignore.case = TRUE) ~ sub("man$", "men", termine, ignore.case = TRUE),
    grepl("[^aeiou]y$", termine, ignore.case = TRUE) ~ sub("y$", "ies", termine, ignore.case = TRUE),
    grepl("(ch|sh|x|z)$", termine, ignore.case = TRUE) ~ paste0(termine, "es"),
    grepl("s$", termine, ignore.case = TRUE) ~ termine,
    .default = paste0(termine, "s")
  )
}

costruisci_dizionario_anonimizzazione <- function(df, config) {
  richieste <- c("domain", "subject", "prompt_id", "prompt")
  if (!all(richieste %in% names(df))) stop("Mancano le colonne dei prompt per il dizionario.")
  if (anyNA(df[c("domain", "subject", "prompt_id")])) stop("Identificativi dei prompt mancanti.")
  soggetti <- dplyr::distinct(df, domain, subject)
  label <- stringi::stri_trim_both(gsub("_", " ", soggetti$subject, fixed = TRUE))
  persone <- soggetti$domain %in% c("gender", "race")
  professioni <- soggetti$domain == "profession"
  testa <- stringi::stri_trans_tolower(sub("^.*[ -]", "", label), locale = "en")
  riconosciuta <- testa %in% config$profession_heads
  candidati <- data.frame(
    domain = soggetti$domain, subject = soggetti$subject, alias = label,
    replacement = ifelse(persone, "Person", "XYZ"), source = "subject_label",
    enabled = (persone & !soggetti$subject %in% config$blocked_person_subjects) |
      (professioni & riconosciuta),
    stringsAsFactors = FALSE
  )
  candidati$review_reason <- dplyr::case_when(
    persone & soggetti$subject %in% config$blocked_person_subjects ~ "known_nonperson_subject",
    professioni & !riconosciuta ~ "subject_not_recognized_as_profession",
    !persone & !professioni ~ "use_identifying_terms_not_entire_page_title",
    .default = NA_character_
  )
  # Per ideologie/religioni i titoli restano nel report dei candidati;
  # solo i termini identificativi espliciti entrano nella sostituzione.
  plurali <- candidati[professioni & candidati$enabled, ]
  plurali$alias <- plurale_professione(plurali$alias)
  plurali$source <- rep("profession_plural", nrow(plurali))
  termini <- function(domain, alias, source) data.frame(
    domain = rep(domain, length(alias)), subject = rep("*", length(alias)),
    alias = alias, replacement = rep("XYZ", length(alias)),
    source = rep(source, length(alias)), enabled = rep(TRUE, length(alias)),
    review_reason = rep(NA_character_, length(alias))
  )
  dizionario <- dplyr::bind_rows(
    candidati, plurali,
    termini("profession", config$profession_extra_terms, "configured_profession"),
    termini("religious_ideology", config$religious_terms, "configured_religion"),
    termini("political_ideology", config$political_terms, "configured_ideology")
  )
  # Alias personali espliciti e legati a un soggetto; nessuna estrazione
  # automatica di soli nomi o cognomi (May, Brown, ecc. sono ambigui).
  alias_personali <- config$person_aliases
  if (is.data.frame(alias_personali)) {
    alias_personali <- lapply(seq_len(nrow(alias_personali)), function(i)
      as.list(alias_personali[i, , drop = FALSE]))
  }
  for (voce in alias_personali) {
    if (!voce$domain %in% c("gender", "race") || !nzchar(voce$subject) || !nzchar(voce$alias))
      stop("Alias personale non valido nella configurazione.")
    dizionario <- dplyr::bind_rows(dizionario, data.frame(
      domain = voce$domain, subject = voce$subject, alias = voce$alias,
      replacement = "Person", source = "configured_person_alias", enabled = TRUE,
      review_reason = NA_character_
    ))
  }
  if (anyNA(dizionario$alias) || any(!nzchar(dizionario$alias)) ||
      any(dizionario$enabled & dizionario$alias %in% c("Person", "XYZ")))
    stop("Il dizionario contiene alias vuoti o coincidenti con i placeholder.")
  dplyr::distinct(dizionario)
}

anonimizza_testi <- function(df, dizionario, versione) {
  richieste <- c("text_full", "text_preparation_status", "domain", "subject", "prompt", "eligible_english_metrics")
  if (!all(richieste %in% names(df))) stop("Mancano i testi preparati per l'anonimizzazione.")
  if (any(c("text_anonymized", "anonymization_status") %in% names(df)))
    stop("Anonimizzazione gia' presente.")
  if (anyNA(dizionario$enabled)) stop("Flag enabled del dizionario mancante.")

  df$text_anonymized <- df$text_full
  df$prompt_anonymized <- df$prompt
  df$anonymization_policy <- rep(versione, nrow(df))
  df$anonymization_n_replacements <- rep(NA_integer_, nrow(df))
  df$anonymization_n_prompt_replacements <- rep(NA_integer_, nrow(df))
  pronto <- df$text_preparation_status == "prepared"
  df$anonymization_n_replacements[pronto] <- 0L
  df$anonymization_n_prompt_replacements[pronto] <- 0L
  dettagli <- list()
  opzioni <- stringi::stri_opts_regex(case_insensitive = TRUE)

  sostituisci <- function(indici, alias, placeholder) {
    if (!length(indici) || !length(alias)) return(invisible(NULL))
    pattern <- pattern_alias(alias)
    trovati <- stringi::stri_extract_all_regex(df$text_anonymized[indici], pattern,
      omit_no_match = TRUE, opts_regex = opzioni)
    conteggi <- lengths(trovati)
    df$anonymization_n_replacements[indici] <<- df$anonymization_n_replacements[indici] + conteggi
    df$anonymization_n_prompt_replacements[indici] <<-
      df$anonymization_n_prompt_replacements[indici] +
      stringi::stri_count_regex(df$prompt_anonymized[indici], pattern, opts_regex = opzioni)
    df$text_anonymized[indici] <<- stringi::stri_replace_all_regex(
      df$text_anonymized[indici], pattern, placeholder, opts_regex = opzioni)
    df$prompt_anonymized[indici] <<- stringi::stri_replace_all_regex(
      df$prompt_anonymized[indici], pattern, placeholder, opts_regex = opzioni)
    usati <- unlist(trovati, use.names = FALSE)
    if (length(usati)) {
      dettagli[[length(dettagli) + 1L]] <<- dplyr::count(data.frame(
        domain = df$domain[indici[1]],
        matched_text = usati, replacement = placeholder
      ), domain, matched_text, replacement, name = "n_replacements")
    }
    invisible(NULL)
  }

  for (dominio in unique(df$domain)) {
    voci <- dizionario[dizionario$domain == dominio & dizionario$enabled, ]
    base <- voci[voci$source != "configured_person_alias", ]
    placeholder <- if (dominio %in% c("gender", "race")) "Person" else "XYZ"
    sostituisci(which(pronto & df$domain == dominio), base$alias, placeholder)
    # Gli alias abbreviati valgono solo per il soggetto a cui sono associati.
    extra <- voci[voci$source == "configured_person_alias", ]
    for (soggetto in unique(extra$subject)) {
      sostituisci(which(pronto & df$domain == dominio & df$subject == soggetto),
                  extra$alias[extra$subject == soggetto], placeholder)
    }
  }
  df$anonymization_status <- dplyr::case_when(
    !pronto ~ "not_prepared",
    df$anonymization_n_replacements == 0L ~ "no_dictionary_match",
    df$anonymization_n_prompt_replacements == 0L ~ "no_prompt_match",
    .default = "applied"
  )
  # Cognomi residui: solo segnalazione, mai sostituzione automatica. La
  # ricerca distingue maiuscole/minuscole per non confondere Brown con brown.
  df$anonymization_residual_name_candidate <- rep(FALSE, nrow(df))
  persone <- which(pronto & df$domain %in% c("gender", "race"))
  labels <- gsub("_", " ", df$subject[persone], fixed = TRUE)
  labels <- sub(" (Jr\\.?|Sr\\.?|II|III|IV)$", "", labels)
  cognomi <- sub("^.* ", "", labels)
  # Nomi a una parola gia' mascherati non producono un candidato residuo.
  utili <- stringi::stri_length(cognomi) >= 3L & !cognomi %in% c("Person", "XYZ")
  pattern_cognomi <- vapply(unique(cognomi[utili]), pattern_alias, character(1))
  if (any(utili)) {
    df$anonymization_residual_name_candidate[persone[utili]] <- stringi::stri_detect_regex(
      df$text_anonymized[persone[utili]], unname(pattern_cognomi[cognomi[utili]]))
  }

  # Una sostituzione non certifica che il testo non contenga altri nomi.
  sospetti <- dizionario[dizionario$review_reason %in% c(
    "known_nonperson_subject", "subject_not_recognized_as_profession"), c("domain", "subject")]
  chiave <- function(d) paste(d$domain, d$subject, sep = "\r")
  da_verificare <- chiave(df) %in% chiave(sospetti)
  df$anonymization_review_required <- pronto &
    (df$anonymization_status != "applied" | da_verificare | df$anonymization_residual_name_candidate)
  df$anonymization_review_reason <- dplyr::case_when(
    !pronto ~ NA_character_,
    da_verificare ~ "subject_entity_type_unverified",
    df$anonymization_status != "applied" ~ df$anonymization_status,
    df$anonymization_residual_name_candidate ~ "residual_target_name_candidate",
    .default = NA_character_
  )
  # Screening Han e revisione dell'anonimizzazione sono criteri separati.
  df$eligible_anonymized_metrics <- df$eligible_english_metrics &
    df$anonymization_status == "applied" & !df$anonymization_review_required
  dettagli <- if (length(dettagli)) {
    dplyr::summarise(dplyr::group_by(dplyr::bind_rows(dettagli), domain, matched_text, replacement),
                     n_replacements = sum(n_replacements), .groups = "drop")
  } else data.frame(domain = character(), matched_text = character(),
                    replacement = character(), n_replacements = integer())
  list(data = df, replacements = dettagli)
}

campiona_anonimizzazione <- function(df, n_per_group = 3L) {
  # Campione deterministico per categoria/stato; stessi prompt per i modelli.
  chiavi <- dplyr::distinct(df, domain, category, anonymization_status, prompt_id)
  chiavi <- dplyr::arrange(chiavi, domain, category, anonymization_status, prompt_id)
  chiavi <- dplyr::slice_head(dplyr::group_by(chiavi, domain, category, anonymization_status), n = n_per_group)
  chiavi <- dplyr::distinct(dplyr::ungroup(chiavi), prompt_id)
  prima <- dplyr::filter(df, repetition == 1L)
  dplyr::select(dplyr::semi_join(prima, chiavi, by = "prompt_id"),
    model_key, prompt_id, repetition, domain, category, subject,
    prompt, generation, text_full, text_anonymized, anonymization_status,
    anonymization_n_replacements, anonymization_review_required, anonymization_review_reason,
    anonymization_residual_name_candidate)
}
