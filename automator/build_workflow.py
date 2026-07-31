"""Generate a Finder Quick Action (.workflow) that runs fcp-subtitle on selected files.

Run once: uv run python automator/build_workflow.py
Then double-click the generated .workflow to install it into ~/Library/Services/.
"""

from __future__ import annotations

import plistlib
import shutil
import uuid
from pathlib import Path

PROJECT_ROOT = Path(__file__).resolve().parent.parent
WORKFLOW_NAME = "SenseVoice 转 FCPXML.workflow"
MENU_TITLE = "SenseVoice 转 FCPXML"


def _info_plist() -> dict:
    return {
        "NSServices": [
            {
                "NSMenuItem": {"default": MENU_TITLE},
                "NSMessage": "runWorkflowAsService",
                "NSRequiredContext": {"NSApplicationIdentifier": "com.apple.finder"},
                "NSSendFileTypes": ["public.audio", "public.movie"],
            }
        ]
    }


def _shell_script() -> str:
    project_root = str(PROJECT_ROOT)
    return (
        "for f in \"$@\"; do\n"
        f'  /usr/bin/env uv run --project "{project_root}" fcp-subtitle "$f" '
        "2>&1 | /usr/bin/tee -a /tmp/fcp_subtitle.log\n"
        'done\n'
    )


def _document_wflow() -> dict:
    action_uuid = str(uuid.uuid4()).upper()
    return {
        "AMApplicationBuild": "1.0",
        "AMApplicationVersion": "2.10",
        "AMDocumentVersion": "2",
        "actions": [
            {
                "action": {
                    "ActionBundlePath": "/System/Library/Automator/Run Shell Script.action",
                    "BundleIdentifier": "com.apple.RunShellScript",
                    "ActionName": "Run Shell Script",
                    "ActionParameters": {
                        "COMMAND_STRING": _shell_script(),
                        "CheckedForUserDefaultShell": True,
                        "inputMethod": 0,
                        "shell": "/bin/zsh",
                        "source": "",
                    },
                },
                "isViewVisible": True,
            }
        ],
        "connectors": {},
        "workflowMetaData": {
            "serviceInputTypeIdentifier": "com.apple.Automator.fileSystemObject",
            "serviceOutputTypeIdentifier": "com.apple.Automator.nothing",
            "serviceProcessesInput": 0,
            "workflowTypeIdentifier": "com.apple.Automator.servicesMenu",
            "applicationBundleID": "com.apple.finder",
            "applicationPath": "/System/Library/CoreServices/Finder.app",
        },
        "UUID": action_uuid,
    }


def build(output_dir: Path | None = None) -> Path:
    output_dir = output_dir or PROJECT_ROOT
    workflow_path = output_dir / WORKFLOW_NAME
    contents_dir = workflow_path / "Contents"

    if workflow_path.exists():
        shutil.rmtree(workflow_path)
    contents_dir.mkdir(parents=True)

    with open(contents_dir / "Info.plist", "wb") as f:
        plistlib.dump(_info_plist(), f)

    with open(contents_dir / "document.wflow", "wb") as f:
        plistlib.dump(_document_wflow(), f)

    return workflow_path


def main() -> None:
    path = build()
    print(f"已生成: {path}")
    print("双击安装,然后在 Finder 里选中音频/视频文件右键 > 快速操作 里就能看到")


if __name__ == "__main__":
    main()
