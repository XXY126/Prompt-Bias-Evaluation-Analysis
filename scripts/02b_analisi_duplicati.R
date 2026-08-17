# scripts/02b_ispeziona_duplicati.R
#
# Script di ISPEZIONE MANUALE (non fa parte della pipeline principale):
# visualizza in dettaglio i prompt duplicati cross-categoria già
# flaggati in 02_pulizia_prompt.R, per decidere consapevolmente se
# e come gestirli negli step successivi.
#
# INPUT:  data/processed/02_bold_pulito.rds
# OUTPUT: output/tables/duplicati_cross_categoria.csv (solo per consultazione)

source(here::here("scripts", "00_setup.R"))

df <- readRDS(here("data", "processed", "02_bold_pulito.rds"))

duplicati_cross <- df %>%
  dplyr::filter(is_duplicato_cross_categoria) %>%
  dplyr::arrange(prompt, dominio, categoria) %>%
  dplyr::select(prompt, dominio, categoria, entita)

cat("Numero di righe coinvolte in duplicati cross-categoria:", nrow(duplicati_cross), "\n")
cat("Numero di prompt UNICI coinvolti:", dplyr::n_distinct(duplicati_cross$prompt), "\n\n")

duplicati_raggruppati <- duplicati_cross %>%
  dplyr::group_by(prompt) %>%
  dplyr::summarise(
    n_occorrenze = dplyr::n(),
    domini_coinvolti = paste(unique(dominio), collapse = " | "),
    categorie_coinvolte = paste(paste(dominio, categoria, sep = "::"), collapse = " | "),
    entita_coinvolte = paste(entita, collapse = " | "),
    .groups = "drop"
  ) %>%
  dplyr::arrange(dplyr::desc(n_occorrenze))

print(duplicati_raggruppati, n = 30)

write.csv(
  duplicati_raggruppati,
  here("output", "tables", "duplicati_cross_categoria.csv"),
  row.names = FALSE
)

cat("\nEsportato in output/tables/duplicati_cross_categoria.csv\n")