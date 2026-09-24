# ============================================================
# R/data_quality.R
# Funzioni per il Data Quality Audit del dataset BOLD
#
# Questo file contiene solo definizioni di funzioni.
# Nessuna funzione modifica o rimuove i prompt originali.
# ============================================================


# ------------------------------------------------------------
# Specifiche e helper condivisi
# ------------------------------------------------------------

specifiche_flag_qualita <- function() {
  list(
    tecnici = c(
      "is_prompt_missing",
      "is_prompt_vuoto",
      "ha_markup",
      "ha_tab",
      "ha_newline",
      "ha_carriage_return",
      "ha_caratteri_controllo",
      "ha_unicode_invisibile"
    ),
    revisione_manuale = c(
      "ha_doppio_spazio",
      "spazio_prima_punteggiatura",
      "ha_spazio_iniziale",
      "parentesi_round_sbilanciate",
      "parentesi_quadre_sbilanciate",
      "virgolette_sbilanciate"
    ),
    informativi = c(
      "ha_non_ascii",
      "ha_spazio_finale"
    )
  )
}


rileva_pattern <- function(x, pattern) {
  stringr::str_detect(x, pattern) |>
    dplyr::coalesce(FALSE)
}


delimitatori_sbilanciati <- function(x, apertura, chiusura) {
  risultato <-
    stringr::str_count(x, stringr::fixed(apertura)) !=
    stringr::str_count(x, stringr::fixed(chiusura))

  dplyr::coalesce(risultato, FALSE)
}


appartiene_a_duplicato <- function(x, escludi_vuoti = FALSE) {
  valido <- !is.na(x)

  if (escludi_vuoti) {
    valido <- valido & x != ""
  }

  valido & (
    duplicated(x) |
      duplicated(x, fromLast = TRUE)
  )
}


verifica_schema_bold <- function(df) {
  colonne_richieste <- c("dominio", "categoria", "entita", "prompt")
  colonne_mancanti <- setdiff(colonne_richieste, names(df))

  if (length(colonne_mancanti) > 0) {
    stop(
      "Colonne mancanti nel dataset: ",
      paste(colonne_mancanti, collapse = ", ")
    )
  }

  invisible(TRUE)
}


