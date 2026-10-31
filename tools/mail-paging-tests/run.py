#!/usr/bin/env python3
"""Run persistent Mail paging and basic search correctness checks. This does not certify UI latency."""
import argparse
import json
from pathlib import Path
import subprocess

REQUIRED = {
    'BananaTests/MailSessionTests/testHistoryNavigationReachesBeyondCapWithoutRetainingOldModels',
    'BananaTests/MailSessionTests/testHistorySearchAndFilterChangesResetTheWindow',
    'BananaUITests/ScaleStressUITests/testMailHistoryNavigationCrossesTwoThousandRowsAndOpens',
    'BananaTests/MailSessionTests/testPaneDelayedReadCarriesTheDisplayedArrivalBoundary',
    'BananaTests/MailSessionTests/testLiveCapabilitiesAllowTriageWithoutOpeningComposerOrSnoozing',
    'BananaTests/MailSessionTests/testAccountRestrictionPreventsOptimisticAndDelayedReadChanges',
    'BananaTests/MailSessionTests/testFailedUndoCanBeRetriedWithoutLosingOriginalEntry',
    'BananaTests/MailSessionTests/testNoOpWithdrawsItsToastAndCannotUndoPreviousAction',
    'BananaTests/MailUndoStackTests/testFailedUndoRestoresOriginalPositionBehindNewActions',
    'BananaTests/ToastCenterTests/testScopedDismissCannotCloseANewerToast',
    'BananaTests/MailListModelTests/testActionCarriesTheDisplayedRowsArrivalBoundary',
    'BananaTests/MailSessionTests/testSynchronousFailureWaitsForReceiptBeforeRestoring',
    'BananaTests/MailSessionTests/testUnsavedActionRestoresItsRowAndRemovesUndo',
    'BananaTests/MailSessionTests/testRefusalAfterChangingPlaceDoesNotNavigateBack',
    'BananaTests/MailSessionTests/testRefusalRetryDoesNotUndoAnEarlierAction',
    'BananaTests/MailSessionTests/testLateActionCountUpdatesUndoAndZeroRemovesIt',
    'BananaTests/MailSessionTests/testScrollingToLoadedBoundaryRequestsAndReceivesMoreRows',
    'BananaTests/MailSessionTests/testGrowthKeepsOldObservationUntilReplacementArrives',
    'BananaTests/MailSessionTests/testLeavingWhileGrowthIsPendingCancelsBothObservations',
    'BananaUITests/ScaleStressUITests/testMailScrollLoadsOlderThanFirstPage',
    'BananaUITests/ScaleStressUITests/testMailScrollAndOpen',
    'BananaUITests/ScaleStressUITests/testMailRemovalReviewPagesKeepsAndPersists',
    'BananaUITests/ScaleStressUITests/testMailSearchFindsRetainedConversationAndClears',
    'BananaUITests/ScaleStressUITests/testCalendarSearchEntryAndDismissal',
}

def cases(node):
    if isinstance(node, dict):
        if node.get('nodeType') == 'Test Case':
            yield node
        for child in node.values():
            yield from cases(child)
    elif isinstance(node, list):
        for child in node:
            yield from cases(child)

def validate(results, device):
    found = set()
    failures = []
    for summary, tree in results:
        if summary.get('result') != 'Passed' or summary.get('failedTests') != 0 or summary.get('skippedTests') != 0:
            failures.append('A result failed, skipped tests, or did not complete')
        if summary.get('runtimeWarnings'):
            failures.append('Runtime warnings were recorded')
        devices = {x.get('device', {}).get('deviceId') for x in summary.get('devicesAndConfigurations', [])}
        if devices != {device}:
            failures.append('Unexpected or missing test device')
        for case in cases(tree):
            key = '/'.join(case.get('nodeIdentifierURL', '').split('/')[-3:])
            if case.get('result') == 'Passed':
                found.add(key)
    missing = sorted(REQUIRED - found)
    if missing:
        failures.append('Required passing cases missing: ' + ', '.join(missing))
    return {'status': 'fail' if failures else 'pass', 'scope': 'Mail paging and initial search UI correctness, not live provider or UI latency acceptance',
            'device': device, 'requiredCases': sorted(REQUIRED), 'failures': failures}

