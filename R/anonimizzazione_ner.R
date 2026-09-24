# Unione di intervalli sul testo originale, mai sul testo gia' mascherato.
# Indici Unicode da zero, estremo finale escluso (come spaCy).
intervalli_vuoti <- function() data.frame(start_char=integer(), end_char=integer())

localizza_dizionario <- function(testi, alias) {
  if (!length(alias)) return(rep(list(intervalli_vuoti()), length(testi)))
  pos <- stringi::stri_locate_all_regex(testi, pattern_alias(alias),
    omit_no_match=TRUE, opts_regex=stringi::stri_opts_regex(case_insensitive=TRUE))
  lapply(pos, function(x) data.frame(start_char=as.integer(x[,1]-1L),
                                    end_char=as.integer(x[,2])))
}

unisci_intervalli <- function(testo, dizionario, ner) {
  # Precedenza al dizionario. Match NER interni gia' coperti non aggiungono
  # sostituzioni; match che estendono/sovrappongono il dizionario vanno in revisione.
  scelti <- intervalli_vuoti()
  scelti$source <- character()
  conflitto <- FALSE
  controlla <- function(x) {
    if (!nrow(x)) return(invisible(NULL))
    stopifnot(all(x$start_char >= 0L), all(x$end_char > x$start_char),
              all(x$end_char <= stringi::stri_length(testo)))
    if ("entity" %in% names(x)) stopifnot(all(x$entity ==
      stringi::stri_sub(testo, x$start_char+1L, x$end_char)))
  }
  controlla(dizionario); controlla(ner)
  if (nrow(dizionario)) for (i in seq_len(nrow(dizionario))) {
    d <- dizionario[i, ]
    overlap <- scelti$start_char < d$end_char & scelti$end_char > d$start_char
    if (!any(overlap)) scelti <- rbind(scelti,
      data.frame(start_char=d$start_char, end_char=d$end_char, source="dictionary"))
  }
  decisioni <- ner
  decisioni$decision <- rep("", nrow(ner))
  if (nrow(ner)) for (i in seq_len(nrow(ner))) {
    e <- ner[i, ]
    overlap <- which(scelti$start_char < e$end_char & scelti$end_char > e$start_char)
    if (!length(overlap)) {
      scelti <- rbind(scelti, data.frame(start_char=e$start_char, end_char=e$end_char, source="ner"))
      decisioni$decision[i] <- "added"
    } else if (any(scelti$start_char[overlap] <= e$start_char &
                   scelti$end_char[overlap] >= e$end_char)) {
      exact <- overlap[scelti$start_char[overlap] == e$start_char & scelti$end_char[overlap] == e$end_char]
      if (length(exact)) scelti$source[exact] <- "dictionary+ner"
      decisioni$decision[i] <- "covered_by_dictionary"
    } else {
      conflitto <- TRUE
      decisioni$decision[i] <- "overlap_kept_dictionary_review"
    }
  }
  scelti <- scelti[order(scelti$start_char), , drop=FALSE]
  list(spans=scelti, conflict=conflitto, decisions=decisioni)
}

sostituisci_intervalli <- function(testo, spans) {
  if (!nrow(spans)) return(testo)
  spans <- spans[order(spans$start_char), , drop=FALSE]
  stopifnot(all(spans$start_char >= 0L), all(spans$end_char > spans$start_char),
            all(spans$end_char <= stringi::stri_length(testo)))
  if (nrow(spans) > 1L) stopifnot(all(head(spans$end_char,-1) <= tail(spans$start_char,-1)))
  cursor <- 0L
  pezzi <- character(nrow(spans)*2L+1L)
  for (i in seq_len(nrow(spans))) {
    pezzi[2L*i-1L] <- if (spans$start_char[i] > cursor)
      stringi::stri_sub(testo, cursor+1L, spans$start_char[i]) else ""
    pezzi[2L*i] <- "Person"
    cursor <- spans$end_char[i]
  }
  pezzi[length(pezzi)] <- if (cursor < stringi::stri_length(testo))
    stringi::stri_sub(testo, cursor+1L) else ""
  paste0(pezzi, collapse="")
}

aggiorna_revisione_ner <- function(df, indici, dizionario) {
  # Si ricalcolano i criteri esistenti sul risultato combinato; conflitti
  # e nomi a cavallo del confine prompt/continuazione restano da verificare.
  x <- df[indici, , drop=FALSE]
  labels <- sub(" (Jr\\.?|Sr\\.?|II|III|IV)$", "", gsub("_", " ", x$subject, fixed=TRUE))
  cognomi <- sub("^.* ", "", labels)
  utili <- stringi::stri_length(cognomi) >= 3L & !cognomi %in% c("Person", "XYZ")
  residui <- rep(FALSE, nrow(x))
  patterns <- vapply(unique(cognomi[utili]), pattern_alias, character(1))
  residui[utili] <- stringi::stri_detect_regex(x$text_anonymized[utili], unname(patterns[cognomi[utili]]))
  sospetti <- dizionario[dizionario$review_reason %in% c("known_nonperson_subject",
    "subject_not_recognized_as_profession"), ]
  chiave <- function(d) paste(d$domain, d$subject, sep="\r")
  nonpersona <- chiave(x) %in% chiave(sospetti)
  stato <- ifelse(x$anonymization_n_replacements == 0L, "no_entity_match",
                  ifelse(x$anonymization_n_prompt_replacements == 0L, "no_prompt_match", "applied"))
  reason <- dplyr::case_when(
    nonpersona ~ "subject_entity_type_unverified",
    x$ner_overlap_conflict ~ "ner_dictionary_overlap",
    x$ner_crosses_prompt_boundary ~ "entity_crosses_prompt_boundary",
    stato != "applied" ~ stato,
    residui ~ "residual_target_name_candidate",
    .default=NA_character_)
  df$anonymization_status[indici] <- stato
  df$anonymization_residual_name_candidate[indici] <- residui
  df$anonymization_review_reason[indici] <- reason
  df$anonymization_review_required[indici] <- !is.na(reason)
  df$eligible_anonymized_metrics[indici] <- x$eligible_english_metrics & stato == "applied" & is.na(reason)
  df
}
