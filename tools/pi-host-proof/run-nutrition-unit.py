#!/usr/bin/env python3
"""Run the native query tests without booting a simulator; discard the compile output."""
import pathlib
import subprocess

repo = pathlib.Path(__file__).resolve().parents[2]
build = repo / '.build/mac-check'
build.mkdir(parents=True, exist_ok=True)
try:
    main = build / 'main.swift'
    main.write_text('import XCTest\nimport Foundation\nlet suite = XCTestSuite(name: "Pi native queries, sample meals and inference transport")\nsuite.addTest(XCTestSuite(forTestCaseClass: AssistantNutritionTests.self))\nsuite.addTest(XCTestSuite(forTestCaseClass: PiSampleMealsTests.self))\nsuite.addTest(XCTestSuite(forTestCaseClass: LocalInferenceTransportTests.self))\nsuite.addTest(XCTestSuite(forTestCaseClass: AssistantCalendarIdentityTests.self))\nsuite.run()\nguard let result = suite.testRun, result.executionCount == 24, result.failureCount == 0 else { exit(1) }\n')
    sources = ['Shared/SnapshotPersistence.swift', 'Shared/WellnessModels.swift',
               'Banana/Pi/AssistantFailure.swift', 'Banana/Pi/AssistantNutrition.swift',
               'Banana/Pi/PiSampleMeals.swift', 'Banana/Pi/AssistantCalendarIdentity.swift', 'BananaTests/AssistantCalendarIdentityTests.swift', 'Banana/Pi/LocalInferenceTransport.swift', 'BananaTests/LocalInferenceTransportTests.swift', 'BananaTests/AssistantNutritionTests.swift', 'BananaTests/PiSampleMealsTests.swift', str(main)]
    executable = build / 'nutrition-tests'
    platform = pathlib.Path(subprocess.check_output(['xcrun', '--sdk', 'macosx', '--show-sdk-platform-path'], text=True).strip())
    frameworks = platform / 'Developer/Library/Frameworks'
    subprocess.run(['swiftc', '-D', 'BANANA_AI', '-I', str(platform / 'Developer/usr/lib'), '-F', str(frameworks), '-L', str(platform / 'Developer/usr/lib'), '-lXCTestSwiftSupport', '-framework', 'XCTest', '-Xlinker', '-rpath', '-Xlinker', str(platform / 'Developer/usr/lib'), '-Xlinker', '-rpath', '-Xlinker', str(frameworks),
                    *sources, '-o', str(executable)], cwd=repo, check=True)
    subprocess.run([str(executable)], cwd=repo, check=True)
finally:
    # Keep the shared Mac app build (and installed symbols); remove only this check's files.
    (build / 'main.swift').unlink(missing_ok=True)
    (build / 'nutrition-tests').unlink(missing_ok=True)
    try: build.rmdir()
    except OSError: pass
