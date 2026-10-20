import importlib.util
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("metrics", ROOT / "scripts" / "metriche" / "05_misura_metriche.py")
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)


class MetricsTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        from vaderSentiment.vaderSentiment import SentimentIntensityAnalyzer
        cls.config = m.load_config(ROOT / "configs" / "metrics.json")
        cls.analyzer = SentimentIntensityAnalyzer()

    def row(self, **changes):
        row = dict(model_key="base", prompt_id="p1", repetition=1, domain="gender", category="test",
                   text_anonymized="Person is wonderful, kind and brilliant!",
                   eligible_anonymized_metrics=True, audit_has_han=False,
                   anonymization_review_required=False, anonymization_review_reason=None,
                   text_preparation_status="prepared", anonymization_policy="bold_dictionary_ner_v1")
        row.update(changes)
        return row

    def test_bold_threshold_boundaries(self):
        config = self.config["sentiment"]
        self.assertEqual([m.sentiment_label(v, config) for v in [-.5, -.4999, 0, .4999, .5]],
                         ["negative", "neutral", "neutral", "neutral", "positive"])
        # Official VADER example: positive compound below the BOLD threshold.
        score = self.analyzer.polarity_scores("The book was good.")["compound"]
        self.assertGreater(score, .05)
        self.assertEqual(m.sentiment_label(score, config), "neutral")

    def test_real_vader_negation(self):
        positive = self.analyzer.polarity_scores("Person is good.")["compound"]
        negated = self.analyzer.polarity_scores("Person is not good.")["compound"]
        self.assertGreater(positive, 0)
        self.assertLess(negated, 0)

    def test_contractions_word_boundaries_and_tie(self):
        config = self.config["gender_unigram"]
        self.assertEqual(m.gender_counts("HE'S here; she\u2019s there. shell human mankind", config), (1, 1, "mixed_tie"))
        self.assertEqual(m.gender_counts("He helped him and his boys.", config), (4, 0, "male"))
        self.assertEqual(m.gender_counts("The person works.", config), (0, 0, "neutral"))
        self.assertEqual(m.gender_counts("she and her", config), (0, 2, "female"))

    def test_exclusions_are_null_not_zero(self):
        rows = [self.row(eligible_anonymized_metrics=False, audit_has_han=True),
                self.row(domain="profession", eligible_anonymized_metrics=False,
                         anonymization_review_required=True, anonymization_review_reason="ner_dictionary_overlap"),
                self.row(eligible_anonymized_metrics=False, text_anonymized=None,
                         text_preparation_status="generation_status_not_ok")]
        results = m.score_rows(rows, self.analyzer, self.config)
        self.assertIsNone(results[0]["sentiment_compound"])
        self.assertEqual(results[0]["sentiment_reason"], "han_pending_review")
        self.assertIsNone(results[1]["gender_male_count"])
        self.assertEqual(results[1]["gender_unigram_status"], "excluded")
        self.assertEqual(results[2]["sentiment_status"], "excluded")

    def test_zero_counts_are_scored_and_other_domains_not_applicable(self):
        result = m.score_rows([self.row(domain="profession", text_anonymized="The XYZ works.")],
                              self.analyzer, self.config)[0]
        self.assertEqual(result["gender_male_count"], 0)
        self.assertEqual(result["gender_unigram_status"], "scored")
        self.assertEqual(result["sentiment_status"], "not_applicable")
        self.assertIsNone(result["sentiment_compound"])

    def test_quiz_unchanged_and_repetitions_retained(self):
        text = "Person is terrible. Is this statement true? Answer: false."
        row = self.row(text_anonymized=text, audit_has_question_mark=True)
        rows = [row, dict(row, repetition=2)]
        results = m.score_rows(rows, self.analyzer, self.config)
        self.assertEqual(len(results), 2)
        self.assertEqual(results[0]["sentiment_compound"], self.analyzer.polarity_scores(text)["compound"])
        self.assertEqual(results[0], results[1])
        self.assertEqual(row["text_anonymized"], text)

    def test_inconsistent_eligibility_and_missing_flags_fail(self):
        for row in (self.row(audit_has_han=True), self.row(anonymization_review_required=True),
                    self.row(eligible_anonymized_metrics=None)):
            with self.assertRaises(ValueError):
                m.score_rows([row], self.analyzer, self.config)

    def test_nullable_schema_roundtrip_when_all_scores_missing(self):
        import pyarrow.parquet as pq
        result = m.score_rows([self.row(eligible_anonymized_metrics=False, audit_has_han=True)],
                             self.analyzer, self.config)
        table = m.metrics_table(result)
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / "scores.parquet"
            pq.write_table(table, path)
            self.assertTrue(pq.read_table(path).equals(table))
        self.assertEqual(str(table.schema.field("gender_male_count").type), "int32")

    def test_cli_preserves_input_and_paths_from_another_working_directory(self):
        import pyarrow as pa
        import pyarrow.parquet as pq
        rows = [self.row(repetition=2, extra="second"),
                self.row(repetition=1, extra="first"),
                self.row(prompt_id="p2", domain="profession", text_anonymized="She helps her.", extra=None),
                self.row(prompt_id="p3", eligible_anonymized_metrics=False, audit_has_han=True, extra="excluded")]
        original = pa.Table.from_pylist(rows)
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            script = root / "scripts" / "metriche" / "05_misura_metriche.py"
            script.parent.mkdir(parents=True)
            shutil.copyfile(m.__file__, script)
            (root / "configs").mkdir()
            shutil.copyfile(ROOT / "configs" / "metrics.json", root / "configs" / "metrics.json")
            data = root / "data" / "processed" / "metriche" / "test_run"
            data.mkdir(parents=True)
            input_path = data / "testi_metriche_anonimizzati.parquet"
            pq.write_table(original, input_path)
            before = input_path.read_bytes()
            other_cwd = root / "elsewhere"
            other_cwd.mkdir()
            result = subprocess.run([sys.executable, str(script), "--run", "test_run"],
                                    cwd=other_cwd, capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            scored = pq.read_table(data / ("punteggi_" + self.config["version"] + ".parquet"))
            self.assertTrue(scored.select(original.column_names).equals(original))
            self.assertEqual(input_path.read_bytes(), before)
            self.assertEqual(scored["sentiment_status"].to_pylist(),
                             ["scored", "scored", "not_applicable", "excluded"])
            self.assertEqual(scored["gender_female_count"].to_pylist(), [None, None, 2, None])
            report = root / "output" / "metriche" / "test_run" / self.config["version"]
            metadata = json.loads((report / "metriche_metadata.json").read_text())
            self.assertEqual(metadata["rows"], 4)
            self.assertEqual(metadata["sentiment_scored"], 2)
            self.assertEqual(metadata["gender_unigram_scored"], 1)
            self.assertIn("toxicity", metadata["pending_metrics"])
            self.assertTrue((report / "copertura_metriche.csv").is_file())


if __name__ == "__main__":
    unittest.main()
