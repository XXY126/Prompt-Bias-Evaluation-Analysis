# Funzioni per l'audit delle continuazioni Qwen3. Nessuna riga viene rimossa
# dal dataset annotato. I Parquet originali non vengono modificati; gli eventuali
# NUL sono rappresentati con U+FFFD nella copia R e conservati in un report hex.

verifica_schema_generazioni <- function(df) {
  richieste <- c("prompt_id", "model_key", "repetition", "domain", "category",
                 "subject", "prompt", "generation", "status", "generated_tokens",
                 "finish_reason")
  mancanti <- setdiff(richieste, names(df))
  if (length(mancanti)) stop("Colonne mancanti: ", paste(mancanti, collapse = ", "))
  if (!nrow(df)) stop("Il Parquet non contiene record.")
  for (nome in c("prompt_id", "model_key", "domain", "category", "subject",
                 "prompt", "generation", "status", "finish_reason")) {
    if (!is.character(df[[nome]])) stop("Colonna non testuale: ", nome)
  }
  chiavi <- c("prompt_id", "model_key", "repetition")
  if (anyNA(df[chiavi])) stop("Chiavi identificative mancanti.")
  if (!is.numeric(df$repetition) || any(df$repetition < 1 | df$repetition %% 1 != 0)) {
    stop("Repetition deve contenere interi positivi.")
  }
  if (!is.numeric(df$generated_tokens)) stop("generated_tokens deve essere numerico.")
  invisible(TRUE)
}

aggiungi_flag_generazioni <- function(df) {
  verifica_schema_generazioni(df)
  if (!"audit_has_nul" %in% names(df)) df$audit_has_nul <- FALSE
  if (!"audit_n_nul" %in% names(df)) df$audit_n_nul <- 0L
  if (!"audit_nul_in_metric_text" %in% names(df)) df$audit_nul_in_metric_text <- FALSE
  testo <- df$generation
  non_vuoto <- !is.na(testo) & stringi::stri_trim_both(testo) != ""
  df$audit_has_text <- non_vuoto
  df$audit_status_ok <- !is.na(df$status) & df$status == "ok"
  df$audit_empty_generation <- df$audit_status_ok & !non_vuoto
  df$audit_missing_prompt <- is.na(df$prompt)
  df$audit_empty_prompt <- !is.na(df$prompt) & stringi::stri_trim_both(df$prompt) == ""
  df$audit_unexpected_status <- is.na(df$status) |
    !df$status %in% c("ok", "skipped_empty_prompt")
  df$audit_status_inconsistent <-
    (df$status %in% "skipped_empty_prompt" & (!df$audit_empty_prompt | non_vuoto)) |
    (df$audit_status_ok & df$audit_empty_prompt)
  df$audit_at_token_limit <- df$finish_reason %in% "max_new_tokens"
  if ("generation_hit_token_limit" %in% names(df))
    df$audit_at_token_limit <- df$generation_hit_token_limit %in% TRUE
  df$audit_sentence_incomplete <- if ("sentence_complete" %in% names(df))
    df$audit_status_ok & !(df$sentence_complete %in% TRUE) else rep(FALSE,nrow(df))
  df$audit_n_chars <- stringi::stri_length(testo)
  df$audit_n_letters <- stringi::stri_count_regex(testo, "\\p{L}")
  df$audit_n_han <- stringi::stri_count_regex(testo, "\\p{script=Han}")
  df$audit_n_han_letters <- stringi::stri_count_regex(testo, "[\\p{L}&&\\p{script=Han}]")
  df$audit_n_latin <- stringi::stri_count_regex(testo, "\\p{script=Latin}")
  df$audit_has_han <- !is.na(df$audit_n_han) & df$audit_n_han > 0
  df$audit_han_share_letters <- ifelse(df$audit_n_letters > 0,
                                      df$audit_n_han_letters / df$audit_n_letters, NA_real_)
  df$audit_han_and_latin <- df$audit_has_han & df$audit_n_latin > 0
  df$audit_has_kana <- !is.na(testo) & stringi::stri_detect_regex(
    testo, "[\\p{script=Hiragana}\\p{script=Katakana}]")
  df$audit_prompt_has_han <- !is.na(df$prompt) &
    stringi::stri_detect_regex(df$prompt, "\\p{script=Han}")
  df$audit_han_only_in_generation <- df$audit_has_han &
    !df$audit_prompt_has_han & !df$audit_missing_prompt
  # Euristica richiesta per possibili quiz: '?' letterale nella sola
  # continuazione. Non verifica che alla domanda segua una risposta.
  df$audit_n_question_marks <- stringi::stri_count_fixed(testo, "?")
  df$audit_has_question_mark <- !is.na(df$audit_n_question_marks) &
    df$audit_n_question_marks > 0L
  # Un segnale semplice di loop, non una classificazione di qualita'.
  df$audit_repeated_word <- !is.na(testo) & stringi::stri_detect_regex(
    testo, "(?i)\\b(\\p{L}+)\\b(?:\\s+\\1\\b){3,}")
  df$audit_roundtrip_mismatch <- if ("tokenizer_roundtrip_matches" %in% names(df)) {
    !is.na(df$tokenizer_roundtrip_matches) & !df$tokenizer_roundtrip_matches
  } else rep(NA, nrow(df))
  df <- dplyr::group_by(df, model_key, prompt_id, repetition)
  df <- dplyr::mutate(df, audit_duplicate_key = dplyr::n() > 1L)
  df <- dplyr::ungroup(df)
  df$audit_review <- df$audit_has_han | df$audit_has_question_mark | df$audit_empty_generation |
    df$audit_unexpected_status | df$audit_status_inconsistent |
    df$audit_missing_prompt | df$audit_repeated_word | df$audit_duplicate_key |
    (df$audit_roundtrip_mismatch %in% TRUE) | df$audit_has_nul | df$audit_sentence_incomplete
  df
}

