# ============================================================
# 00_setup.R
# Setup centralizzato del progetto: mirror CRAN + librerie comuni
#
# Ogni altro script richiama questo file in testa con:
#   source(here::here("scripts", "00_setup.R"))
#
# NOTA: per funzionare, questo file richiede che esista un
# progetto RStudio (.Rproj) nella cartella radice, altrimenti
# here::here() non sa individuare la radice del progetto.
# ============================================================

# Mirror CRAN fisso, evita il prompt interattivo di scelta mirror
options(repos = c(CRAN = "https://cloud.r-project.org"))

# Librerie richieste da TUTTI gli script del progetto
# (librerie specifiche di un singolo step, es. VADER o toxic-bert
# in Python via reticulate, vanno dichiarate nel singolo script)
librerie_necessarie <- c(
  "here",       # gestione path assoluti relativi alla radice del progetto
  "dplyr",      # manipolazione dataframe
  "stringr",    # manipolazione stringhe
  "ggplot2",    # visualizzazione
  "purrr",      # programmazione funzionale (map, imap)
  "tidyr",      # reshaping dataframe
  "jsonlite"    # lettura file JSON
)

nuove <- librerie_necessarie[!(librerie_necessarie %in% installed.packages()[, "Package"])]
if (length(nuove) > 0) {
  message("Installazione pacchetti mancanti: ", paste(nuove, collapse = ", "))
  install.packages(nuove)
}

invisible(lapply(librerie_necessarie, library, character.only = TRUE))

# ------------------------------------------------------------
# Creazione automatica delle cartelle di progetto, se mancanti.
# Necessario perché zip/git non conservano cartelle vuote: dopo
# un'estrazione o un clone, le cartelle di output potrebbero non
# esistere fisicamente e causare errori di scrittura più avanti.
# ------------------------------------------------------------
cartelle_progetto <- c(
  here::here("data", "raw", "prompts"),
  here::here("data", "processed"),
  here::here("output", "figures"),
  here::here("output", "tables")
)

invisible(lapply(cartelle_progetto, function(d) {
  if (!dir.exists(d)) {
    dir.create(d, recursive = TRUE)
    message("Creata cartella mancante: ", d)
  }
}))

message("Setup completato. Radice del progetto: ", here::here())
