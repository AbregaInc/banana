#!/usr/bin/env python3
"""Exercise the production history/copy and atomic persistence code without accounts or a GUI."""
from pathlib import Path
import subprocess,tempfile
root=Path(__file__).resolve().parents[2]
with tempfile.TemporaryDirectory(prefix='banana-recent-meals-tests-') as directory:
    binary=Path(directory)/'checks'
    sources=['Shared/SnapshotPersistence.swift','Shared/WellnessModels.swift','Banana/Model/NutritionDays.swift','Banana/Model/MealRepeatPersistence.swift','tools/recent-meals-tests/main.swift']
    subprocess.run(['swiftc','-O',*[str(root/s) for s in sources],'-o',str(binary)],check=True)
    subprocess.run([str(binary)],check=True)