riepiloga_generazioni <- function(df, gruppi = "model_key") {
  media <- function(x) if (all(is.na(x))) NA_real_ else mean(x, na.rm = TRUE)
  dplyr::summarise(
    dplyr::group_by(df, dplyr::across(dplyr::all_of(gruppi))),
    n_records = dplyr::n(), n_prompts = dplyr::n_distinct(prompt_id),
    n_ok = sum(audit_status_ok),
    n_skipped_empty = sum(status %in% "skipped_empty_prompt"),
    n_empty_generation = sum(audit_empty_generation),
    n_unexpected_status = sum(audit_unexpected_status),
    n_status_inconsistent = sum(audit_status_inconsistent),
    n_duplicate_key_rows = sum(audit_duplicate_key),
    n_at_token_limit = sum(audit_at_token_limit & audit_status_ok),
    pct_at_token_limit_ok = 100 * media(audit_at_token_limit[audit_status_ok]),
    mean_generated_tokens_ok = media(generated_tokens[audit_status_ok]),
    mean_chars_ok = media(audit_n_chars[audit_status_ok]),
    n_nonempty_ok = sum(audit_has_text & audit_status_ok),
    n_han_ok = sum(audit_has_han & audit_status_ok),
    pct_han_nonempty_ok = 100 * media(audit_has_han[audit_has_text & audit_status_ok]),
    n_han_and_latin_ok = sum(audit_han_and_latin & audit_status_ok),
    n_han_only_in_generation_ok = sum(audit_han_only_in_generation & audit_status_ok),
    n_question_mark_ok = sum(audit_has_question_mark & audit_status_ok),
    pct_question_mark_nonempty_ok = 100 *
      media(audit_has_question_mark[audit_has_text & audit_status_ok]),
    n_repeated_word = sum(audit_repeated_word),
    n_nul_rows = sum(audit_has_nul),
    n_nul_characters = sum(audit_n_nul),
    n_sentence_incomplete = sum(audit_sentence_incomplete),
    n_review = sum(audit_review), .groups = "drop"
  )
}

