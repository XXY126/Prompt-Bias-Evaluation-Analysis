if (dir.exists(".audit-r-library")) .libPaths(c(".audit-r-library", .libPaths()))
source("R/anonimizzazione.R")
source("R/anonimizzazione_ner.R")
t <- "Waylon Payne also stars in Monte Hellman's film. Is he bad?"
d <- localizza_dizionario(t,"Waylon Payne")[[1]]
n <- localizza_dizionario(t,"Monte Hellman")[[1]]
r <- unisci_intervalli(t,d,n)
stopifnot(sostituisci_intervalli(t,r$spans) == "Person also stars in Person's film. Is he bad?",
          !r$conflict, sum(r$spans$source=="ner")==1L)
# Stesso nome trovato due volte: una sostituzione, provenienza doppia.
r <- unisci_intervalli("Alice White",data.frame(start_char=0L,end_char=11L),
                       data.frame(start_char=0L,end_char=11L,entity="Alice White"))
stopifnot(nrow(r$spans)==1L, r$spans$source=="dictionary+ner", !r$conflict)
# Un cognome gia' incluso nel nome completo non viene sostituito due volte.
r <- unisci_intervalli("Alice White",data.frame(start_char=0L,end_char=11L),
                       data.frame(start_char=6L,end_char=11L))
stopifnot(nrow(r$spans)==1L, !r$conflict)
# Un intervallo NER che estende il dizionario non elimina parole ulteriori.
r <- unisci_intervalli("Alice White and Bob",data.frame(start_char=0L,end_char=11L),
                       data.frame(start_char=0L,end_char=19L))
stopifnot(r$conflict, sostituisci_intervalli("Alice White and Bob",r$spans)=="Person and Bob")
# Indici Unicode: Han e emoji contano come singoli caratteri, non byte.
t <- "\u6f22 \U0001f600 Jos\u00e9's?"
r <- unisci_intervalli(t,intervalli_vuoti(),localizza_dizionario(t,"Jos\u00e9")[[1]])
stopifnot(sostituisci_intervalli(t,r$spans)=="\u6f22 \U0001f600 Person's?",
          sostituisci_intervalli(t,intervalli_vuoti())==t)
# Non cancellare l'esclusione linguistica quando il cognome residuo e' risolto.
x <- data.frame(subject="Alice_White", domain="gender", text_anonymized="Person is kind.",
  anonymization_n_replacements=1L, anonymization_n_prompt_replacements=1L,
  ner_overlap_conflict=FALSE, ner_crosses_prompt_boundary=FALSE,
  eligible_english_metrics=FALSE, anonymization_status="applied",
  anonymization_residual_name_candidate=TRUE, anonymization_review_reason="residual_target_name_candidate",
  anonymization_review_required=TRUE, eligible_anonymized_metrics=FALSE)
dict <- data.frame(domain="gender",subject="Alice_White",review_reason=NA_character_)
x <- aggiorna_revisione_ner(x,1L,dict)
stopifnot(!x$anonymization_review_required, !x$eligible_anonymized_metrics)
cat("OK: abbinamento, sovrapposizioni, Unicode, possessivi e criteri di revisione.\n")
