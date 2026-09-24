# Preparazione del testo completo, senza modificare prompt o continuazione.
# Include il filtro preliminare Han; il mascheramento e' in anonimizzazione.R.

prepara_testi_metriche <- function(df) {
  richieste <- c("prompt", "generation", "status")
  mancanti <- setdiff(richieste, names(df))
  if (length(mancanti))
    stop("Colonne mancanti: ", paste(mancanti, collapse = ", "))

  for (nome in richieste) {
    if (!is.character(df[[nome]]))
      stop("Colonna non testuale: ", nome)
  }

  nuove <- c("text_full", "text_preparation_status")
  if (any(nuove %in% names(df)))
    stop("Le colonne di preparazione sono gia' presenti; usare l'input dell'audit.")

  # Un motivo principale per riga; le informazioni complete rimangono nei
  # flag dell'audit. Anche le righe non preparabili vengono conservate.
  nul <- if ("audit_nul_in_metric_text" %in% names(df)) df$audit_nul_in_metric_text else rep(FALSE,nrow(df))
  if (!is.logical(nul) || anyNA(nul)) stop("Flag audit_nul_in_metric_text non valido.")
  motivo <- dplyr::case_when(
    is.na(df$status) | df$status != "ok" ~ "generation_status_not_ok",
    nul ~ "nul_in_metric_text",
    is.na(df$prompt) ~ "missing_prompt",
    stringi::stri_trim_both(df$prompt) == "" ~ "empty_prompt",
    is.na(df$generation) ~ "missing_generation",
    stringi::stri_trim_both(df$generation) == "" ~ "empty_generation",
    .default = "prepared"
  )

  testo <- rep(NA_character_, nrow(df))
  valide <- motivo == "prepared"
  # Nessuno spazio aggiunto: la continuazione puo' iniziare con uno spazio,
  # punteggiatura oppure completare una parola iniziata nel prompt.
  testo[valide] <- paste0(df$prompt[valide], df$generation[valide])

  df$text_full <- testo
  df$text_preparation_status <- motivo
  df
}

applica_criterio_han <- function(df) {
  richieste <- c("text_full", "text_preparation_status", "audit_has_han")
  if (!all(richieste %in% names(df)))
    stop("Il criterio Han richiede i testi preparati e audit_has_han.")
  if (!is.logical(df$audit_has_han) || anyNA(df$audit_has_han))
    stop("audit_has_han deve essere un flag logico senza NA.")
  if (!is.character(df$text_preparation_status) || anyNA(df$text_preparation_status))
    stop("text_preparation_status deve essere testuale e senza NA.")

  nuove <- c("language_screen_policy", "eligible_english_metrics",
             "exclusion_reason", "language_review_required")
  if (any(nuove %in% names(df)))
    stop("Il criterio linguistico e' gia' stato applicato.")

  preparato <- df$text_preparation_status == "prepared"
  # Questo e' uno screening per scrittura Han nella sola continuazione,
  # non un classificatore della lingua. Un testo ammesso non e' certificato inglese.
  df$language_screen_policy <- rep("exclude_any_han_v1", nrow(df))
  df$eligible_english_metrics <- preparato & !df$audit_has_han
  df$language_review_required <- preparato & df$audit_has_han
  df$exclusion_reason <- dplyr::case_when(
    !preparato ~ df$text_preparation_status,
    df$audit_has_han ~ "han_pending_review",
    .default = NA_character_
  )
  df
}

riepiloga_copertura_metriche <- function(df, gruppi = "model_key") {
  dplyr::summarise(
    dplyr::group_by(df, dplyr::across(dplyr::all_of(gruppi))),
    n_records = dplyr::n(),
    n_prepared = sum(text_preparation_status == "prepared"),
    n_not_prepared = sum(text_preparation_status != "prepared"),
    n_excluded_han = sum(exclusion_reason %in% "han_pending_review"),
    n_eligible = sum(eligible_english_metrics),
    pct_excluded_han_prepared = if (n_prepared > 0) 100 * n_excluded_han / n_prepared else NA_real_,
    pct_eligible_prepared = if (n_prepared > 0) 100 * n_eligible / n_prepared else NA_real_,
    .groups = "drop"
  )
}
