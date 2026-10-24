"""Retired iOS task creation boundary, not a live-service traffic assertion."""
import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SHELL = ROOT / 'Packages/iOS/CmuxMobileShell/Sources/CmuxMobileShell'
UI = ROOT / 'Packages/iOS/CmuxMobileShellUI/Sources/CmuxMobileShellUI'


class TaskCreationRemovalTests(unittest.TestCase):
    def test_no_task_ui_or_startup_producers(self):
        forbidden = re.compile(
            r'\b(?:TaskComposerSheet|TaskComposerButton|TaskComposerPrefetchObserver|'
            r'TaskComposerPrefetchModifier|submitTaskComposer|taskComposerPresentation|'
            r'workspaceTaskComposer|supportsTaskComposer|MobileTaskModelCatalogClient|'
            r'MobileTaskCommandComposer)\b|'
            r'cmux\.mobile\.debug\.taskComposer(?:ShellIconVariant|FullLiquidGlass)\.v1|'
            r'cmux\.com/api/agent-models|"mobile\.(?:task\.models\.list|directory\.(?:list|search))"'
        )
        for root in [ROOT / 'ios/cmuxPackage/Sources', *(ROOT / 'Packages/iOS').glob('*/Sources')]:
            for path in root.rglob('*.swift'):
                self.assertIsNone(forbidden.search(path.read_text()), str(path))

    def test_legacy_store_has_no_production_read_write_triggers(self):
        forbidden = re.compile(r'\b(?:listTemplates|composerDrafts|saveComposerDraft|setComposerPickerPreferences)\s*\(')
        for path in [*SHELL.glob('MobileShellComposite*.swift'), *UI.rglob('*.swift')]:
            self.assertIsNone(forbidden.search(path.read_text()), str(path))
        root = (ROOT / 'ios/cmuxPackage/Sources/cmuxFeature/CMUXMobileRootScene.swift').read_text()
        self.assertIn('UserDefaultsMobileTaskTemplateStore(', root)
        self.assertIn('taskTemplateStore?.clearAllUserData()', (SHELL / 'MobileShellComposite.swift').read_text())

    def test_shared_paths_are_not_retired(self):
        for name in ('TaskComposerPromptEditorCoordinator.swift', 'TaskTemplateIcon.swift',
                     'TaskComposerShellIconVariant.swift', 'TaskComposerAttachmentStager.swift'):
            self.assertTrue((UI / 'TaskComposer' / name).is_file())
        upload = (SHELL / 'MobileShellComposite+TaskAttachments.swift').read_text()
        self.assertIn('"mobile.task.attachment.upload"', upload)
        self.assertIn('context.isCurrent(', upload)
        self.assertIn('"workspace.create"', (SHELL / 'MobileShellComposite+WorkspaceCreateRequest.swift').read_text())
        self.assertIn('ImportedPhotoLibraryFile.load', (UI / 'TerminalComposerView.swift').read_text())
        self.assertIn('TaskComposerPromptEditorCoordinator', (UI / 'TerminalComposerPromptEditor.swift').read_text())


if __name__ == '__main__':
    unittest.main()
