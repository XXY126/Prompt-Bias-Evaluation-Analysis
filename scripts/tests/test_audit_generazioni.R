# Controlli mirati su Unicode, dati mancanti e abbinamento delle repliche.
# Rscript scripts/tests/test_audit_generazioni.R
if (dir.exists(".audit-r-library")) .libPaths(c(".audit-r-library", .libPaths()))
source("R/audit_generazioni.R")
df <- data.frame(
  prompt_id = letters[1:7], model_key = "qwen3_8b_base", repetition = 1L,
  domain = "gender", category = "female", subject = "Example",
  prompt = c("Example", "Example", "Example", "Example", "", "Example", "Example"),
  generation = c("English only.", "Hello \u4f60\u597d, world \u4e16\u754c!",
                 "\u65e5\u672c\u8a9e\u304b\u306a", "\U00020000", NA, "  ",
                 "word word word word"),
  status = c(rep("ok", 4), "skipped_empty_prompt", "ok", "ok"),
  generated_tokens = c(3, 8, 5, 1, 0, 1, 4),
  finish_reason = c(rep("max_new_tokens", 4), "not_generated_empty_prompt",
                    "eos_token", "eos_token"), stringsAsFactors = FALSE
)
x <- aggiungi_flag_generazioni(df)
stopifnot(identical(x$generation, df$generation), identical(x$prompt, df$prompt),
          identical(which(x$audit_has_han), 2:4), x$audit_n_han[2] == 4,
          x$audit_n_han[4] == 1, x$audit_has_kana[3],
          x$audit_han_and_latin[2], !x$audit_han_and_latin[3],
          is.na(x$audit_han_share_letters[5]), !x$audit_empty_generation[5],
          x$audit_empty_generation[6], x$audit_repeated_word[7])
segments <- estrai_passaggi_han(x)
stopifnot(nrow(segments) == 4,
          segments$han_segment[1] == "\u4f60\u597d",
          segments$start_char[1] == 7, segments$end_char[1] == 8,
          nrow(estrai_passaggi_han(x[1, ])) == 0)
s <- riepiloga_generazioni(x)
stopifnot(s$n_nonempty_ok == 5, s$n_han_ok == 3,
          s$pct_han_nonempty_ok == 60, s$n_empty_generation == 1)
copertura <- controlla_abbinamento_generazioni(x, c("qwen3_8b_base", "qwen3_8b_post"))
stopifnot(sum(copertura$n_records == 0) == 7)
duplicati <- aggiungi_flag_generazioni(rbind(df, df[1, ]))
stopifnot(sum(duplicati$audit_duplicate_key) == 2, nrow(duplicati) == 8)
post <- df
post$model_key <- "qwen3_8b_post"
paired <- aggiungi_flag_generazioni(rbind(df, post))
sample1 <- campiona_revisione_generazioni(paired, 2)
sample2 <- campiona_revisione_generazioni(paired, 2)
stopifnot(nrow(sample1) == 4, identical(sample1, sample2),
          all(table(sample1$prompt_id) == 2))
skip <- riepiloga_generazioni(x[5, ])
stopifnot(is.na(skip$pct_han_nonempty_ok), is.na(skip$mean_generated_tokens_ok))
bad <- df
bad$prompt[2] <- "\u4f60\u597d"
bad$status[1] <- NA_character_
bad$status[3] <- "skipped_empty_prompt"
flags <- aggiungi_flag_generazioni(bad)
stopifnot(!flags$audit_han_only_in_generation[2], flags$audit_unexpected_status[1],
          flags$audit_status_inconsistent[3], !anyNA(flags$audit_review))
quiz <- df
quiz$generation <- c("Who? Answer: Example.", "Why? What?", "Plain text.",
                     "Fullwidth\uFF1F", NA, "  ", "No questions.")
quiz$prompt[3] <- "A question in the prompt?"
quiz_flags <- aggiungi_flag_generazioni(quiz)
quiz_summary <- riepiloga_generazioni(quiz_flags)
stopifnot(identical(which(quiz_flags$audit_has_question_mark), 1:2),
          identical(quiz_flags$audit_n_question_marks, c(1L, 2L, 0L, 0L, NA_integer_, 0L, 0L)),
          all(quiz_flags$audit_review[1:2]),
          identical(quiz_flags$generation, quiz$generation),
          identical(quiz_flags$prompt, quiz$prompt),
          quiz_summary$n_question_mark_ok == 2,
          quiz_summary$pct_question_mark_nonempty_ok == 40,
          is.na(riepiloga_generazioni(quiz_flags[5, ])$pct_question_mark_nonempty_ok))
cat("OK: Unicode Han/Kana, quiz con '?', testo invariato, NA, denominatori, duplicati e campione appaiato.\n")

# V3: fine frase e limite effettivo sono segnali distinti.
sentence <- df[1:2, ]
sentence$sentence_complete <- c(TRUE,FALSE)
sentence$generation_hit_token_limit <- c(TRUE,FALSE)
sentence$finish_reason <- c("sentence_end","eos_token")
sentence <- aggiungi_flag_generazioni(sentence)
stopifnot(identical(sentence$audit_at_token_limit,c(TRUE,FALSE)),
          identical(sentence$audit_sentence_incomplete,c(FALSE,TRUE)),
          sentence$audit_review[2],riepiloga_generazioni(sentence)$n_sentence_incomplete==1L)
