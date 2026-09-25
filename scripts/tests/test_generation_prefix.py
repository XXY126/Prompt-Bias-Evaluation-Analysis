"""Test senza GPU: serializzazione input e identita' della configurazione."""
import importlib.util
from pathlib import Path
import sys
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))
spec = importlib.util.spec_from_file_location("generation_pipeline", ROOT / "scripts/05_generate_prompts.py")
pipeline = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = pipeline
spec.loader.exec_module(pipeline)


class PrefixTests(unittest.TestCase):
    def test_raw_preserves_text(self):
        for prompt in ("", "  The doctor", "A partial wor", "Name\t", "\u4f60\u597d"):
            self.assertEqual(pipeline.build_model_input(prompt, {"prompt_mode": "raw"}), prompt)

    def test_prefix_preserves_original_suffix(self):
        config = pipeline.load_yaml(ROOT / "configs/generation_english_prose.yaml")
        experiment = config["experiment"]
        prompt = "  The doctor worked as"
        text = pipeline.build_model_input(prompt, experiment)
        self.assertEqual(text, experiment["instruction_prefix"] + prompt)
        self.assertTrue(text.endswith("Text to continue:\n" + prompt))

    def test_invalid_modes_and_prefixes(self):
        for config in (
            {"prompt_mode": "chat"},
            {"prompt_mode": "raw", "instruction_prefix": "Instruction"},
            {"prompt_mode": "instruction_prefix", "instruction_prefix": "  "},
            {"prompt_mode": "instruction_prefix", "instruction_prefix": None},
        ):
            with self.assertRaises(ValueError):
                pipeline.build_model_input("Example", config)

    def test_prefix_changes_resume_signature(self):
        config = pipeline.load_yaml(ROOT / "configs/generation_english_prose.yaml")
        def signature():
            return pipeline.build_signature(
                "example", {"repo_id": "example"}, ROOT,
                config["experiment"], config["generation"], config["runtime"],
                config["quantization"], {}, "test_run", None,
            )
        with patch.object(pipeline, "model_manifest", return_value={}):
            first, payload = signature()
            self.assertEqual(payload["instruction_prefix"], config["experiment"]["instruction_prefix"])
            config["experiment"]["instruction_prefix"] += "Different instruction\n"
            second, _ = signature()
        self.assertNotEqual(first, second)


if __name__ == "__main__":
    unittest.main()
