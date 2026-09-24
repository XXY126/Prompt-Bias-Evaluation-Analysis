# ============================================================
# scripts/03_technical_issues_analysis.R
#
# Analisi diagnostica dei problemi tecnici individuati nel
# dataset BOLD, con un approfondimento sui caratteri newline.
#
# Lo script NON modifica, NON elimina e NON sovrascrive prompt.
# La versione normalizzata inclusa nei risultati e' soltanto
# una candidata da confrontare con il testo originale.
#
# INPUT:
#   data/processed/01_bold_raw.rds
#
# OUTPUT:
#   output/audit/technical_analysis/*.csv
# ============================================================

source(here::here("R", "setup.R"))
source(here::here("R", "data_quality.R"))


# ------------------------------------------------------------
# Percorsi e caricamento
# ------------------------------------------------------------

input_path <- here::here(
  "data",
  "processed",
  "01_bold_raw.rds"
)

output_dir <- here::here(
  "output",
  "audit",
  "technical_analysis"
)

dir.create(output_dir, recursive = TRUE, showWarnings = FALSE)

df_raw <- readRDS(input_path)
verifica_schema_bold(df_raw)

# L'ID conserva il collegamento con la posizione nel dataset originale.
df_audit <- df_raw |>
  dplyr::mutate(id_riga_originale = dplyr::row_number()) |>
  aggiungi_flag_qualita()

if (!identical(df_raw$prompt, df_audit$prompt)) {
  stop("ERRORE: l'analisi tecnica ha modificato i prompt originali.")
}


# ------------------------------------------------------------
# Funzioni diagnostiche locali
# ------------------------------------------------------------

rendi_caratteri_visibili <- function(x) {
  x |>
    stringr::str_replace_all(stringr::fixed("\r"), "\\\\r") |>
    stringr::str_replace_all(stringr::fixed("\n"), "\\\\n") |>
    stringr::str_replace_all(stringr::fixed("\t"), "\\\\t")
}

posizioni_carattere <- function(x, carattere) {
  purrr::map_chr(x, function(testo) {
    if (is.na(testo)) {
      return(NA_character_)
    }

    posizioni <- stringr::str_locate_all(
      testo,
      stringr::fixed(carattere)
    )[[1]][, "start"]

    if (length(posizioni) == 0) "" else paste(posizioni, collapse = " | ")
  })
}

classifica_newline <- function(prompt, n_newline) {
  dplyr::case_when(
    n_newline == 0 ~ "nessun_newline",
    stringr::str_detect(prompt, "^\\n+$") ~ "solo_newline",
    stringr::str_detect(prompt, "^\\n+") &
      stringr::str_detect(prompt, "\\n+$") ~ "iniziale_e_finale",
    stringr::str_detect(prompt, "^\\n+") ~ "iniziale",
    stringr::str_detect(prompt, "\\n+$") ~ "finale",
    stringr::str_detect(prompt, "\\n{2,}") ~ "interno_consecutivo",
    n_newline == 1 ~ "interno_singolo",
    n_newline > 1 ~ "interno_multiplo",
    TRUE ~ "altro"
  )
}

normalizza_solo_whitespace <- function(x) {
  # Candidata diagnostica: non viene usata per sovrascrivere il prompt.
  x |>
    stringr::str_replace_all("\\r\\n|\\r|\\n|\\t", " ") |>
    stringr::str_squish()
}


# ------------------------------------------------------------
# 1. Quadro complessivo dei problemi tecnici
# ------------------------------------------------------------

technical_summary <- tibble::tibble(
  problema = c(
    "prompt_missing",
    "prompt_vuoto",
    "markup",
    "tab",
    "newline",
    "carriage_return",
    "unicode_invisibile",
    "almeno_un_errore_tecnico"
  ),
  n_prompt = c(
    sum(df_audit$is_prompt_missing, na.rm = TRUE),
    sum(df_audit$is_prompt_vuoto, na.rm = TRUE),
    sum(df_audit$ha_markup, na.rm = TRUE),
    sum(df_audit$ha_tab, na.rm = TRUE),
    sum(df_audit$ha_newline, na.rm = TRUE),
    sum(df_audit$ha_carriage_return, na.rm = TRUE),
    sum(df_audit$ha_unicode_invisibile, na.rm = TRUE),
    sum(df_audit$flag_errore_tecnico, na.rm = TRUE)
  )
) |>
  dplyr::mutate(
    percentuale = round(100 * n_prompt / nrow(df_audit), 3)
  )

readr::write_csv(
  technical_summary,
  file.path(output_dir, "technical_issues_summary.csv")
)


# ------------------------------------------------------------
# 2. Dettaglio dei prompt con newline
# ------------------------------------------------------------

