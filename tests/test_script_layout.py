"""Regression checks for relocated scripts and historical checkpoint provenance."""
import ast
import hashlib
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[1]


class ScriptLayoutTests(unittest.TestCase):
    def test_literal_source_and_provenance_paths_exist(self):
        for folder in ("scripts", "R", "tests"):
            for path in (ROOT / folder).rglob("*.R"):
                for target in re.findall(r'["\']((?:scripts|R)/[^"\']+\.R)["\']', path.read_text()):
                    with self.subTest(script=str(path.relative_to(ROOT)), target=target):
                        self.assertTrue((ROOT / target).is_file())
                for directory, name in re.findall(
                    r'here(?:::here)?\("(R|scripts)",\s*"([^"\n]+\.R)"\)', path.read_text()
                ):
                    with self.subTest(script=str(path.relative_to(ROOT)), target=name):
                        self.assertTrue((ROOT / directory / name).is_file())

    def test_python_entrypoints_resolve_repository_root(self):
        # Evaluate only path expressions; setup scripts have download/GPU side effects.
        scripts = ["setup/verifica_ambiente.py", "generazione/genera.py",
                   "metriche/03_esegui_ner.py", "metriche/05_misura_metriche.py",
                   "esperimenti/pilota_ner.py"]
        for relative in scripts:
            path = ROOT / "scripts" / relative
            assignments = [node for node in ast.walk(ast.parse(path.read_text()))
                           if isinstance(node, ast.Assign) and any(
                               isinstance(target, ast.Name) and target.id in
                               ("root", "repo_root", "REPO_ROOT") for target in node.targets)]
            with self.subTest(script=relative):
                self.assertEqual(len(assignments), 1)
                value = eval(compile(ast.Expression(assignments[0].value), str(path), "eval"),
                             {"Path": Path, "__file__": str(path)})
                self.assertEqual(value, ROOT)

    def test_legacy_content_and_root_preserve_checkpoint_identity(self):
        path = ROOT / "legacy" / "05_generate_prompts_v2.py"
        self.assertEqual(hashlib.sha256(path.read_bytes()).hexdigest(),
                         "f4da1e3356c8e8463d3eb88d012dfe633c88daf612a3a23b3c0c03bf2e1941a4")
        self.assertEqual(path.resolve().parent.parent, ROOT)


if __name__ == "__main__":
    unittest.main()
