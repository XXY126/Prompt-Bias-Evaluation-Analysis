# Rscript scripts/tests/test_diversita_repliche.R
if (dir.exists(".audit-r-library")) .libPaths(c(".audit-r-library", .libPaths()))
source("R/audit_generazioni.R")

df <- data.frame(
  model_key = "qwen3_8b_base", prompt_id = "prompt_a", repetition = 1:5,
  domain = "gender", category = "female", subject = "Example", prompt = "Example",
  generation = c("  Hello WORLD. ", "hello\nworld.", "Different.",
                 "\u4f60\u597d\tWORLD!", " \u4f60\u597d\u00A0world! "),
  status = "ok", generated_tokens = 5, finish_reason = "max_new_tokens"
)
annotato <- aggiungi_flag_generazioni(df)
risultati <- analizza_diversita_repliche(annotato)
s <- risultati$per_prompt
stopifnot(s$n_valid == 5, s$n_unique_normalized == 3,
          s$n_redundant_normalized == 2, s$max_same_normalized == 2,
          s$n_pairs == 10, s$n_equal_pairs_normalized == 2,
          !s$all_identical_normalized, nrow(risultati$uguali) == 4,
          sum(risultati$distribuzione$n_prompts) == 1,
          identical(annotato$generation, df$generation),
          identical(risultati$uguali$generation, df$generation[c(1, 2, 4, 5)]))

# Conserva differenze di punteggiatura, accenti, negazioni e numeri.
testi <- c("Yes.", "Yes?", "cafe", "caf\u00e9", "is good", "is not good", "1", "2")
stopifnot(length(unique(normalizza_generazione(testi))) == length(testi),
          is.na(normalizza_generazione(NA_character_)))

uguali <- df
uguali$generation <- rep("HELLO world.", 5)
s <- analizza_diversita_repliche(aggiungi_flag_generazioni(uguali))$per_prompt
stopifnot(s$n_unique_normalized == 1, s$n_redundant_normalized == 4,
          s$n_equal_pairs_normalized == 10, s$all_identical_normalized)

# Le chiavi dei prompt e dei modelli delimitano i confronti.
altro <- uguali
altro$model_key <- "qwen3_8b_post"
altra_occorrenza <- uguali
altra_occorrenza$prompt_id <- "prompt_b"
s <- analizza_diversita_repliche(
  aggiungi_flag_generazioni(rbind(df, altro, altra_occorrenza))
)$per_prompt
stopifnot(nrow(s) == 3, all(s$n_valid == 5), sum(s$n_pairs) == 30)

# Zero o una continuazione valida non dimostrano identita' tra repliche.
vuote <- df
vuote$generation <- c(NA, "", "\t", "Text.", "Other.")
vuote$status[4:5] <- "failed"
r <- analizza_diversita_repliche(aggiungi_flag_generazioni(vuote))
stopifnot(r$per_prompt$n_valid == 0, r$per_prompt$n_unique_normalized == 0,
          r$per_prompt$n_pairs == 0, is.na(r$per_prompt$max_same_normalized),
          is.na(r$per_prompt$all_identical_normalized), nrow(r$uguali) == 0)
s <- analizza_diversita_repliche(aggiungi_flag_generazioni(df[1, ]))$per_prompt
stopifnot(s$n_valid == 1, s$n_unique_normalized == 1,
          s$n_pairs == 0, is.na(s$all_identical_normalized))

# Un record duplicato non deve diventare una replica aggiuntiva.
r <- analizza_diversita_repliche(aggiungi_flag_generazioni(rbind(df, df[1, ])))
stopifnot(r$per_prompt$replica_group_invalid, r$per_prompt$n_records == 6,
          is.na(r$per_prompt$n_unique_normalized), is.na(r$per_prompt$n_pairs),
          is.na(r$per_prompt$all_identical_normalized), nrow(r$uguali) == 0)
cat("OK: confronto normalizzato, separazione dei gruppi, coppie, NA e chiavi duplicate.\n")
