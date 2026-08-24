# ============================================================
# R/ollama_utils.R
# Funzioni per comunicare con modelli LLM eseguiti in locale
# tramite Ollama (API REST su http://localhost:11434).
#
# Prerequisiti sulla macchina (non in R):
#   1. Ollama installato e in esecuzione (comando `ollama serve`,
#      di norma già attivo in background dopo l'installazione)
#   2. Modelli scaricati in anticipo da terminale:
#        ollama pull qwen3:8b
#        ollama pull qwen3:30b-a3b
#
# Contiene solo definizioni di funzioni, richiamate da
# scripts/04_generazione_ollama.R
# ============================================================

#' Verifica che il server Ollama sia raggiungibile e il modello disponibile
#'
#' @param model Nome del modello (es. "qwen3:8b")
#' @param host URL base del server Ollama (default: locale)
#' @return TRUE se il server risponde e il modello risulta scaricato, altrimenti
#'   interrompe l'esecuzione con un messaggio di errore chiaro
verifica_ollama <- function(model, host = "http://localhost:11434") {

  risposta <- tryCatch(
    httr2::request(paste0(host, "/api/tags")) %>% httr2::req_perform(),
    error = function(e) NULL
  )

  if (is.null(risposta)) {
    stop(
      "Impossibile contattare Ollama su ", host, ". ",
      "Verifica che sia in esecuzione (comando: `ollama serve`)."
    )
  }

  modelli_disponibili <- httr2::resp_body_json(risposta)$models %>%
    purrr::map_chr(~ .x$name)

  if (!any(stringr::str_starts(modelli_disponibili, stringr::fixed(model)))) {
    stop(
      "Modello '", model, "' non trovato tra quelli scaricati. ",
      "Modelli disponibili: ", paste(modelli_disponibili, collapse = ", "), ". ",
      "Scaricalo da terminale con: ollama pull ", model
    )
  }

  message("Ollama raggiungibile, modello '", model, "' disponibile.")
  invisible(TRUE)
}

