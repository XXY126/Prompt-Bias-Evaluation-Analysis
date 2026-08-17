# ============================================================
# R/caricamento.R
# Funzioni per il caricamento e l'appiattimento del dataset BOLD
#
# Questo file contiene SOLO definizioni di funzioni.
# Non esegue nulla direttamente: viene richiamato con source()
# dagli script in scripts/ (es. scripts/01_caricamento_dati.R)
# ============================================================

#' Appiattisce un singolo file JSON di BOLD in un dataframe
#'
#' Il formato originale di BOLD è annidato a due livelli:
#'   {categoria: {nome_entita: [lista_di_prompt]}}
#'
#' @param filepath Percorso completo al file JSON del dominio
#' @param dominio Nome del dominio (es. "gender", "profession"),
#'   usato solo per etichettare le righe risultanti
#' @return Un dataframe con colonne: dominio, categoria, entita, prompt
flatten_bold_json <- function(filepath, dominio) {

  if (!file.exists(filepath)) {
    stop(
      "File non trovato: ", filepath,
      " — verifica il path con list.files() sulla cartella attesa."
    )
  }

  raw <- jsonlite::fromJSON(filepath, simplifyVector = FALSE)

  righe <- list()
  for (categoria in names(raw)) {
    entita_list <- raw[[categoria]]
    for (entita in names(entita_list)) {
      prompts <- entita_list[[entita]]
      for (p in prompts) {
        righe[[length(righe) + 1]] <- data.frame(
          dominio = dominio,
          categoria = categoria,
          entita = entita,
          prompt = p,
          stringsAsFactors = FALSE
        )
      }
    }
  }

  dplyr::bind_rows(righe)
}

#' Carica tutti i domini di BOLD e li unisce in un unico dataframe
#'
#' @param path_dir Cartella contenente i file JSON originali di BOLD
#' @param file_domini Lista nominata: nome_dominio -> nome_file_json
#'   Esempio:
#'   list(gender = "gender_prompt.json", race = "race_prompt.json", ...)
#' @return Un unico dataframe con tutti i domini concatenati
carica_bold_completo <- function(path_dir, file_domini) {

  df_list <- purrr::imap(file_domini, function(fname, dominio) {
    filepath <- file.path(path_dir, fname)
    flatten_bold_json(filepath, dominio)
  })

  dplyr::bind_rows(df_list)
}

#' Stampa un riepilogo strutturale rapido del dataset caricato
#'
#' @param df Dataframe BOLD (output di carica_bold_completo)
riepilogo_struttura_bold <- function(df) {
  cat("Numero totale di prompt:", nrow(df), "\n")
  cat("Domini presenti:", paste(unique(df$dominio), collapse = ", "), "\n")
  cat("Numero categorie per dominio:\n")

  df %>%
    dplyr::group_by(dominio) %>%
    dplyr::summarise(n_categorie = dplyr::n_distinct(categoria), .groups = "drop") %>%
    print()

  invisible(NULL)
}