# ------------------------------------------------------------
# Diversita' delle repliche: uguaglianza dopo normalizzazione
# ------------------------------------------------------------

normalizza_generazione <- function(testo) {
  # Copia di confronto: minuscole e spazi Unicode uniformati.
  # Punteggiatura, accenti, numeri e parole restano presenti.
  testo <- stringi::stri_trans_tolower(testo, locale = "en")
  testo <- stringi::stri_replace_all_regex(testo, "\\p{White_Space}+", " ")
  stringi::stri_trim_both(testo)
}

analizza_diversita_repliche <- function(df) {
  # Chiavi duplicate sono problemi tecnici, non repliche indipendenti:
  # questi gruppi rimangono nel report, con misure di diversita' NA.
  dati <- dplyr::group_by(df, model_key, prompt_id)
  dati <- dplyr::mutate(
    dati,
    replica_group_invalid = any(audit_duplicate_key)
  )
  dati <- dplyr::ungroup(dati)

  per_prompt <- dplyr::summarise(
    dplyr::group_by(dati, model_key, prompt_id),
    domain = dplyr::first(domain),
    category = dplyr::first(category),
    subject = dplyr::first(subject),
    prompt = dplyr::first(prompt),
    n_records = dplyr::n(),
    n_valid = sum(audit_status_ok & audit_has_text),
    replica_group_invalid = any(replica_group_invalid),
    .groups = "drop"
  )

  valide <- dplyr::filter(
    dati,
    audit_status_ok & audit_has_text & !replica_group_invalid
  )
  valide$generation_normalized <- normalizza_generazione(valide$generation)

  # Raggruppare testi normalizzati permette di contare anche le coppie
  # uguali senza costruire tutte le combinazioni di righe.
  frequenze <- dplyr::count(
    valide, model_key, prompt_id, generation_normalized,
    name = "n_same_normalized"
  )
  misure <- dplyr::summarise(
    dplyr::group_by(frequenze, model_key, prompt_id),
    n_unique_normalized = dplyr::n(),
    max_same_normalized = if (length(n_same_normalized)) {
      max(n_same_normalized)
    } else {
      NA_integer_
    },
    n_equal_pairs_normalized = sum(choose(n_same_normalized, 2)),
    .groups = "drop"
  )
  per_prompt <- dplyr::left_join(
    per_prompt, misure, by = c("model_key", "prompt_id")
  )
  per_prompt <- dplyr::mutate(
    per_prompt,
    n_unique_normalized = dplyr::if_else(
      replica_group_invalid, NA_integer_,
      dplyr::coalesce(n_unique_normalized, 0L)
    ),
    n_redundant_normalized = n_valid - n_unique_normalized,
    n_pairs = dplyr::if_else(replica_group_invalid, NA_real_, choose(n_valid, 2)),
    n_equal_pairs_normalized = dplyr::if_else(
      replica_group_invalid, NA_real_,
      dplyr::coalesce(n_equal_pairs_normalized, 0)
    ),
    all_identical_normalized = dplyr::if_else(
      !replica_group_invalid & n_valid >= 2,
      n_unique_normalized == 1L, NA
    )
  )

  # Una riga per replica coinvolta, con testo originale e copia normalizzata.
  uguali <- dplyr::inner_join(
    valide,
    dplyr::filter(frequenze, n_same_normalized >= 2),
    by = c("model_key", "prompt_id", "generation_normalized")
  )
  uguali <- dplyr::arrange(uguali, model_key, prompt_id, repetition)

  # n_valid resta nella distribuzione: 1 testo disponibile e 5 testi uguali
  # sono situazioni diverse. Include anche gruppi senza testi validi.
  distribuzione <- dplyr::count(
    per_prompt, model_key, domain, category, replica_group_invalid,
    n_valid, n_unique_normalized, name = "n_prompts"
  )
  list(per_prompt = per_prompt, uguali = uguali, distribuzione = distribuzione)
}

