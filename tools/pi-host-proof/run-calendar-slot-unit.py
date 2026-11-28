"""Compile the native composer interval decisions with a synthetic account-scoped calendar transport."""
from pathlib import Path
import subprocess
import tempfile

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]


def method(source, signature, next_member):
    start = source.index("    " + signature)
    end = source.index("    " + next_member, start + len(signature))
    return source[start:end]


with tempfile.TemporaryDirectory(prefix="banana-composer-slot-") as workspace:
    folder = Path(workspace)
    capabilities = (ROOT / "Banana/Pi/AssistantCapabilities.swift").read_text()
    slot = method(capabilities, "static func composerIntervalAvailable(", "private static func calendarBusy(")
    window = method(capabilities, "private static func calendarBusy(", "static func execute(")
    projection = folder / "CalendarMethods.swift"
    projection.write_text("import Foundation\nextension AssistantCapabilities {\n" + slot + window + "}\n")
    binary = folder / "composer-calendar-contracts"
    subprocess.run([ROOT / "tools/agents/xcode-lock.sh", "xcrun", "swiftc", "-D", "BANANA_AI",
                    ROOT / "Banana/Pi/AssistantFailure.swift", projection,
                    HERE / "calendar-slot-contracts/Proof.swift", "-o", binary], check=True)
    subprocess.run([binary], check=True)

with tempfile.TemporaryDirectory(prefix="banana-calendar-scope-") as workspace:
    folder = Path(workspace)
    provider = (ROOT / "Banana/Model/GoogleCalendarService.swift").read_text()
    scoped = method(provider, "private func composerWindowFetch(", "private func buildCalendarWindow(")
    # The private entry is called by the assertion harness in another Swift source file.
    scoped = scoped.replace("private func composerWindowFetch(", "func composerWindowFetch(", 1)
    projection = folder / "ScopedRead.swift"
    projection.write_text("import Foundation\nextension GoogleCalendarService {\n" + scoped + "}\n")
    binary = folder / "scoped-calendar-contracts"
    subprocess.run([ROOT / "tools/agents/xcode-lock.sh", "xcrun", "swiftc", projection,
                    HERE / "calendar-scope-contracts/Proof.swift", "-o", binary], check=True)
    subprocess.run([binary], check=True)
