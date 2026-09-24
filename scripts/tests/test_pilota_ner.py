"""Checks on replacement integrity, independent of a downloaded NER model."""
import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location("pilot", Path(__file__).parents[1] / "07c_pilota_ner.py")
pilot = importlib.util.module_from_spec(spec)
spec.loader.exec_module(pilot)


class PreviewTests(unittest.TestCase):
    def test_unicode_offsets_possessive_and_question_preserved(self):
        text = "漢 😀 José met Brown's friend. Was he wrong?"
        entities = [dict(entity=name, label="PERSON", start_char=text.index(name),
                         end_char=text.index(name) + len(name)) for name in ("José", "Brown")]
        self.assertEqual(pilot.person_preview(text, entities),
                         "漢 😀 Person met Person's friend. Was he wrong?")

    def test_other_labels_and_no_entities_preserve_original(self):
        text = "London is not a person."
        entity = dict(entity="London", label="GPE", start_char=0, end_char=6)
        self.assertEqual(pilot.person_preview(text, [entity]), text)
        self.assertEqual(pilot.person_preview(text, []), text)

    def test_inconsistent_span_is_rejected(self):
        with self.assertRaises(ValueError):
            pilot.person_preview("Alice", [dict(entity="Bob", label="PERSON", start_char=0, end_char=5)])

    def test_overlapping_spans_are_rejected(self):
        with self.assertRaises(ValueError):
            pilot.person_preview("Alice Smith", [
                dict(entity="Alice Smith", label="PERSON", start_char=0, end_char=11),
                dict(entity="Smith", label="PERSON", start_char=6, end_char=11)])


if __name__ == "__main__":
    unittest.main()