estrai_passaggi_han <- function(df, contesto = 50L) {
  # Coordinate 1-based in caratteri Unicode nella SOLA continuazione.
  # Un passaggio e' una sequenza contigua Han; la colonna context conserva
  # punteggiatura e testo circostante. Han non equivale a lingua cinese.
  id_cols <- c("model_key", "prompt_id", "repetition", "domain", "category", "subject")
  parti <- lapply(which(df$audit_has_han), function(i) {
    pos <- stringi::stri_locate_all_regex(df$generation[i], "\\p{script=Han}+")[[1]]
    out <- df[rep(i, nrow(pos)), id_cols, drop = FALSE]
    out$segment_index <- seq_len(nrow(pos))
    out$start_char <- pos[, 1]
    out$end_char <- pos[, 2]
    out$han_segment <- stringi::stri_sub(df$generation[i], pos[, 1], pos[, 2])
    out$context <- stringi::stri_sub(df$generation[i], pmax(1L, pos[, 1] - contesto),
                                   pos[, 2] + contesto)
    out
  })
  if (length(parti)) return(dplyr::bind_rows(parti))
  out <- df[FALSE, id_cols, drop = FALSE]
  out$segment_index <- out$start_char <- out$end_char <- integer()
  out$han_segment <- out$context <- character()
  out
}

controlla_abbinamento_generazioni <- function(df, modelli) {
  # Si aggrega prima del join: chiavi duplicate restano visibili, senza
  # moltiplicare artificialmente le coppie Base/post-trained.
  conteggi <- dplyr::count(df, prompt_id, repetition, model_key, name = "n_records")
  chiavi <- dplyr::distinct(df, prompt_id, repetition)
  griglia <- merge(as.data.frame(chiavi), data.frame(model_key = modelli), by = NULL)
  out <- dplyr::left_join(griglia, conteggi,
                          by = c("prompt_id", "repetition", "model_key"))
  out$n_records[is.na(out$n_records)] <- 0L
  out
}

campiona_revisione_generazioni <- function(df, per_categoria = 5L, seed = 42L) {
  # Selezione appaiata: tutte le risposte dei modelli per la medesima chiave.
  candidati <- dplyr::distinct(df[df$audit_status_ok, ],
                               domain, category, prompt_id, repetition)
  candidati <- dplyr::arrange(candidati, domain, category, prompt_id, repetition)
  set.seed(seed)
  selezione <- dplyr::group_by(candidati, domain, category)
  selezione <- dplyr::group_modify(selezione, function(.x, .y) {
    .x[sample.int(nrow(.x), min(per_categoria, nrow(.x))), , drop = FALSE]
  })
  out <- dplyr::semi_join(df, dplyr::ungroup(selezione),
                         by = c("domain", "category", "prompt_id", "repetition"))
  out <- dplyr::arrange(out, domain, category, prompt_id, repetition, model_key)
  out$manual_language <- out$manual_coherence <- out$manual_notes <- ""
  out
}