aggiungi_flag_qualita <- function(df) {

  specifiche <- specifiche_flag_qualita()

  # Duplicazione dell'intera osservazione:
  # dominio + categoria + entità + prompt.
  chiave_riga <- df |>
    dplyr::select(dominio, categoria, entita, prompt)

  is_riga_duplicata <-
    duplicated(chiave_riga) |
    duplicated(chiave_riga, fromLast = TRUE)

  df |>
    dplyr::mutate(

      # Versione normalizzata usata SOLO nell'audit.
      # Il prompt originale non viene modificato.
      prompt_normalizzato_audit = dplyr::if_else(
        is.na(prompt),
        NA_character_,
        stringr::str_squish(stringr::str_to_lower(prompt))
      ),

      # Completezza
      is_prompt_missing = is.na(prompt),
      is_prompt_vuoto =
        dplyr::coalesce(stringr::str_trim(prompt) == "", FALSE),

      # Markup / encoding / caratteri di controllo
      ha_markup = rileva_pattern(
        prompt,
        "\\[\\[|\\]\\]|\\{\\{|<ref|&amp;|<.*?>"
      ),

      ha_tab = rileva_pattern(prompt, "\t"),

      ha_newline = rileva_pattern(prompt, "\n"),

      ha_carriage_return = rileva_pattern(prompt, "\r"),

      ha_unicode_invisibile = rileva_pattern(
        prompt,
        "[\\x{200B}\\x{FEFF}\\x{00A0}]"
      ),

      # Whitespace / punteggiatura:
      # sono segnali da ispezionare, non errori certi.
      ha_doppio_spazio = rileva_pattern(prompt, "  "),

      spazio_prima_punteggiatura = rileva_pattern(
        prompt,
        " [.,;:!?]"
      ),

      ha_spazio_iniziale = rileva_pattern(prompt, "^ "),

      # Lo spazio finale è quasi universale in BOLD ed è informativo.
      ha_spazio_finale = rileva_pattern(prompt, " $"),

      # Non-ASCII non implica encoding corrotto.
      ha_non_ascii = rileva_pattern(prompt, "[^\\x00-\\x7F]"),

      # Strutture aperte possono essere legittime in un prompt incompleto:
      # vengono quindi solo segnalate per revisione manuale.
      parentesi_round_sbilanciate = delimitatori_sbilanciati(
        prompt,
        "(",
        ")"
      ),

      parentesi_quadre_sbilanciate = delimitatori_sbilanciati(
        prompt,
        "[",
        "]"
      ),

      virgolette_sbilanciate =
        dplyr::coalesce(
          stringr::str_count(prompt, '"') %% 2 != 0,
          FALSE
        )
    ) |>
    dplyr::mutate(
      ha_caratteri_controllo =
        ha_tab | ha_newline | ha_carriage_return,

      # Duplicati: fotografia preliminare.
      # L'analisi approfondita avverrà nello step dedicato.
      is_duplicato_esatto = appartiene_a_duplicato(prompt),

      is_duplicato_normalizzato = appartiene_a_duplicato(
        prompt_normalizzato_audit,
        escludi_vuoti = TRUE
      ),

      is_riga_duplicata = is_riga_duplicata,

      # Probabili errori tecnici: candidati al cleaning
      # dopo l'ispezione dei casi.
      flag_errore_tecnico = dplyr::if_any(
        dplyr::all_of(specifiche$tecnici),
        ~ .x
      ),

      # Segnali ambigui: non vanno corretti automaticamente.
      flag_revisione_manuale = dplyr::if_any(
        dplyr::all_of(specifiche$revisione_manuale),
        ~ .x
      )
    )
}


riepilogo_dataset <- function(df_raw, df_audit) {

  prompt_norm_validi <- df_audit$prompt_normalizzato_audit[
    !is.na(df_audit$prompt_normalizzato_audit) &
      df_audit$prompt_normalizzato_audit != ""
  ]

  n_categorie <- df_raw |>
    dplyr::filter(!is.na(dominio), !is.na(categoria)) |>
    dplyr::distinct(dominio, categoria) |>
    nrow()

  tibble::tibble(
    n_righe = nrow(df_raw),
    n_colonne_originali = ncol(df_raw),
    n_colonne_dopo_audit = ncol(df_audit),
    n_domini = dplyr::n_distinct(df_raw$dominio, na.rm = TRUE),
    n_categorie = n_categorie,
    n_entita = dplyr::n_distinct(df_raw$entita, na.rm = TRUE),
    n_prompt_unici_esatti = dplyr::n_distinct(df_raw$prompt, na.rm = TRUE),
    n_prompt_unici_normalizzati = length(unique(prompt_norm_validi))
  )
}


riepilogo_missing <- function(df) {

  risultati <- lapply(names(df), function(nome_colonna) {
    x <- df[[nome_colonna]]
    n_missing <- sum(is.na(x))

    n_vuoti <- if (is.character(x)) {
      sum(!is.na(x) & stringr::str_trim(x) == "")
    } else {
      NA_integer_
    }

    tibble::tibble(
      colonna = nome_colonna,
      n_missing = n_missing,
      pct_missing = round(100 * n_missing / nrow(df), 3),
      n_stringhe_vuote = n_vuoti
    )
  })

  dplyr::bind_rows(risultati)
}


riepilogo_domini_categorie <- function(df) {
  df |>
    dplyr::count(dominio, categoria, name = "n_prompt") |>
    dplyr::arrange(dominio, dplyr::desc(n_prompt))
}


controlla_domini <- function(df, domini_attesi) {

  presenti <- unique(stats::na.omit(df$dominio))

  tibble::tibble(
    dominio = union(domini_attesi, presenti)
  ) |>
    dplyr::mutate(
      atteso = dominio %in% domini_attesi,
      presente = dominio %in% presenti,
      stato = dplyr::case_when(
        atteso & presente ~ "OK",
        atteso & !presente ~ "MANCANTE",
        !atteso & presente ~ "INATTESO"
      )
    )
}


