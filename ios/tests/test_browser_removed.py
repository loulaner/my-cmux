"""iOS browser product boundary; not device/SFTP or zero-live-traffic proof."""
import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
IOS = 'Packages/iOS'


class BrowserRemovalTests(unittest.TestCase):
    def test_packages_and_concrete_entrypoints_are_absent(self):
        for package in ('CmuxMobileBrowser', 'CmuxMobileBrowserStream', 'CmuxMobileTunnel'):
            path = ROOT / IOS / package
            self.assertFalse((path / 'Package.swift').exists())
            self.assertFalse(list((path / 'Sources').rglob('*.swift')))
            self.assertNotIn(package, (ROOT / 'cmux.xcworkspace/contents.xcworkspacedata').read_text())
            for manifest in [ROOT / 'ios/cmuxPackage/Package.swift', *(ROOT / IOS).glob('*/Package.swift')]:
                self.assertNotIn(package + '"', manifest.read_text(), str(manifest))

    def test_no_runtime_browser_producers_subscriptions_or_network_owners(self):
        forbidden = re.compile(
            r'mobile\.browser\.|"browser\.(?:frame|state|closed|dialog)|'
            r'\b(?:BrowserSurfaceStore|BrowserStreamStore|MobileBrowserPane|BrowserStreamPane|'
            r'activeBrowser|activeBrowserStream|browserStore|browserStreamStore|'
            r'SSHSocksProxy|SSHDirectTCPIPBackend|MobileMacBrowserNetwork|MobileTunnelLaneConnection|'
            r'tunnelConnectProvider|tunnelListeningPortsProvider|IrxTunnelClient|'
            r'pendingLocalBrowserTabRestoreWorkspaceID|attachBrowser|'
            r'MobileSSHAttachedBrowser|MobileSSHBrowserProviding)\b|'
            r'"browser-(?:navigate|back|forward|reload|mouse-guarded|wheel-guarded|'
            r'frame-presented|key-press|insert-text|pointer-frame-guard-v1)"'
        )
        roots = [ROOT / 'ios/cmuxPackage/Sources', ROOT / 'ios/cmux', *(ROOT / IOS).glob('*/Sources')]
        for root in roots:
            for path in root.rglob('*.swift'):
                self.assertIsNone(forbidden.search(path.read_text()), str(path))

    def test_ssh_terminal_and_file_transport_remain(self):
        ssh = ROOT / IOS / 'CmuxMobileSSH/Sources/CmuxMobileSSH'
        connection = (ssh / 'SSHConnection.swift').read_text()
        for token in ('func openDirectTCPIP', 'func openSession', 'jump.openDirectTCPIP', 'SSHChannelDataUnwrapper'):
            self.assertIn(token, connection)
        self.assertTrue((ssh / 'SSHLocalPortForward.swift').is_file())
        self.assertIn('.subsystem("sftp")', (ssh / 'SFTP/SFTPClient.swift').read_text())
        computers = (ROOT / IOS / 'CmuxMobileShell/Sources/CmuxMobileShell/MobileSSHComputers.swift').read_text()
        for token in ('forwardsByHost', 'func startPortForward', 'func stopPortForward', 'func stopAllPortForwards', 'SFTPClient.open'):
            self.assertIn(token, computers)
        lane = (ROOT / 'ios/cmuxPackage/Sources/cmuxFeature/IrxArtifactLane.swift').read_text()
        self.assertIn('struct IrxArtifactLane', lane)

    def test_wire_compatibility_and_non_browser_previews_remain(self):
        ssh = ROOT / IOS / 'CmuxMobileSSH/Sources/CmuxMobileSSH/CmuxTUI'
        for token in ('CmuxTUIBrowserStatus', 'CmuxTUIBrowserTab'):
            self.assertIn(token, (ssh / 'CmuxTUIBrowser.swift').read_text())
        self.assertIn('browsers: [CmuxTUIBrowserTab]', (ssh / 'CmuxTUIModels.swift').read_text())
        for path in (
            'Packages/Shared/CMUXMobileCore/Sources/CMUXMobileCore/MobileBrowserFrameEvent.swift',
            'Packages/iOS/CmuxAgentChatUI/Sources/CmuxAgentChatUI/Markdown/MarkdownWebContentView.swift',
            'Packages/iOS/CmuxMobileShellUI/Sources/CmuxMobileShellUI/SSHFiles/SSHFileBrowserModel.swift',
            'Packages/iOS/CmuxMobileShell/Sources/CmuxMobileShell/MobileShellComposite+SSHPaste.swift',
        ):
            self.assertTrue((ROOT / path).is_file(), path)
        memory = (ROOT / IOS / 'CmuxMobileShellModel/Sources/CmuxMobileShellModel/MobileWorkspaceLastTabStore.swift').read_text()
        for kind in ('browserStream', 'localBrowser', 'simulatorStream'):
            self.assertIn('case ' + kind, memory)


if __name__ == '__main__':
    unittest.main()
