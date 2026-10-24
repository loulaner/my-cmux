"""Retire only iOS viewing-lease publication; retain discovery and lifecycle."""
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SHELL = ROOT / 'Packages/iOS/CmuxMobileShell'
SOURCE = SHELL / 'Sources/CmuxMobileShell'


class WorkspacePresencePublisherRemovedTests(unittest.TestCase):
    def test_exclusive_publisher_and_dependencies_are_absent(self):
        for name in ('MobileWorkspacePresenceAnnouncer.swift', 'WorkspacePresenceAnnouncing.swift',
                     'MobileShellComposite+WorkspacePresence.swift'):
            self.assertFalse((SOURCE / name).exists(), name)
        for name in ('MobileWorkspacePresenceAnnouncerTests.swift', 'MobilePresenceRecordingTransport.swift'):
            self.assertFalse((SHELL / 'Tests/CmuxMobileShellTests' / name).exists(), name)
        self.assertNotIn('CmuxWorkspacePresence', (SHELL / 'Package.swift').read_text())
        for path in SOURCE.glob('*.swift'):
            for symbol in ('WorkspacePresenceAnnouncing', 'MobileWorkspacePresenceAnnouncer',
                           'workspacePresenceAnnouncer', 'announceWorkspaceScopeForSelection',
                           'clearWorkspacePresenceScope', 'setWorkspaceViewing'):
                self.assertNotIn(symbol, path.read_text(), str(path))

    def test_selection_and_discovery_remain(self):
        shell = (SOURCE / 'MobileShellComposite.swift').read_text()
        selection = shell.split('public var selectedWorkspaceID:', 1)[1].split('\n    }', 1)[0]
        self.assertIn('pendingLastTabRestoreWorkspaceID = selectedWorkspaceID', selection)
        self.assertIn('syncSelectedTerminalForWorkspace()', selection)
        subscription = shell.split('func evaluateDirectoryObservation()', 1)[1].split('\n    }', 1)[0]
        for text in ('if isSignedIn, let discovery = personalIrohDiscovery', 'discovery.directoryUpdates()',
                     'directoryObservationTask?.cancel()'):
            self.assertIn(text, subscription)
        self.assertTrue((ROOT / 'Packages/Shared/CmuxWorkspacePresence/Package.swift').is_file())

    def test_foreground_guards_and_refresh_cancel_remain(self):
        routes = (SOURCE / 'MobileShellComposite+ReconnectRoutes.swift').read_text()
        resume = routes.split('public func resumeForegroundRefresh()', 1)[1].split('\n    }', 1)[0]
        suspend = routes.split('public func suspendForegroundRefresh()', 1)[1].split('\n    }', 1)[0]
        for text in ('guard foregroundRefreshLifecycleState != .active else { return }',
                     'foregroundResumeEpoch &+= 1', 'evaluateDirectoryObservation()',
                     'startObservingNetworkPathChanges()', 'recoverForegroundConnectionIfNeeded',
                     'resumeSecondaryControlMaintenanceAfterForeground()'):
            self.assertIn(text, resume)
        for text in ('guard foregroundRefreshLifecycleState != .background else { return }',
                     'connectionRecoveryOwner.cancelProbing()', 'suspendSecondaryConnectionEstablishmentForBackground()',
                     'guard lastBackgroundedAt == nil else { return }', 'runtime?.now() ?? Date()'):
            self.assertIn(text, suspend)


if __name__ == '__main__':
    unittest.main()
