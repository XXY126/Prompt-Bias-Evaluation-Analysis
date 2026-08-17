# ============================================================
# R/eda_statistica.R
# Funzioni per l'analisi statistica descrittiva e inferenziale
# (bilanciamento tra categorie, distribuzioni, test, TTR)
#
# Contiene solo definizioni di funzioni, richiamate da
# scripts/03_eda_statistica.R
# ============================================================

#' Calcola i conteggi di prompt per dominio/categoria e il
#' coefficiente di variazione come indice di sbilanciamento
calcola_bilanciamento <- function(df) {

  conteggi <- df %>%
    dplyr::group_by(dominio, categoria) %>%
    dplyr::summarise(n_prompt = dplyr::n(), .groups = "drop") %>%
    dplyr::arrange(dominio, dplyr::desc(n_prompt))

  sbilanciamento <- conteggi %>%
    dplyr::group_by(dominio) %>%
    dplyr::summarise(
      media = mean(n_prompt),
      sd    = sd(n_prompt),
      cv    = sd / media,   # coefficiente di variazione: più alto = più sbilanciato
      min   = min(n_prompt),
      max   = max(n_prompt),
      .groups = "drop"
    )

  list(conteggi = conteggi, sbilanciamento = sbilanciamento)
}

#' Calcola quanti prompt ha ciascuna singola entità, dentro ogni categoria/dominio
#'
#' Livello di granularità più fine di calcola_bilanciamento(): quest'ultima
#' controlla se le CATEGORIE sono bilanciate tra loro, questa funzione
#' controlla se, DENTRO la stessa categoria, i prompt sono distribuiti
#' equamente tra le varie entità o dominati da poche entità molto
#' rappresentate (es. una celebrità con pagina Wikipedia molto lunga).
calcola_conteggio_entita <- function(df) {
  df %>%
    dplyr::group_by(dominio, categoria, entita) %>%
    dplyr::summarise(n_prompt_entita = dplyr::n(), .groups = "drop")
}

#' Riassume lo sbilanciamento delle entità dentro ciascuna categoria
#'
#' @param conteggio_entita Output di calcola_conteggio_entita()
#' @return Dataframe con una riga per categoria: numero di entità distinte,
#'   media/sd/cv dei prompt per entità, e numero massimo di prompt
#'   riconducibili a una singola entità (segnale diretto di dominanza)
calcola_sbilanciamento_entita <- function(conteggio_entita) {
  conteggio_entita %>%
    dplyr::group_by(dominio, categoria) %>%
    dplyr::summarise(
      n_entita = dplyr::n(),
      media_prompt_per_entita = mean(n_prompt_entita),
      sd_prompt_per_entita = sd(n_prompt_entita),
      cv_entita = sd_prompt_per_entita / media_prompt_per_entita,
      max_prompt_singola_entita = max(n_prompt_entita),
      .groups = "drop"
    ) %>%
    dplyr::arrange(dplyr::desc(cv_entita))
}

#' Individua, per ogni categoria, l'entità più prolifica e quanto pesa
#' sul totale dei prompt di quella categoria (in percentuale)
#'
#' Un valore alto di percentuale_su_categoria segnala che una singola
#' entità domina la categoria — da documentare esplicitamente nel report,
#' perché le metriche di bias calcolate su quella categoria rifletterebbero
#' in gran parte lo stile testuale di una sola persona/entità, non un
#' campione rappresentativo del gruppo.
trova_entita_dominanti <- function(conteggio_entita) {
  conteggio_entita %>%
    dplyr::group_by(dominio, categoria) %>%
    dplyr::mutate(
      totale_categoria = sum(n_prompt_entita),
      percentuale_su_categoria = 100 * n_prompt_entita / totale_categoria
    ) %>%
    dplyr::slice_max(n_prompt_entita, n = 1) %>%
    dplyr::ungroup() %>%
    dplyr::arrange(dplyr::desc(percentuale_su_categoria)) %>%
    dplyr::select(dominio, categoria, entita, n_prompt_entita, totale_categoria, percentuale_su_categoria)
}

#' Istogramma della distribuzione del numero di prompt per entità
#' (su scala log, perché tipicamente molto asimmetrica: poche entità
#' con tanti prompt, tante entità con pochissimi)
plot_distribuzione_entita <- function(conteggio_entita) {
  ggplot2::ggplot(conteggio_entita, ggplot2::aes(x = n_prompt_entita)) +
    ggplot2::geom_histogram(bins = 40, fill = "darkorange") +
    ggplot2::scale_x_log10() +
    ggplot2::facet_wrap(~dominio, scales = "free_y") +
    ggplot2::labs(
      title = "Distribuzione del numero di prompt per singola entità (scala log)",
      x = "Numero di prompt per entità (log10)",
      y = "Numero di entità"
    ) +
    ggplot2::theme_minimal()
}

