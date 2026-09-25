"""Conservative English sentence-boundary heuristic on prompt + continuation.

Uses lookahead during decoding so a just-generated period is not mistaken
for part of a decimal/abbreviation. Raw generated text is always retained.
No claim of perfect linguistic sentence segmentation.
"""
import re

POLICY = "english_sentence_v1"
ABBREVIATIONS = frozenset("mr mrs ms dr prof rev hon st sr jr gen lt col capt sgt sen rep gov vs etc fig eq vol no pp ed inc ltd corp co dept approx est jan feb mar apr jun jul aug sep sept oct nov dec".split())
CLOSERS = "\"'\u2019\u201d)]}"


def sentence_end(prompt, continuation, final=False):
    """Return exclusive character offset in continuation, or None.

    Ignore boundaries wholly inside the prompt. Abbreviations, initials,
    acronyms, decimal dots and ellipses do not trigger a stop. This favours
    missing some boundaries over cutting names/numbers. Final punctuation
    without lookahead is accepted only at EOS/token cap (final=True).
    """
    text = prompt + continuation
    offset = len(prompt)
    for match in re.finditer(r"[.!?]", text):
        i = match.start()
        if i < offset:
            continue
        if text[i] == ".":
            if (i and text[i - 1] == ".") or (i + 1 < len(text) and text[i + 1] == "."):
                continue
            if i and i + 1 < len(text) and text[i - 1].isdigit() and text[i + 1].isdigit():
                continue
            prefix = text[:i]
            word = re.search(r"([A-Za-z]+)$", prefix)
            if word and (word[1].casefold() in ABBREVIATIONS or
                         (len(word[1]) == 1 and word[1].isupper())):
                continue
            if re.search(r"(?:\b[A-Za-z]\.)+[A-Za-z]$", prefix):
                continue
        end = i + 1
        while end < len(text) and (text[end] in CLOSERS or text[end] in "!?"):
            end += 1
        # No boundary within a word/URL such as example.com.
        if end < len(text) and not text[end].isspace():
            continue
        if not final and not text[end:].strip():
            continue
        return end - offset
    return None


def trim_sentence(prompt, raw):
    end = sentence_end(prompt, raw, final=True)
    return (raw if end is None else raw[:end]), end


def make_sentence_stopper(tokenizer, prompts, input_length, torch, stopping_base):
    """Per-sequence stopping: completed batch members do not stop the others."""
    class SentenceStopper(stopping_base):
        def __init__(self):
            self.stop_lengths = [None] * len(prompts)

        def __call__(self, input_ids, scores, **kwargs):
            if len(input_ids) != len(prompts):
                raise ValueError("Sentence stopping requires one output sequence per prompt")
            done = []
            for i, prompt in enumerate(prompts):
                if self.stop_lengths[i] is None:
                    ids = input_ids[i, input_length:]
                    raw = tokenizer.decode(ids.tolist(), skip_special_tokens=True,
                                           clean_up_tokenization_spaces=False)
                    if sentence_end(prompt, raw) is not None:
                        self.stop_lengths[i] = len(ids)
                done.append(self.stop_lengths[i] is not None)
            return torch.tensor(done, dtype=torch.bool, device=input_ids.device)
    return SentenceStopper()
