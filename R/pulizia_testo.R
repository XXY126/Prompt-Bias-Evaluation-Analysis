# ============================================================
# R/pulizia_testo.R
# Funzioni per l'ispezione e la pulizia del campo testuale "prompt"
#
# Contiene solo definizioni di funzioni, richiamate da
# scripts/02_pulizia_prompt.R
# ============================================================

#' Aggiunge colonne di lunghezza (caratteri e parole) al dataframe
aggiungi_lunghezza <- function(df) {
  df %>%
    dplyr::mutate(
      n_char   = stringr::str_length(prompt),
      n_parole = stringr::str_count(prompt, "\\S+")
    )
}

#' Flagga i duplicati esatti, quasi-esatti e cross-categoria
#'
#' Non rimuove nulla: aggiunge solo colonne di flag, la decisione
#' di rimozione va presa consapevolmente a valle (vedi report).
flagga_duplicati <- function(df) {

  df <- df %>%
    dplyr::mutate(
      prompt_normalizzato = stringr::str_squish(stringr::str_to_lower(prompt)),
      is_duplicato_esatto  = duplicated(prompt) | duplicated(prompt, fromLast = TRUE),
      is_duplicato_quasi   = duplicated(prompt_normalizzato) | duplicated(prompt_normalizzato, fromLast = TRUE)
    )

  # Duplicati che attraversano categorie diverse (più gravi: possibile
  # contaminazione tra i gruppi che verranno confrontati statisticamente)
  cross_categoria <- df %>%
    dplyr::group_by(prompt) %>%
    dplyr::filter(dplyr::n() > 1) %>%
    dplyr::summarise(n_categorie_diverse = dplyr::n_distinct(paste(dominio, categoria)), .groups = "drop") %>%
    dplyr::filter(n_categorie_diverse > 1) %>%
    dplyr::pull(prompt)

  df <- df %>%
    dplyr::mutate(is_duplicato_cross_categoria = prompt %in% cross_categoria)

  df
}

#' Flagga outlier di lunghezza con metodo IQR (più robusto di un percentile fisso)
flagga_outlier_lunghezza <- function(df) {

  q1  <- quantile(df$n_parole, 0.25, na.rm = TRUE)
  q3  <- quantile(df$n_parole, 0.75, na.rm = TRUE)
  iqr <- q3 - q1

  limite_basso <- q1 - 1.5 * iqr
  limite_alto  <- q3 + 1.5 * iqr

  df %>%
    dplyr::mutate(
      outlier_lunghezza = n_parole < limite_basso | n_parole > limite_alto
    )
}

#' Flagga possibili troncamenti a metà parola
#'
#' NOTA IMPORTANTE: BOLD contiene per design frasi incomplete (sono
#' prompt pensati per essere completati da un modello generativo).
#' Non è quindi anomalo che un prompt finisca senza punteggiatura:
#' il segnale di vero errore è un troncamento a META' parola, non
#' la semplice assenza di punto finale.
flagga_troncamento <- function(df) {

  parole_funzionali <- c(
    "the", "a", "an", "of", "in", "to", "on", "at", "for", "with",
    "by", "as", "and", "or", "is", "was", "were", "are", "that",
    "which", "who", "his", "her", "its", "their"
  )

  # IMPORTANTE: i prompt di BOLD terminano tipicamente con uno spazio
  # finale (voluto: sono prefissi pensati per essere concatenati
  # direttamente a una continuazione generata da un modello). Senza
  # str_trim(), str_sub(prompt, -1, -1) leggerebbe sempre uno spazio
  # come "ultimo carattere", facendo risultare TUTTI i prompt come
  # troncati — falso positivo sistematico, non un problema reale dei dati.
  df %>%
    dplyr::mutate(
      prompt_trim = stringr::str_trim(prompt),
      ultimo_char = stringr::str_sub(prompt_trim, -1, -1),
      finisce_con_punteggiatura = stringr::str_detect(ultimo_char, "[.!?,:;]"),
      ultima_parola = stringr::word(prompt_trim, -1),
      ultima_parola_sospetta = stringr::str_length(ultima_parola) <= 2 &
        !(tolower(ultima_parola) %in% parole_funzionali)
    ) %>%
    dplyr::select(-prompt_trim)
}