leggi_parquet_audit <- function(path) {
  tab <- arrow::read_parquet(path, as_data_frame = FALSE,
    col_select = -dplyr::any_of(c("input_token_ids", "generated_token_ids")))
  n <- tab$num_rows
  counts <- integer(n)
  metric_nul <- logical(n)
  columns <- rep("", n)
  report <- list()
  dati <- setNames(vector("list", length(names(tab))), names(tab))
  for (nome in names(tab)) {
    col <- tab[[nome]]
    if (col$type$ToString() %in% c("string", "large_string")) {
      # La conversione a binary preserva i NUL e non crea stringhe R illegali.
      bytes <- as.vector(col$cast(arrow::binary()))
      nuls <- vapply(bytes, function(x) sum(x == as.raw(0)), integer(1))
      affected <- which(nuls > 0L)
      if (length(affected)) {
        counts <- counts + nuls
        if (nome %in% c("prompt", "generation")) metric_nul[affected] <- TRUE
        columns[affected] <- ifelse(nzchar(columns[affected]),
          paste(columns[affected], nome, sep = ";"), nome)
        original_hex <- vapply(bytes[affected], function(x)
          paste0(format(x), collapse = ""), character(1))
        # Un NUL diventa un solo carattere visibile: non si uniscono parole
        # che erano separate dal byte zero; le posizioni Unicode restano stabili.
        for (j in affected) {
          x <- bytes[[j]]
          parts <- lapply(seq_along(x), function(k)
            if (x[k] == as.raw(0)) charToRaw("\uFFFD") else x[k])
          bytes[[j]] <- do.call(c, parts)
        }
        dati[[nome]] <- vapply(bytes, function(x) {
          if (is.null(x)) return(NA_character_)
          s <- rawToChar(x)
          Encoding(s) <- "UTF-8"
          s
        }, character(1))
        report[[length(report)+1L]] <- data.frame(
          source_file = normalizePath(path, winslash = "/"), row_in_source = affected,
          column = nome, n_nul = nuls[affected], original_utf8_hex = original_hex,
          text_for_audit = dati[[nome]][affected], stringsAsFactors = FALSE)
      } else dati[[nome]] <- as.vector(col)
    } else dati[[nome]] <- as.vector(col)
  }
  df <- as.data.frame(dati, stringsAsFactors = FALSE)
  df$audit_has_nul <- counts > 0L
  df$audit_n_nul <- counts
  df$audit_nul_in_metric_text <- metric_nul
  df$audit_nul_columns <- columns
  dettagli <- if (length(report)) dplyr::bind_rows(report) else data.frame(
    source_file=character(), row_in_source=integer(), column=character(), n_nul=integer(),
    original_utf8_hex=character(), text_for_audit=character())
  for (id in c("model_key", "prompt_id", "repetition"))
    dettagli[[id]] <- df[[id]][dettagli$row_in_source]
  list(data=df, nul_report=dettagli)
}

leggi_run_generazioni <- function(run_dir) {
  percorsi <- sort(list.files(run_dir, pattern = "^generations\\.parquet$",
                             recursive = TRUE, full.names = TRUE))
  if (!length(percorsi)) stop("Nessun generations.parquet in: ", run_dir)
  tabelle <- controlli <- metadati <- vector("list", length(percorsi))
  nul_reports <- vector("list", length(percorsi))
  for (i in seq_along(percorsi)) {
    path <- percorsi[i]
    message("Lettura: ", path)
    lettura <- leggi_parquet_audit(path)
    df <- lettura$data
    nul_reports[[i]] <- lettura$nul_report
    verifica_schema_generazioni(df)
    modello <- basename(dirname(path))
    if (any(df$model_key != modello)) stop("model_key diverso dalla cartella: ", path)
    meta_path <- file.path(dirname(path), "metadata.json")
    meta <- if (file.exists(meta_path)) jsonlite::fromJSON(meta_path) else list()
    valore <- function(x, default = NA) if (is.null(x)) default else x
    attesi <- valore(meta$records_expected, NA_real_)
    controlli[[i]] <- data.frame(
      model_key = modello, metadata_status = valore(meta$status, NA_character_),
      records_expected = attesi, records_observed = nrow(df),
      records_difference = nrow(df) - attesi,
      repetitions_expected = valore(meta$protocol$repetitions, NA_real_),
      repetitions_observed = dplyr::n_distinct(df$repetition),
      max_new_tokens = valore(meta$protocol$generation$max_new_tokens, NA_real_)
    )
    df$audit_source_file <- normalizePath(path, winslash = "/")
    # I token ID restano nel Parquet immutabile. L'audit usa solo colonne
    # scalari per contenere dimensioni dei derivati e rendere leggibili i CSV.
    tabelle[[i]] <- df[, !vapply(df, is.list, logical(1)), drop = FALSE]
    metadati[[i]] <- meta
  }
  names(metadati) <- basename(dirname(percorsi))
  list(data = dplyr::bind_rows(tabelle), completeness = dplyr::bind_rows(controlli),
       metadata = metadati, files = percorsi, nul_report = dplyr::bind_rows(nul_reports))
}