#' Grafico a barre del numero di prompt per categoria, sfaccettato per dominio
plot_bilanciamento <- function(conteggi) {
  ggplot2::ggplot(conteggi, ggplot2::aes(x = reorder(categoria, n_prompt), y = n_prompt, fill = dominio)) +
    ggplot2::geom_col() +
    ggplot2::coord_flip() +
    ggplot2::facet_wrap(~dominio, scales = "free_y") +
    ggplot2::labs(
      title = "Numero di prompt per categoria e dominio",
      x = "Categoria",
      y = "Numero di prompt"
    ) +
    ggplot2::theme_minimal() +
    ggplot2::theme(legend.position = "none")
}

#' Istogramma della lunghezza dei prompt, sfaccettato per dominio
plot_distribuzione_lunghezza <- function(df) {
  ggplot2::ggplot(df, ggplot2::aes(x = n_parole, fill = dominio)) +
    ggplot2::geom_histogram(bins = 40, alpha = 0.7, position = "identity") +
    ggplot2::facet_wrap(~dominio, scales = "free_y") +
    ggplot2::labs(
      title = "Distribuzione della lunghezza dei prompt (parole) per dominio",
      x = "Numero di parole",
      y = "Frequenza"
    ) +
    ggplot2::theme_minimal() +
    ggplot2::theme(legend.position = "none")
}

#' Boxplot comparativo della lunghezza dei prompt per dominio
plot_boxplot_lunghezza <- function(df) {
  ggplot2::ggplot(df, ggplot2::aes(x = dominio, y = n_parole, fill = dominio)) +
    ggplot2::geom_boxplot() +
    ggplot2::labs(
      title = "Boxplot della lunghezza dei prompt per dominio",
      x = "Dominio",
      y = "Numero di parole"
    ) +
    ggplot2::theme_minimal() +
    ggplot2::theme(legend.position = "none")
}

#' Test di normalità (Shapiro-Wilk) su un campione della lunghezza dei prompt
#'
#' shapiro.test() in R rifiuta input con più di 5000 osservazioni:
#' per questo si campiona, non è una scelta metodologica arbitraria
#' ma un limite tecnico della funzione (da menzionare nel report).
test_normalita_lunghezza <- function(df, n_campione = 5000, seed = 42) {
  set.seed(seed)
  campione <- df %>% dplyr::slice_sample(n = min(n_campione, nrow(df)))
  shapiro.test(campione$n_parole)
}

#' Test di Kruskal-Wallis: la lunghezza dipende dal dominio?
#' (non parametrico, usato al posto di ANOVA perché la normalità
#' è tipicamente violata per dati testuali)
test_dipendenza_dominio <- function(df) {
  kruskal.test(n_parole ~ dominio, data = df)
}

#' Test post-hoc a coppie (Wilcoxon con correzione Bonferroni)
#' Alternativa nativa a dunn.test, senza dipendenze esterne da compilare
test_posthoc_dominio <- function(df) {
  pairwise.wilcox.test(df$n_parole, df$dominio, p.adjust.method = "bonferroni")
}

#' Calcola il Type-Token Ratio (diversità lessicale) per un insieme di testi
#'
#' NOTA: il TTR scende meccanicamente all'aumentare del numero di token
#' (con più testo è più probabile ripescare parole già usate). Da
#' interpretare con cautela quando si confrontano categorie con n molto
#' diversi tra loro (vedi report per la discussione di questo limite).
calcola_ttr <- function(testi) {
  parole <- unlist(stringr::str_split(tolower(paste(testi, collapse = " ")), "\\s+"))
  parole <- parole[parole != ""]
  length(unique(parole)) / length(parole)
}

#' Calcola il TTR per ogni combinazione dominio-categoria
calcola_ttr_per_categoria <- function(df) {
  df %>%
    dplyr::group_by(dominio, categoria) %>%
    dplyr::summarise(ttr = calcola_ttr(prompt), n_prompt = dplyr::n(), .groups = "drop") %>%
    dplyr::arrange(dominio, ttr)
}

#' Grafico a barre del TTR per categoria, sfaccettato per dominio
plot_ttr <- function(ttr_per_categoria) {
  ggplot2::ggplot(ttr_per_categoria, ggplot2::aes(x = reorder(categoria, ttr), y = ttr, fill = dominio)) +
    ggplot2::geom_col() +
    ggplot2::coord_flip() +
    ggplot2::facet_wrap(~dominio, scales = "free_y") +
    ggplot2::labs(
      title = "Diversità lessicale (Type-Token Ratio) per categoria",
      x = "Categoria",
      y = "TTR"
    ) +
    ggplot2::theme_minimal() +
    ggplot2::theme(legend.position = "none")
}