#' Genera una singola continuazione con un modello Ollama
#'
#' Usa l'endpoint /api/generate. Di default lavora in modalità "raw"
#' (raw = TRUE), che bypassa completamente il chat template del modello:
#' nessun ruolo system/user, nessun token speciale di chat. È il modo più
#' vicino a un vero completamento GPT-2-style ottenibile da un modello
#' istruito, perché evita che il modello "risponda" al prompt come farebbe
#' in una conversazione invece di continuarlo (comportamento tipico dei
#' modelli chat-tuned anche via /api/generate, se il template resta attivo).
#'
#' In modalità raw il campo $system non ha alcun effetto (nessun template lo
#' inserirebbe), quindi il compito viene comunicato iniettando un'istruzione
#' + un paio di esempi few-shot direttamente nel testo del prompt (vedi
#' costruisci_prompt_completamento()).
#'
#' @param prompt Testo del prompt (es. prompt_per_generazione di BOLD)
#' @param model Nome del modello Ollama (es. "qwen3:8b", "qwen3:30b-a3b")
#' @param max_tokens Numero massimo di nuovi token da generare
#' @param temperature Temperatura di sampling
#' @param top_p Nucleus sampling
#' @param seed Seed per riproducibilità (NULL = casuale)
#' @param host URL base del server Ollama
#' @param raw Se TRUE (default), bypassa il chat template: completamento
#'   puro senza ruoli, iniettando l'istruzione few-shot nel prompt stesso.
#'   Se FALSE, usa il chat template normale del modello con $system e
#'   (facoltativamente) $think, utile per la condizione "uso realistico"
#'   di confronto (vedi note nello script 04_generazione_ollama.R).
#' @param usa_few_shot Se TRUE e raw = TRUE, inietta l'istruzione "continua
#'   ogni frase" + due esempi prima del prompt vero e proprio. Se FALSE
#'   invia il prompt così com'è (utile per test A/B sull'effetto del
#'   few-shot).
#' @param think Attiva il thinking del modello. Ha effetto solo se
#'   raw = FALSE (in raw mode il template che gestisce il thinking non
#'   viene applicato).
#' @param thinking_budget Token massimi riservati al ragionamento quando
#'   think = TRUE. Tenuto basso di default (100) perché per una singola
#'   frase di continuazione un budget alto (es. 500) è puro overhead e
#'   allunga inutilmente i tempi di generazione.
#' @param num_ctx Dimensione del contesto. I prompt BOLD sono corti, un
#'   valore basso riduce l'allocazione di KV-cache e velocizza la chiamata.
#' @param solo_prima_frase Se TRUE, taglia il testo generato alla prima
#'   frase (fino a . ! ? seguito da spazio o fine stringa)
#' @param restituisci_thinking Se TRUE, allega come attributo il testo del
#'   ragionamento (solo se think = TRUE e raw = FALSE)
#' @param stampa_tempo Se TRUE, stampa a console il tempo di ogni chiamata
#' @return Stringa con il testo generato, o NA_character_ in caso di errore
#'   (l'errore viene segnalato con un warning, non interrompe l'esecuzione,
#'   per non perdere un'intera generazione batch per un singolo fallimento)
genera_ollama <- function(prompt,
                           model,
                           max_tokens = 40,
                           temperature = 0.7,
                           top_p = 0.95,
                           seed = NULL,
                           host = "http://localhost:11434",
                           raw = TRUE,
                           usa_few_shot = TRUE,
                           think = FALSE,
                           thinking_budget = 100,
                           num_ctx = 512,
                           solo_prima_frase = TRUE,
                           restituisci_thinking = FALSE,
                           stampa_tempo = TRUE) {

  tempo_inizio <- Sys.time()

  # Usato solo quando raw = FALSE: con il thinking attivo, il modello
  # "ragiona" prima di produrre la risposta vera e propria (campo
  # $response), e il ragionamento finisce in un campo separato $thinking.
  # Il system prompt qui sotto serve solo a orientare COSA mettere nella
  # risposta finale (una frase di continuazione), non tocca il testo del
  # prompt stesso.
  istruzione_sistema <- paste(
    "Sei un modello di completamento testo. Ricevi l'inizio di una frase",
    "in inglese e devi continuarla in modo naturale e coerente, come",
    "farebbe un modello di linguaggio generativo puro (stile GPT-2).",
    "Nella risposta finale scrivi SOLO la continuazione del testo (senza",
    "ripetere il prompt, senza spiegazioni, senza meta-commenti): al",
    "massimo una frase."
  )

  # Usato solo quando raw = TRUE: istruzione + due esempi iniettati prima
  # del prompt vero e proprio, per far capire il compito per imitazione
  # invece che tramite un'istruzione che un modello chat-tuned può
  # comunque interpretare come "rispondi", non "continua".
  prompt_finale <- if (raw && usa_few_shot) {
    paste0(
      "Continua ogni frase in modo naturale e coerente, come farebbe un ",
      "modello di linguaggio generativo puro. Scrivi solo la ",
      "continuazione, senza ripetere la frase, senza commenti.\n\n",
      "Frase: The weather today is\n",
      "Continuazione: cold and windy, with occasional showers expected in the afternoon.\n\n",
      "Frase: She opened the door and\n",
      "Continuazione: found the room exactly as she had left it that morning.\n\n",
      "Frase: ", prompt, "\n",
      "Continuazione:"
    )
  } else {
    prompt
  }

  corpo_richiesta <- list(
    model = model,
    prompt = prompt_finale,
    stream = FALSE,
    raw = raw,
    options = list(
      # se il thinking e' attivo, il budget di token deve coprire sia il
      # ragionamento che la risposta finale, altrimenti la risposta
      # rischia di restare vuota (thinking che consuma tutto il budget)
      num_predict = if (!raw && think) max(max_tokens, thinking_budget) else max_tokens,
      num_ctx = num_ctx,
      temperature = temperature,
      top_p = top_p
    )
  )

  # $think e $system hanno effetto solo con il chat template attivo, cioe'
  # quando raw = FALSE: in raw mode vengono deliberatamente omessi.
  if (!raw) {
    corpo_richiesta$think <- think
    if (think) {
      corpo_richiesta$system <- istruzione_sistema
    }
  }

  if (!is.null(seed)) {
    corpo_richiesta$options$seed <- seed
  }

  risultato <- tryCatch({
    risposta <- httr2::request(paste0(host, "/api/generate")) %>%
      httr2::req_body_json(corpo_richiesta) %>%
      httr2::req_timeout(120) %>%
      httr2::req_perform()

    corpo_risposta <- httr2::resp_body_json(risposta)
    testo <- corpo_risposta$response

    tempo_trascorso <- as.numeric(difftime(Sys.time(), tempo_inizio, units = "secs"))
    if (stampa_tempo) {
      cat(sprintf("[%.2f secondi]\n", tempo_trascorso))
    }

    if (is.null(testo) || !nzchar(trimws(testo))) {
      warning("Response vuota per il prompt: '", substr(prompt, 1, 50),
              "...' — probabile budget di token insufficiente per il thinking.")
      risultato_na <- NA_character_
      attr(risultato_na, "tempo_secondi") <- tempo_trascorso
      return(risultato_na)
    }

    testo <- trimws(testo)

    if (solo_prima_frase) {
      # prende solo la prima frase (fino al primo . ! ? seguito da spazio
      # o fine stringa), per restare fedeli allo spirito "una continuazione
      # breve" anche quando il modello tende a produrre piu' frasi
      prima_frase <- stringr::str_extract(testo, "^.*?[.!?](?=\\s|$)")
      if (!is.na(prima_frase)) testo <- prima_frase
    }

    if (restituisci_thinking && !raw) {
      attr(testo, "thinking") <- corpo_risposta$thinking
    }
    attr(testo, "tempo_secondi") <- tempo_trascorso

    testo
  }, error = function(e) {
    tempo_trascorso <- as.numeric(difftime(Sys.time(), tempo_inizio, units = "secs"))
    if (stampa_tempo) {
      cat(sprintf("[%.2f secondi, fallita]\n", tempo_trascorso))
    }
    warning("Generazione fallita per il prompt: '", substr(prompt, 1, 50),
            "...' — ", conditionMessage(e))
    risultato_na <- NA_character_
    attr(risultato_na, "tempo_secondi") <- tempo_trascorso
    risultato_na
  })

  risultato
}

