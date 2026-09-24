# ============================================================
# 06_audit_generazioni.R
# Audit delle continuazioni BOLD: completezza, qualita' e revisione.
#
# INPUT:  data/generated/<run>/<modello>/generations.parquet
#         e relativi metadata.json
# OUTPUT: output/audit/generazioni/<run>/
#
# Eseguire dalla radice del progetto.
# Da terminale:
#   Rscript scripts/06_audit_generazioni.R bold_raw_v1_rep5
# In RStudio:
#   source("scripts/06_audit_generazioni.R")
# Per scegliere un'altra run con source():
#   Sys.setenv(BOLD_AUDIT_RUN = "nome_run")
# ============================================================


# ------------------------------------------------------------
# 1. Dipendenze e funzioni riutilizzabili
# ------------------------------------------------------------

# Aggiunge la libreria locale, se presente. Non installa pacchetti.
if (dir.exists(".audit-r-library"))
  .libPaths(c(".audit-r-library", .libPaths()))

pacchetti <- c("here", "dplyr", "stringi", "readr", "jsonlite", "ggplot2", "arrow")
mancanti <- pacchetti[!vapply(pacchetti, requireNamespace, logical(1), quietly = TRUE)]

if (length(mancanti))
  stop("Installare i pacchetti R: ", paste(mancanti, collapse = ", "))

source(here::here("R", "audit_generazioni.R"))


# ------------------------------------------------------------
# 2. Scelta della run e percorsi
# ------------------------------------------------------------

# In esecuzione non interattiva, il primo argomento ha precedenza.
# Altrimenti usa BOLD_AUDIT_RUN, con bold_raw_v1_rep5 come default.
args <- commandArgs(trailingOnly = TRUE)
run_name <- if (!interactive() && length(args))
  args[1] else
  Sys.getenv("BOLD_AUDIT_RUN", "bold_raw_v1_rep5")

if (!grepl("^[A-Za-z0-9][A-Za-z0-9_.-]*$", run_name))
  stop("Nome run non valido.")

run_dir <- here::here("data", "generated", run_name)
output_dir <- here::here("output", "audit", "generazioni", run_name)

if (!dir.exists(run_dir))
  stop("Run inesistente: ", run_dir)


# ------------------------------------------------------------
# 3. Caricamento e aggiunta dei flag di audit
# ------------------------------------------------------------

run <- leggi_run_generazioni(run_dir)
df <- aggiungi_flag_generazioni(run$data)

# Conserva la rappresentazione R del lettore, ordine e numero delle righe.
# Eventuali NUL sostituiti dal lettore sono tracciati separatamente.
stopifnot(
  identical(df$prompt, run$data$prompt),
  identical(df$generation, run$data$generation),
  nrow(df) == nrow(run$data)
)

dir.create(output_dir, recursive = TRUE, showWarnings = FALSE)


# ------------------------------------------------------------
# 4. Abbinamento tra modelli e coerenza dei prompt
# ------------------------------------------------------------

# I due modelli previsti restano nella verifica anche se uno non e' presente.
modelli <- union(c("qwen3_8b_base", "qwen3_8b_post"), unique(df$model_key))
copertura <- controlla_abbinamento_generazioni(df, modelli)

# Per ogni coppia prompt/replica, testo e attributi devono coincidere.
incoerenze <- dplyr::summarise(
  dplyr::group_by(df, prompt_id, repetition),
  n_prompt_texts = dplyr::n_distinct(prompt),
  n_domains = dplyr::n_distinct(domain),
  n_categories = dplyr::n_distinct(category),
  n_subjects = dplyr::n_distinct(subject),
  .groups = "drop"
)

incoerenze <- dplyr::filter(
  incoerenze,
  n_prompt_texts != 1 | n_domains != 1 |
    n_categories != 1 | n_subjects != 1
)


# ------------------------------------------------------------
# 5. Riepiloghi ed esportazione dei dati
# ------------------------------------------------------------

# CSV UTF-8 con BOM, leggibili anche in Excel; NA esportati come celle vuote.
scrivi <- function(x, nome)
  readr::write_excel_csv(x, file.path(output_dir, nome), na = "")

summary_model <- riepiloga_generazioni(df)
summary_category <- riepiloga_generazioni(df, c("model_key", "domain", "category"))

# Diversita' tra repliche dello stesso prompt, separatamente per modello.
# La normalizzazione agisce su una copia dei testi usata per il confronto.
diversita_repliche <- analizza_diversita_repliche(df)
scrivi(diversita_repliche$per_prompt, "diversita_repliche_prompt.csv")
scrivi(diversita_repliche$distribuzione, "distribuzione_diversita_repliche.csv")
scrivi(diversita_repliche$uguali, "repliche_uguali_normalizzate.csv")

# Completezza, riepiloghi descrittivi e motivi di arresto.
scrivi(run$completeness, "completezza.csv")
scrivi(summary_model, "riepilogo_modello.csv")
scrivi(summary_category, "riepilogo_categoria.csv")
scrivi(
  riepiloga_generazioni(df, c("model_key", "repetition")),
  "riepilogo_replica.csv"
)
scrivi(dplyr::count(df, model_key, status, finish_reason), "stati_arresto.csv")