def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--out', type=Path, required=True)
    p.add_argument('--device', required=True)
    p.add_argument('--derived-data', type=Path, default=Path('.build/stress-dd'))
    p.add_argument('--verify-results', nargs='+', type=Path, help='Verify existing xcresults without building or launching')
    a = p.parse_args()
    a.out.mkdir(parents=True, exist_ok=False)
    bundles = a.verify_results
    command_exit = 0
    if not bundles:
        if subprocess.run(['pgrep', '-x', 'xcodebuild'], capture_output=True).returncode == 0:
            (a.out / 'gate.json').write_text(json.dumps({'status': 'unmeasured', 'reason': 'Another Xcode job is active'}))
            return 2
        bundle = a.out / 'tests.xcresult'
        cmd = ['xcodebuild', '-project', 'Banana.xcodeproj', '-scheme', 'Banana', '-configuration', 'Release',
               '-destination', f'platform=iOS Simulator,id={a.device},arch=arm64', 'ARCHS=arm64', 'ONLY_ACTIVE_ARCH=YES',
               'BANANA_UNRELEASED=YES',  # This audit intentionally exercises the separate Beta module.
               'SWIFT_ACTIVE_COMPILATION_CONDITIONS=$(inherited) DEBUG', '-derivedDataPath', str(a.derived_data),
               'CODE_SIGNING_ALLOWED=NO', '-parallel-testing-enabled', 'NO', '-collect-test-diagnostics', 'never',
               '-only-testing:BananaTests/MailSessionTests', '-only-testing:BananaTests/MailListModelTests',
               '-only-testing:BananaTests/MailUndoStackTests/testFailedUndoRestoresOriginalPositionBehindNewActions',
               '-only-testing:BananaTests/ToastCenterTests/testScopedDismissCannotCloseANewerToast',
               '-only-testing:BananaUITests/ScaleStressUITests/testMailScrollLoadsOlderThanFirstPage',
               '-only-testing:BananaUITests/ScaleStressUITests/testMailHistoryNavigationCrossesTwoThousandRowsAndOpens',
               '-only-testing:BananaUITests/ScaleStressUITests/testMailScrollAndOpen',
               '-only-testing:BananaUITests/ScaleStressUITests/testMailRemovalReviewPagesKeepsAndPersists',
               '-only-testing:BananaUITests/ScaleStressUITests/testMailSearchFindsRetainedConversationAndClears',
               '-only-testing:BananaUITests/ScaleStressUITests/testCalendarSearchEntryAndDismissal',
               '-resultBundlePath', str(bundle), '-quiet', 'test']
        with (a.out / 'xcode.log').open('w') as f:
            generation = subprocess.run(['xcodegen', 'generate'], stdout=f, stderr=subprocess.STDOUT)
            if generation.returncode:
                (a.out / 'gate.json').write_text(json.dumps({'status': 'unmeasured', 'reason': 'Project generation failed', 'exit': generation.returncode}))
                return 2
            r = subprocess.run(cmd, stdout=f, stderr=subprocess.STDOUT)
        command_exit = r.returncode
        (a.out / 'command.json').write_text(json.dumps({'command': cmd, 'exit': r.returncode}, indent=2))
        bundles = [bundle]
    results = []
    try:
        for index, bundle in enumerate(bundles):
            values = []
            for kind in ['summary', 'tests']:
                r = subprocess.run(['xcrun', 'xcresulttool', 'get', 'test-results', kind, '--path', str(bundle)],
                                   capture_output=True, text=True, check=True)
                (a.out / f'{index}-{kind}.json').write_text(r.stdout)
                values.append(json.loads(r.stdout))
            results.append(values)
        verdict = validate(results, a.device)
        if command_exit:
            verdict['status'] = 'fail'
            verdict['failures'].append(f'xcodebuild exited {command_exit}')
    except (subprocess.CalledProcessError, ValueError) as error:
        verdict = {'status': 'unmeasured', 'error': str(error)}
    verdict['resultPaths'] = [str(b.resolve()) for b in bundles]
    (a.out / 'gate.json').write_text(json.dumps(verdict, indent=2))
    print(json.dumps(verdict))
    return {'pass': 0, 'fail': 1, 'unmeasured': 2}[verdict['status']]

if __name__ == '__main__':
    raise SystemExit(main())