#' Flagga caratteri speciali, markup residuo, encoding anomalo
flagga_caratteri_speciali <- function(df) {
  df %>%
    dplyr::mutate(
      ha_markup                     = stringr::str_detect(prompt, "\\[\\[|\\]\\]|\\{\\{|<ref|&amp;|<.*?>"),
      ha_caratteri_controllo        = stringr::str_detect(prompt, "[\\t\\n\\r]"),
      ha_doppio_spazio               = stringr::str_detect(prompt, "  "),
      spazio_prima_punteggiatura     = stringr::str_detect(prompt, " [.,;:!?]"),
      ha_non_ascii                   = stringr::str_detect(prompt, "[^\\x00-\\x7F]"),
      ha_unicode_invisibile          = stringr::str_detect(prompt, "[\\x{200B}\\x{FEFF}\\x{00A0}]"),
      parentesi_round_sbilanciate    = stringr::str_count(prompt, stringr::fixed("(")) != stringr::str_count(prompt, stringr::fixed(")")),
      parentesi_quadre_sbilanciate   = stringr::str_count(prompt, stringr::fixed("[")) != stringr::str_count(prompt, stringr::fixed("]")),
      virgolette_sbilanciate         = stringr::str_count(prompt, '"') %% 2 != 0
    )
}

#' Applica la pulizia automatica SICURA (solo correzioni non ambigue)
#'
#' Corregge solo artefatti tecnici inequivocabili (markup, spazi,
#' caratteri di controllo, unicode invisibili). Non tocca duplicati,
#' outlier o troncamenti: quelli restano flag da decidere a valle.
applica_pulizia_sicura <- function(df) {
  df %>%
    dplyr::mutate(
      # Versione per la GENERAZIONE con i modelli offline (step successivi
      # della pipeline): corregge solo artefatti di markup/encoding, ma
      # PRESERVA lo spazio finale originale del prompt, perché è voluto
      # (i modelli generativi si aspettano di concatenare la continuazione
      # subito dopo, esattamente come nel paper originale di BOLD).
      prompt_per_generazione = prompt %>%
        stringr::str_replace_all("&amp;", "&") %>%
        stringr::str_replace_all("\\[\\[|\\]\\]", "") %>%
        stringr::str_replace_all("\\{\\{.*?\\}\\}", "") %>%
        stringr::str_replace_all("[\\t\\n\\r]", " ") %>%
        stringr::str_replace_all("[\\x{200B}\\x{FEFF}]", ""),

      # Versione NORMALIZZATA per le statistiche testuali (lunghezza, TTR,
      # confronti lessicali): qui lo spazio finale non ha significato e
      # va rimosso per non sporcare i conteggi.
      prompt_pulito = stringr::str_squish(prompt_per_generazione)
    )
}

#' Pipeline completa di ispezione + pulizia, in un'unica chiamata
#'
#' @param df Dataframe BOLD grezzo (colonna "prompt" richiesta)
#' @return Dataframe con tutte le colonne di flag + prompt_pulito
pulisci_prompt_completo <- function(df) {
  df %>%
    aggiungi_lunghezza() %>%
    flagga_duplicati() %>%
    flagga_outlier_lunghezza() %>%
    flagga_troncamento() %>%
    flagga_caratteri_speciali() %>%
    applica_pulizia_sicura() %>%
    dplyr::mutate(
      flag_qualita_strutturale = ha_caratteri_controllo | ha_doppio_spazio |
        spazio_prima_punteggiatura | ha_unicode_invisibile |
        parentesi_round_sbilanciate | parentesi_quadre_sbilanciate |
        virgolette_sbilanciate | ha_markup
    )
}

#' Stampa un riepilogo sintetico di tutti i flag di qualità
riepilogo_qualita_testo <- function(df) {
  n <- nrow(df)

  cat("\n========== RIEPILOGO QUALITÀ TESTO (prompt) ==========\n")
  cat("Prompt totali:", n, "\n")
  cat("Duplicati esatti:", sum(df$is_duplicato_esatto), "\n")
  cat("Duplicati cross-categoria (più gravi):", sum(df$is_duplicato_cross_categoria), "\n")
  cat("Outlier di lunghezza (IQR):", sum(df$outlier_lunghezza), "\n")
  cat("Troncamenti sospetti:", sum(df$ultima_parola_sospetta), "\n")
  cat("Markup residuo:", sum(df$ha_markup), "\n")
  cat("Caratteri non-ASCII:", sum(df$ha_non_ascii),
      "(", round(100 * sum(df$ha_non_ascii) / n, 2), "%)\n")

  # Modifiche SOSTANZIALI: solo markup/encoding, esclude la normale
  # rimozione dello spazio finale (che è normalizzazione, non correzione
  # di un errore) — confronta prompt originale vs prompt_per_generazione,
  # non vs prompt_pulito (che è sempre "squished" per costruzione)
  n_modifiche_sostanziali <- sum(df$prompt != df$prompt_per_generazione)
  cat("Prompt con modifiche SOSTANZIALI (markup/encoding, spazi finali esclusi):",
      n_modifiche_sostanziali,
      "(", round(100 * n_modifiche_sostanziali / n, 2), "%)\n")
  cat("========================================================\n")

  invisible(NULL)
}
