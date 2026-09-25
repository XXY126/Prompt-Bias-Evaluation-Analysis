import platform
import shutil
import subprocess
import sys
from importlib.metadata import PackageNotFoundError, version
from pathlib import Path

import torch


def print_section(title):
    print(f"\n{'=' * 60}")
    print(title)
    print("=" * 60)


def check_package(package):
    try:
        print(f"{package:<20} {version(package)}")
        return True
    except PackageNotFoundError:
        print(f"{package:<20} NOT INSTALLED")
        return False


# --------------------------------------------------
# 1. System
# --------------------------------------------------

print_section("SYSTEM")

print(f"OS:              {platform.system()} {platform.release()}")
print(f"Architecture:    {platform.machine()}")
print(f"Python:          {platform.python_version()}")
print(f"Executable:      {sys.executable}")


# --------------------------------------------------
# 2. Python dependencies
# --------------------------------------------------

print_section("PYTHON PACKAGES")

required_packages = [
    "torch",
    "transformers",
    "accelerate",
    "bitsandbytes",
    "huggingface-hub",
    "pyyaml",
    "pandas",
    "pyarrow",
]

packages_ok = True

for package in required_packages:
    packages_ok &= check_package(package)


# --------------------------------------------------
# 3. CUDA / GPU
# --------------------------------------------------

print_section("GPU / CUDA")

cuda_available = torch.cuda.is_available()

print(f"CUDA available:  {cuda_available}")
print(f"PyTorch CUDA:    {torch.version.cuda}")

if cuda_available:

    device = torch.cuda.current_device()
    properties = torch.cuda.get_device_properties(device)

    total_vram = properties.total_memory / 1024**3

    free_vram, total_vram_runtime = torch.cuda.mem_get_info()
    free_vram /= 1024**3
    total_vram_runtime /= 1024**3

    print(f"GPU:             {properties.name}")
    print(f"Compute cap.:    {properties.major}.{properties.minor}")
    print(f"VRAM total:      {total_vram:.2f} GB")
    print(f"VRAM free:       {free_vram:.2f} GB")

    if hasattr(torch.cuda, "is_bf16_supported"):
        print(f"BF16 supported:  {torch.cuda.is_bf16_supported()}")

else:
    print("WARNING: PyTorch cannot access an NVIDIA GPU.")


# --------------------------------------------------
# 4. NVIDIA driver
# --------------------------------------------------

print_section("NVIDIA DRIVER")

try:
    result = subprocess.run(
        [
            "nvidia-smi",
            "--query-gpu=name,driver_version,memory.total,memory.free",
            "--format=csv,noheader"
        ],
        capture_output=True,
        text=True,
        check=True,
    )

    print(result.stdout.strip())

except (FileNotFoundError, subprocess.CalledProcessError):
    print("nvidia-smi not available.")


# --------------------------------------------------
# 5. Disk space
# --------------------------------------------------

print_section("DISK")

repo_root = Path(__file__).resolve().parent.parent

total, used, free = shutil.disk_usage(repo_root)

print(f"Repository:      {repo_root}")
print(f"Free disk:       {free / 1024**3:.2f} GB")


# --------------------------------------------------
# 6. Project structure
# --------------------------------------------------

print_section("PROJECT")

expected_paths = [
    repo_root / "configs",
    repo_root / "data",
    repo_root / "models",
]

for path in expected_paths:
    status = "OK" if path.exists() else "MISSING"
    print(f"{str(path.relative_to(repo_root)):<20} {status}")


# --------------------------------------------------
# Summary
# --------------------------------------------------

print_section("SUMMARY")

if packages_ok and cuda_available:
    print("Environment looks ready for model experiments.")
else:
    print("Environment has missing requirements. Check the messages above.")