# ============================================================
# 03_eda_statistica.R
#
# STEP 3 della pipeline: analisi statistica descrittiva e
# inferenziale sul dataset già pulito — bilanciamento tra
# categorie, distribuzione della lunghezza, test di normalità
# e dipendenza dal dominio, diversità lessicale (TTR).
#
# INPUT:  data/processed/02_bold_pulito.rds
# OUTPUT: output/figures/*.png
#         output/tables/bilanciamento_categorie.csv
#         output/tables/ttr_per_categoria.csv
#         data/processed/03_bold_eda.rds  (dataset finale pronto
#           per la generazione con i modelli offline)
# ============================================================

source(here::here("scripts", "00_setup.R"))
source(here::here("R", "eda_statistica.R"))

# --- Caricamento output dello step precedente ---
df <- readRDS(here("data", "processed", "02_bold_pulito.rds"))

# ============================================================
# Bilanciamento tra categorie
# ============================================================

bilanciamento <- calcola_bilanciamento(df)
print(bilanciamento$conteggi)
print(bilanciamento$sbilanciamento)

write.csv(
  bilanciamento$conteggi,
  here("output", "tables", "bilanciamento_categorie.csv"),
  row.names = FALSE
)

plot_bal <- plot_bilanciamento(bilanciamento$conteggi)
ggsave(here("output", "figures", "bilanciamento_categorie.png"), plot_bal, width = 10, height = 8)

# ============================================================
# Bilanciamento a livello di singola entità (dentro ogni categoria)
# ============================================================
# Livello di granularità più fine: anche se una categoria ha "abbastanza"
# prompt in totale, questi potrebbero essere concentrati su poche entità
# molto rappresentate (es. celebrità con pagina Wikipedia molto lunga),
# invece che distribuiti equamente tra tutte le entità della categoria.

conteggio_entita <- calcola_conteggio_entita(df)

sbilanciamento_entita <- calcola_sbilanciamento_entita(conteggio_entita)
print(sbilanciamento_entita)

entita_dominanti <- trova_entita_dominanti(conteggio_entita)
print(entita_dominanti)

write.csv(
  conteggio_entita,
  here("output", "tables", "conteggio_prompt_per_entita.csv"),
  row.names = FALSE
)
write.csv(
  sbilanciamento_entita,
  here("output", "tables", "sbilanciamento_entita_per_categoria.csv"),
  row.names = FALSE
)
write.csv(
  entita_dominanti,
  here("output", "tables", "entita_dominanti_per_categoria.csv"),
  row.names = FALSE
)

plot_entita <- plot_distribuzione_entita(conteggio_entita)
ggsave(here("output", "figures", "distribuzione_prompt_per_entita.png"), plot_entita, width = 10, height = 8)

# Segnala nel log le categorie dove un'unica entità supera il 10% del totale:
# soglia arbitraria ma ragionevole per un primo controllo, da rivalutare
# leggendo la tabella completa entita_dominanti_per_categoria.csv
soglia_dominanza <- 10
categorie_a_rischio <- entita_dominanti %>% dplyr::filter(percentuale_su_categoria > soglia_dominanza)

if (nrow(categorie_a_rischio) > 0) {
  cat("\n⚠️  Categorie con un'entità che supera il", soglia_dominanza, "% del totale:\n")
  print(categorie_a_rischio)
} else {
  cat("\nNessuna categoria ha un'entità dominante oltre la soglia del", soglia_dominanza, "%.\n")
}

# ============================================================
# Distribuzione della lunghezza dei prompt
# ============================================================

plot_hist <- plot_distribuzione_lunghezza(df)
ggsave(here("output", "figures", "distribuzione_lunghezza.png"), plot_hist, width = 10, height = 6)

plot_box <- plot_boxplot_lunghezza(df)
ggsave(here("output", "figures", "boxplot_lunghezza.png"), plot_box, width = 8, height = 6)

# QQ-plot (supporto visivo alla normalità)
png(here("output", "figures", "qqplot_lunghezza.png"), width = 800, height = 600)
qqnorm(df$n_parole, main = "QQ-Plot lunghezza prompt (parole)")
qqline(df$n_parole, col = "red")
dev.off()

# ============================================================
# Test statistici
# ============================================================

shapiro_result <- test_normalita_lunghezza(df)
print(shapiro_result)

kruskal_result <- test_dipendenza_dominio(df)
print(kruskal_result)

posthoc_result <- test_posthoc_dominio(df)
print(posthoc_result)

# ============================================================
# Diversità lessicale (TTR)
# ============================================================

ttr_categoria <- calcola_ttr_per_categoria(df)
print(ttr_categoria)

write.csv(
  ttr_categoria,
  here("output", "tables", "ttr_per_categoria.csv"),
  row.names = FALSE
)

plot_ttr_fig <- plot_ttr(ttr_categoria)
ggsave(here("output", "figures", "ttr_per_categoria.png"), plot_ttr_fig, width = 10, height = 8)

# ============================================================
# Riepilogo finale
# ============================================================

cat("\n========== RIEPILOGO EDA STATISTICA ==========\n")
cat("Prompt totali:", nrow(df), "\n")
cat("Domini:", length(unique(df$dominio)), "\n")
cat("Categorie totali:", dplyr::n_distinct(paste(df$dominio, df$categoria)), "\n")
cat("Test Shapiro-Wilk (campione) p-value:", format.pval(shapiro_result$p.value, digits = 3), "\n")
cat("Test Kruskal-Wallis (lunghezza ~ dominio) p-value:", format.pval(kruskal_result$p.value, digits = 3), "\n")
cat("================================================\n")

# --- Salvataggio dataset finale, pronto per la generazione con i modelli ---
output_path <- here("data", "processed", "03_bold_eda.rds")
saveRDS(df, output_path)

message("Dataset finale (post EDA) salvato in: ", output_path)
message("Pronto per lo step successivo: generazione con modelli offline.")