newline_details <- df_audit |>
  dplyr::filter(ha_newline) |>
  dplyr::mutate(
    n_newline = stringr::str_count(prompt, stringr::fixed("\n")),
    posizioni_newline = posizioni_carattere(prompt, "\n"),
    newline_iniziale = stringr::str_detect(prompt, "^\n"),
    newline_finale = stringr::str_detect(prompt, "\n$"),
    newline_consecutivi = stringr::str_detect(prompt, "\n{2,}"),
    spazio_prima_newline = stringr::str_detect(prompt, " \n"),
    spazio_dopo_newline = stringr::str_detect(prompt, "\n "),
    tipo_newline = classifica_newline(prompt, n_newline),
    lunghezza_originale = stringr::str_length(prompt),
    prompt_visibile = rendi_caratteri_visibili(prompt),
    prompt_candidato_whitespace = normalizza_solo_whitespace(prompt),
    lunghezza_candidata = stringr::str_length(prompt_candidato_whitespace),
    candidata_diversa = prompt != prompt_candidato_whitespace
  ) |>
  dplyr::select(
    id_riga_originale,
    dominio,
    categoria,
    entita,
    tipo_newline,
    n_newline,
    posizioni_newline,
    newline_iniziale,
    newline_finale,
    newline_consecutivi,
    spazio_prima_newline,
    spazio_dopo_newline,
    ha_tab,
    ha_carriage_return,
    ha_markup,
    is_duplicato_esatto,
    is_duplicato_normalizzato,
    lunghezza_originale,
    lunghezza_candidata,
    candidata_diversa,
    prompt,
    prompt_visibile,
    prompt_candidato_whitespace
  ) |>
  dplyr::arrange(dominio, categoria, id_riga_originale)

readr::write_csv(
  newline_details,
  file.path(output_dir, "newline_details.csv")
)


# ------------------------------------------------------------
# 2b. Un file di ispezione per ogni tipo di newline
# ------------------------------------------------------------

newline_types_dir <- file.path(output_dir, "newline_by_type")
dir.create(newline_types_dir, recursive = TRUE, showWarnings = FALSE)

tipi_newline <- sort(unique(newline_details$tipo_newline))

purrr::walk(tipi_newline, function(tipo_corrente) {
  tabella_tipo <- newline_details |>
    dplyr::filter(tipo_newline == tipo_corrente) |>
    dplyr::arrange(dominio, categoria, id_riga_originale) |>
    dplyr::select(
      id_riga_originale,
      dominio,
      categoria,
      entita,
      tipo_newline,
      n_newline,
      posizioni_newline,
      prompt,
      prompt_visibile,
      prompt_candidato_whitespace
    )

  readr::write_csv(
    tabella_tipo,
    file.path(
      newline_types_dir,
      paste0("newline_", tipo_corrente, ".csv")
    )
  )
})


# ------------------------------------------------------------
# 3. Riepiloghi dei newline
# ------------------------------------------------------------

newline_summary <- newline_details |>
  dplyr::count(tipo_newline, name = "n_prompt") |>
  dplyr::mutate(
    percentuale_sui_prompt_con_newline = round(
      100 * n_prompt / nrow(newline_details),
      3
    )
  ) |>
  dplyr::arrange(dplyr::desc(n_prompt), tipo_newline) |>
  tibble::as_tibble()

newline_by_domain <- newline_details |>
  dplyr::count(dominio, tipo_newline, name = "n_prompt") |>
  dplyr::group_by(dominio) |>
  dplyr::mutate(
    percentuale_nel_dominio = round(100 * n_prompt / sum(n_prompt), 3)
  ) |>
  dplyr::ungroup() |>
  dplyr::arrange(dominio, dplyr::desc(n_prompt), tipo_newline)

newline_by_category <- newline_details |>
  dplyr::count(dominio, categoria, tipo_newline, name = "n_prompt") |>
  dplyr::arrange(dominio, dplyr::desc(n_prompt), categoria, tipo_newline)

readr::write_csv(
  newline_summary,
  file.path(output_dir, "newline_summary.csv")
)

readr::write_csv(
  newline_by_domain,
  file.path(output_dir, "newline_by_domain.csv")
)

readr::write_csv(
  newline_by_category,
  file.path(output_dir, "newline_by_category.csv")
)


# ------------------------------------------------------------
# 4. Controlli di integrita'
# ------------------------------------------------------------

if (nrow(newline_details) != sum(df_audit$ha_newline, na.rm = TRUE)) {
  stop("ERRORE: il numero di prompt nel dettaglio newline non coincide.")
}

if (!identical(df_raw$prompt, df_audit$prompt)) {
  stop("ERRORE: i prompt originali sono cambiati durante l'analisi.")
}


# ------------------------------------------------------------
# Output in console
# ------------------------------------------------------------

cat("\n========== ANALISI PROBLEMI TECNICI ==========\n")
print(technical_summary, n = Inf)

cat("\n========== APPROFONDIMENTO NEWLINE ==========\n")
print(newline_summary, n = Inf)

cat(
  "\nPrompt con newline:", nrow(newline_details),
  "su", nrow(df_raw),
  paste0("(", round(100 * nrow(newline_details) / nrow(df_raw), 3), "%)"),
  "\n"
)

cat(
  "L'analisi non ha modificato o eliminato alcun prompt.\n",
  "La colonna prompt_candidato_whitespace e' solo diagnostica.\n",
  "Risultati salvati in: ", output_dir, "\n",
  "File separati per tipo salvati in: ", newline_types_dir, "\n",
  sep = ""
)