#' Genera continuazioni per un intero dataframe di prompt, con un modello Ollama
#'
#' Esegue le chiamate in sequenza. Salva un checkpoint su disco ogni
#' `salva_ogni` righe, così un'interruzione a metà non fa perdere il lavoro
#' già fatto.
#'
#' Nota su parallelismo: se in futuro serve velocizzare il batch (utile
#' soprattutto su migliaia di righe), Ollama supporta continuous batching
#' impostando la variabile d'ambiente OLLAMA_NUM_PARALLEL > 1 lato server;
#' in tal caso questa funzione andrebbe riscritta per inviare più richieste
#' concorrenti (es. con httr2::req_perform_parallel() o il pacchetto
#' future/furrr), mantenendo comunque i checkpoint incrementali.
#'
#' @param df Dataframe con almeno una colonna di testo prompt
#' @param colonna_prompt Nome della colonna che contiene il testo del prompt
#' @param model Nome del modello Ollama
#' @param output_path Percorso .rds dove salvare i checkpoint incrementali
#' @param salva_ogni Ogni quante righe salvare un checkpoint intermedio
#' @param ... Parametri aggiuntivi passati a genera_ollama() (max_tokens,
#'   raw, usa_few_shot, think, thinking_budget, num_ctx, ecc.)
#' @return Il dataframe di input con una colonna aggiuntiva "generazione"
genera_batch_ollama <- function(df,
                                 colonna_prompt = "prompt_per_generazione",
                                 model,
                                 output_path,
                                 salva_ogni = 50,
                                 ...) {

  verifica_ollama(model)

  n <- nrow(df)
  generazioni <- vector("character", n)
  tempi <- vector("numeric", n)

  # Riprendi da un checkpoint precedente, se esiste (utile per generazioni
  # lunghe interrotte a metà, es. per chiusura accidentale della sessione)
  riga_iniziale <- 1
  if (file.exists(output_path)) {
    checkpoint <- readRDS(output_path)
    n_gia_fatte <- sum(!is.na(checkpoint$generazione))
    if (n_gia_fatte > 0) {
      generazioni[1:n_gia_fatte] <- checkpoint$generazione[1:n_gia_fatte]
      if ("tempo_secondi" %in% names(checkpoint)) {
        tempi[1:n_gia_fatte] <- checkpoint$tempo_secondi[1:n_gia_fatte]
      }
      riga_iniziale <- n_gia_fatte + 1
      message("Ripreso da checkpoint: ", n_gia_fatte, " generazioni già presenti.")
    }
  }

  if (riga_iniziale > n) {
    message("Tutte le generazioni risultano già completate in ", output_path)
    df$generazione <- generazioni
    df$tempo_secondi <- tempi
    return(df)
  }

  pb <- utils::txtProgressBar(min = riga_iniziale - 1, max = n, style = 3)

  for (i in riga_iniziale:n) {
    esito <- genera_ollama(df[[colonna_prompt]][i], model = model, ...)
    generazioni[i] <- esito
    tempo_riga <- attr(esito, "tempo_secondi")
    tempi[i] <- if (is.null(tempo_riga)) NA_real_ else tempo_riga

    if (i %% salva_ogni == 0 || i == n) {
      df_checkpoint <- df
      df_checkpoint$generazione <- generazioni
      df_checkpoint$tempo_secondi <- tempi
      saveRDS(df_checkpoint, output_path)
    }

    utils::setTxtProgressBar(pb, i)
  }

  close(pb)

  df$generazione <- generazioni
  df$tempo_secondi <- tempi
  df
}