# Problemi di abbinamento e casi da ispezionare manualmente.
scrivi(dplyr::filter(copertura, n_records != 1), "problemi_abbinamento.csv")
scrivi(incoerenze, "prompt_incoerenti.csv")
scrivi(run$nul_report, "caratteri_nul.csv")
scrivi(df[df$audit_review, ], "casi_da_rivedere.csv")

# Indicatori testuali: caratteri Han e '?' come euristica di possibile quiz.
scrivi(df[df$audit_has_han, ], "generazioni_con_han.csv")
scrivi(df[df$audit_has_question_mark, ], "generazioni_possibili_quiz.csv")
scrivi(estrai_passaggi_han(df), "passaggi_han.csv")

# Campione per annotazione e dataset completo con tutti i flag.
scrivi(campiona_revisione_generazioni(df), "campione_revisione.csv")
saveRDS(df, file.path(output_dir, "generazioni_annotate.rds"))


# ------------------------------------------------------------
# 6. Grafici descrittivi
# ------------------------------------------------------------

# Distribuzione dei token per modello e dominio, sulle generazioni con stato ok.
plot_data <- df[df$audit_status_ok & !is.na(df$generated_tokens), ]

if (nrow(plot_data)) {
  p <- ggplot2::ggplot(
    plot_data,
    ggplot2::aes(generated_tokens, fill = model_key)
  ) +
    ggplot2::geom_histogram(binwidth = 1, boundary = -0.5, show.legend = FALSE) +
    ggplot2::facet_grid(model_key ~ domain, scales = "free_y") +
    ggplot2::labs(
      x = "Token generati",
      y = "Numero di continuazioni",
      title = paste("Lunghezza delle continuazioni -", run_name)
    ) +
    ggplot2::theme_minimal()

  ggplot2::ggsave(
    file.path(output_dir, "lunghezze.png"),
    p,
    width = 13,
    height = 6,
    dpi = 160
  )
}

# Frequenza di Han sulle continuazioni non vuote con stato ok.
p <- ggplot2::ggplot(
  summary_category,
  ggplot2::aes(pct_han_nonempty_ok, category, colour = model_key)
) +
  ggplot2::geom_point(position = ggplot2::position_dodge(width = 0.5), na.rm = TRUE) +
  ggplot2::facet_wrap(~domain, scales = "free_y", ncol = 2) +
  ggplot2::labs(
    x = "% con caratteri Han (continuazioni non vuote con status ok)",
    y = NULL,
    colour = "Modello",
    title = "Presenza di caratteri Han per categoria",
    subtitle = "Indicatore di scrittura; non identifica automaticamente la lingua cinese"
  ) +
  ggplot2::theme_minimal()

ggplot2::ggsave(
  file.path(output_dir, "presenza_han.png"),
  p,
  width = 13,
  height = 11,
  dpi = 160
)


# ------------------------------------------------------------
# 7. Metadati e informazioni per la riproducibilita'
# ------------------------------------------------------------

# Registra input, impronte dei file, criteri dei flag e ambiente software.
jsonlite::write_json(
  list(
    run = run_name,
    audited_at = format(Sys.time(), tz = "UTC", usetz = TRUE),
    input_files = normalizePath(run$files, winslash = "/"),
    input_md5 = as.list(tools::md5sum(run$files)),
    source_metadata = run$metadata,
    script_md5 = as.list(tools::md5sum(here::here(c(
      "R/audit_generazioni.R",
      "scripts/06_audit_generazioni.R"
    )))),
    han_detection = "Unicode script=Han; not a Chinese language classifier",
    quiz_detection = "Literal ASCII '?' in generation only; does not verify an answer is present",
    nul_handling = list(
      policy = "nul_visible_replacement_v1",
      action = "NUL -> U+FFFD only in R audit copy; original Parquet unchanged",
      raw_bytes = "caratteri_nul.csv: original_utf8_hex for each affected cell",
      n_rows = sum(df$audit_has_nul), n_nul = sum(df$audit_n_nul),
      metric_preparation = "prompt/generation NUL rows are not prepared for scoring"
    ),
    replica_comparison = list(
      method = "Equality after lowercase (locale=en), Unicode whitespace collapse and trim",
      group_by = c("model_key", "prompt_id"),
      eligible = "status=ok and nonempty generation; groups with duplicate keys excluded",
      original_text_preserved = !any(df$audit_has_nul)
    ),
    sampling = list(
      seed = 42,
      keys_per_category = 5,
      paired_by = c("prompt_id", "repetition")
    ),
    r_version = R.version.string,
    packages = as.list(vapply(
      pacchetti,
      function(x) as.character(utils::packageVersion(x)),
      character(1)
    ))
  ),
  file.path(output_dir, "audit_metadata.json"),
  pretty = TRUE,
  auto_unbox = TRUE,
  na = "null"
)

capture.output(sessionInfo(), file = file.path(output_dir, "sessionInfo.txt"))


# ------------------------------------------------------------
# 8. Riepilogo a console e segnalazione dei problemi
# ------------------------------------------------------------

print(as.data.frame(summary_model))

if (any(run$completeness$records_difference != 0, na.rm = TRUE) ||
    any(is.na(run$completeness$metadata_status) |
        run$completeness$metadata_status != "complete")) {
  warning("Run incompleta o metadati mancanti: consultare completezza.csv.")
}

if (any(copertura$n_records != 1) || nrow(incoerenze)) {
  warning("Abbinamento tra modelli da verificare: consultare i CSV dei problemi.")
}

message("Audit salvato in: ", output_dir)
