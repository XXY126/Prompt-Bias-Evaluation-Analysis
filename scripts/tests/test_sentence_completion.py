import sys
from pathlib import Path
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from sentence_completion import sentence_end, trim_sentence, make_sentence_stopper


class SentenceTests(unittest.TestCase):
    def test_first_completion_and_original_spacing(self):
        raw = " a teacher. She lived elsewhere."
        text, end = trim_sentence("Person was", raw)
        self.assertEqual(text, " a teacher.")
        self.assertEqual(raw[:end], text)

    def test_abbreviation_initial_decimal_and_acronym(self):
        raw = " Dr. J. Brown in the U.S. for 3.5 years. Next"
        self.assertEqual(trim_sentence("She worked with", raw)[0],
                         " Dr. J. Brown in the U.S. for 3.5 years.")

    def test_partial_word_and_prompt_abbreviation(self):
        self.assertEqual(trim_sentence("She met Dr", ". Brown yesterday. Then")[0], ". Brown yesterday.")
        self.assertEqual(trim_sentence("This was un", "usual. Next")[0], "usual.")

    def test_streaming_waits_for_decimal_lookahead(self):
        self.assertIsNone(sentence_end("Cost: ", "3."))
        self.assertIsNone(sentence_end("Cost: ", "3.5"))
        self.assertIsNone(sentence_end("Cost: ", "3.5 dollars."))
        self.assertEqual(sentence_end("Cost: ", "3.5 dollars. Next"), len("3.5 dollars."))

    def test_closing_quotes_preserved(self):
        self.assertEqual(trim_sentence('She said, "', 'I agree." Next')[0], 'I agree."')

    def test_incomplete_and_question_not_disguised(self):
        self.assertEqual(trim_sentence("He was", " walking towards"), (" walking towards", None))
        self.assertEqual(trim_sentence("He was", " ready? Answer: yes.")[0], " ready?")

    def test_batch_stops_independently(self):
        import torch
        from transformers import StoppingCriteria
        class Tokenizer:
            def decode(self, ids, **kwargs):
                return "".join(chr(i) for i in ids)
        stopper = make_sentence_stopper(Tokenizer(), ["A", "B"], 1, torch, StoppingCriteria)
        # Equal token lengths, first row complete, second still running.
        ids = torch.tensor([[0] + list(map(ord, s)) for s in (" done. X", " waiting")])
        self.assertEqual(stopper(ids,None).tolist(), [True,False])
        self.assertEqual(stopper.stop_lengths, [8,None])
        ids = torch.tensor([[0] + list(map(ord, s)) for s in (" done. X     ", " waiting. X  ")])
        self.assertEqual(stopper(ids,None).tolist(), [True,True])
        self.assertEqual(stopper.stop_lengths, [8,13])


if __name__ == "__main__":
    unittest.main()