trova_varianti_categoria <- function(df) {
  df |>
    dplyr::filter(
      !is.na(categoria),
      stringr::str_trim(categoria) != ""
    ) |>
    dplyr::mutate(
      categoria_normalizzata =
        stringr::str_squish(stringr::str_to_lower(categoria))
    ) |>
    dplyr::group_by(dominio, categoria_normalizzata) |>
    dplyr::summarise(
      n_varianti = dplyr::n_distinct(categoria),
      varianti = paste(sort(unique(categoria)), collapse = " | "),
      .groups = "drop"
    ) |>
    dplyr::filter(n_varianti > 1)
}


riepilogo_flag_testo <- function(df) {

  gruppi <- specifiche_flag_qualita()

  specifiche_flag <- dplyr::bind_rows(
    tibble::tibble(
      controllo = gruppi$tecnici,
      classe = "errore_tecnico"
    ),
    tibble::tibble(
      controllo = gruppi$revisione_manuale,
      classe = "revisione_manuale"
    ),
    tibble::tibble(
      controllo = gruppi$informativi,
      classe = "informativo"
    ),
    tibble::tibble(
      controllo = c(
        "flag_errore_tecnico",
        "flag_revisione_manuale"
      ),
      classe = "sintesi"
    )
  )

  risultati <- df |>
    dplyr::summarise(
      dplyr::across(
        dplyr::all_of(specifiche_flag$controllo),
        ~ sum(.x, na.rm = TRUE)
      )
    ) |>
    tidyr::pivot_longer(
      dplyr::everything(),
      names_to = "controllo",
      values_to = "n_prompt"
    ) |>
    dplyr::mutate(
      percentuale = round(100 * n_prompt / nrow(df), 3)
    )

  specifiche_flag |>
    dplyr::left_join(risultati, by = "controllo")
}


riepilogo_duplicati <- function(df) {

  n_gruppi_esatti <- df |>
    dplyr::filter(is_duplicato_esatto) |>
    dplyr::distinct(prompt) |>
    nrow()

  n_gruppi_normalizzati <- df |>
    dplyr::filter(is_duplicato_normalizzato) |>
    dplyr::distinct(prompt_normalizzato_audit) |>
    nrow()

  tibble::tibble(
    tipo = c(
      "righe_completamente_duplicate",
      "righe_in_prompt_duplicati_esatti",
      "gruppi_prompt_duplicati_esatti",
      "righe_in_prompt_duplicati_normalizzati",
      "gruppi_prompt_duplicati_normalizzati"
    ),
    valore = c(
      sum(df$is_riga_duplicata, na.rm = TRUE),
      sum(df$is_duplicato_esatto, na.rm = TRUE),
      n_gruppi_esatti,
      sum(df$is_duplicato_normalizzato, na.rm = TRUE),
      n_gruppi_normalizzati
    )
  )
}


estrai_casi_flaggati <- function(df, flag_sintesi, flag_dettaglio) {
  colonne_base <- c(
    "dominio",
    "categoria",
    "entita",
    "prompt"
  )

  df |>
    dplyr::filter(.data[[flag_sintesi]]) |>
    dplyr::select(
      dplyr::all_of(c(colonne_base, flag_dettaglio))
    )
}


estrai_errori_tecnici <- function(df) {
  specifiche <- specifiche_flag_qualita()

  estrai_casi_flaggati(
    df,
    flag_sintesi = "flag_errore_tecnico",
    flag_dettaglio = setdiff(
      specifiche$tecnici,
      "ha_caratteri_controllo"
    )
  )
}


estrai_revisione_manuale <- function(df) {
  specifiche <- specifiche_flag_qualita()

  estrai_casi_flaggati(
    df,
    flag_sintesi = "flag_revisione_manuale",
    flag_dettaglio = specifiche$revisione_manuale
  )
}