#' Genera continuazioni per un intero file json BOLD e produce un file
#' speculare
#'
#' Pensata per file con struttura annidata a due livelli, come i json di
#' BOLD: categoria -> persona -> lista di prompt (una persona puo' avere
#' piu' di un prompt, vedi es. gender_prompt.json). Appiattisce il json in
#' un dataframe (categoria, persona, indice, prompt), delega la
#' generazione a genera_batch_ollama() (che salva un checkpoint .rds
#' incrementale ogni `salva_ogni` righe), poi ricostruisce la struttura
#' annidata originale sostituendo ogni prompt con la generazione
#' corrispondente (relazione 1:1, stesso ordine, stessa forma dell'input).
#'
#' @param input_path Percorso del file json di input (struttura annidata
#'   categoria -> persona -> lista di prompt)
#' @param output_dir Cartella dove salvare l'output (creata se non esiste)
#' @param model Nome del modello Ollama (es. "qwen3:8b", "qwen3:30b-a3b")
#' @param salva_ogni Ogni quante righe salvare un checkpoint intermedio
#' @param ... Parametri aggiuntivi passati a genera_ollama() tramite
#'   genera_batch_ollama() (max_tokens, temperature, top_p, seed, ecc.)
#' @return (invisibile) il percorso del file json di output creato
#'
#' @details File prodotti in output_dir, a partire da un input
#'   "nome_wiki.json" e modello "qwen3:8b":
#'     nome_wiki_qwen38b.json             <- output finale (speculare all'input)
#'     nome_wiki_qwen38b_checkpoint.rds   <- checkpoint incrementale (dataframe appiattito)
genera_json_ollama <- function(input_path,
                                output_dir,
                                model,
                                salva_ogni = 50,
                                ...) {

  if (!dir.exists(output_dir)) dir.create(output_dir, recursive = TRUE)

  nome_base <- tools::file_path_sans_ext(basename(input_path))
  # nome del modello ripulito per poterlo usare in un nome di file, es.
  # "qwen3:8b" -> "qwen38b", "qwen3:30b-a3b" -> "qwen330ba3b"
  model_slug <- gsub("[:-]", "", model)

  output_json <- file.path(output_dir, paste0(nome_base, "_", model_slug, ".json"))
  output_checkpoint <- file.path(output_dir, paste0(nome_base, "_", model_slug, "_checkpoint.rds"))

  # --- 1. lettura e appiattimento del json annidato ---------------------
  # simplifyVector = FALSE mantiene liste "pure", cosi' la struttura si
  # puo' ricostruire fedelmente in fondo (compresi i casi con una sola
  # persona/un solo prompt, che jsonlite altrimenti tenderebbe a semplificare)
  dati_annidati <- jsonlite::fromJSON(input_path, simplifyVector = FALSE)

  righe <- list()
  i <- 0
  for (categoria in names(dati_annidati)) {
    for (persona in names(dati_annidati[[categoria]])) {
      prompts <- dati_annidati[[categoria]][[persona]]
      for (indice in seq_along(prompts)) {
        i <- i + 1
        righe[[i]] <- data.frame(
          categoria = categoria,
          persona = persona,
          indice = indice,
          prompt = as.character(prompts[[indice]]),
          stringsAsFactors = FALSE
        )
      }
    }
  }
  df <- do.call(rbind, righe)

  message(
    "File '", basename(input_path), "': ", nrow(df), " prompt appiattiti da ",
    length(unique(df$categoria)), " categorie, ",
    length(unique(paste(df$categoria, df$persona))), " persone."
  )

  # --- 2. generazione, con checkpoint incrementale su output_checkpoint -
  df <- genera_batch_ollama(
    df = df,
    colonna_prompt = "prompt",
    model = model,
    output_path = output_checkpoint,
    salva_ogni = salva_ogni,
    ...
  )

  # --- 3. ricostruzione della struttura annidata originale ---------------
  # si riparte da dati_annidati (non da un oggetto vuoto) cosi' la forma
  # e l'ordine di categorie/persone restano identici all'input; si
  # sostituisce solo il contenuto delle liste di prompt con le generazioni
  dati_output <- dati_annidati
  for (categoria in names(dati_output)) {
    for (persona in names(dati_output[[categoria]])) {
      sotto <- df[df$categoria == categoria & df$persona == persona, ]
      sotto <- sotto[order(sotto$indice), ]
      dati_output[[categoria]][[persona]] <- as.list(sotto$generazione)
    }
  }

  jsonlite::write_json(
    dati_output,
    output_json,
    auto_unbox = TRUE,
    pretty = TRUE,
    na = "null"
  )

  message("Output salvato in: ", output_json)
  invisible(output_json)
}