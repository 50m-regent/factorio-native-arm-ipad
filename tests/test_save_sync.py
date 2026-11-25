"""Exercise the real save synchronizer on disk without an iCloud account."""

import json
import os
import shutil
import subprocess
import sys
import time
import zipfile
from pathlib import Path

import pytest

pytestmark = pytest.mark.skipif(
    sys.platform != "darwin" or shutil.which("xcrun") is None,
    reason="Save synchronization requires Foundation and the Apple compiler",
)


@pytest.fixture(scope="module")
def sync_binary(tmp_path_factory: pytest.TempPathFactory) -> Path:
    """Compile the production synchronization engine with its small CLI harness."""
    root = Path(__file__).resolve().parents[1]
    binary = tmp_path_factory.mktemp("save-sync") / "sync-tests"
    subprocess.run(
        [
            "xcrun",
            "clang",
            "-fobjc-arc",
            "-Wall",
            "-Wextra",
            "-Werror",
            "-framework",
            "Foundation",
            str(root / "probe/SaveSync.m"),
            str(root / "tests/SaveSyncTests.m"),
            "-o",
            str(binary),
        ],
        check=True,
        capture_output=True,
        text=True,
        timeout=60,
    )
    return binary


def save(path: Path, content: str, *, age: int = 10) -> bytes:
    """Create a ZIP with a controlled modification time."""
    with zipfile.ZipFile(path, "w") as archive:
        archive.writestr("factory/level.dat", content)
    timestamp = time.time() - age
    os.utime(path, (timestamp, timestamp))
    return path.read_bytes()


def run_save_tool(
    binary: Path, mode: str, local: Path, other: Path
) -> dict[str, object]:
    """Run the actual file operations against isolated folders."""
    result = subprocess.run(
        [str(binary), mode, str(local), str(other)],
        check=True,
        capture_output=True,
        text=True,
        timeout=30,
    )
    return json.loads(result.stdout)


@pytest.fixture
def folders(tmp_path: Path) -> tuple[Path, Path]:
    """Provide isolated local and cloud-like folders for each test."""
    local, remote = tmp_path / "local", tmp_path / "remote"
    local.mkdir()
    remote.mkdir()
    return local, remote


def test_latest_save_replaces_one_backup(
    sync_binary: Path, folders: tuple[Path, Path]
) -> None:
    """Select by modification time and overwrite a single cloud file on updates."""
    local, remote = folders
    backup = remote / "Factorio iPad Latest.zip"
    legacy = remote / "factory-sync-legacy.zip"
    original = save(local / "manual.zip", "older", age=50)
    first = save(local / "_autosave1.zip", "latest", age=30)
    legacy.write_bytes(original)
    assert run_save_tool(sync_binary, "backup", local, remote) == {
        "copied": True,
        "error": "",
    }
    assert backup.read_bytes() == first
    assert run_save_tool(sync_binary, "backup", local, remote)["copied"] is False
    updated = save(local / "manual.zip", "new progress")
    assert run_save_tool(sync_binary, "backup", local, remote)["copied"] is True
    assert backup.read_bytes() == updated
    assert legacy.read_bytes() == original
    assert {file.name for file in remote.iterdir()} == {backup.name, legacy.name}
    assert not (local / legacy.name).exists()


def test_keeps_newer_cloud_save(sync_binary: Path, folders: tuple[Path, Path]) -> None:
    """Keep a newer backup when the iPad has fewer or older saves."""
    local, remote = folders
    save(local / "factory.zip", "old", age=40)
    backup = remote / "Factorio iPad Latest.zip"
    expected = save(backup, "new")
    assert run_save_tool(sync_binary, "backup", local, remote) == {
        "copied": False,
        "error": "",
    }
    assert backup.read_bytes() == expected


def test_ignores_unfinished_or_linked_saves(
    sync_binary: Path, folders: tuple[Path, Path]
) -> None:
    """Keep the previous backup when the only candidates are unsafe to copy."""
    local, remote = folders
    expected = save(remote / "Factorio iPad Latest.zip", "previous", age=120)
    recent = save(local / "recent.zip", "just written", age=0)
    partial = local / "partial.zip"
    partial.write_bytes(recent[:-8])
    timestamp = time.time() - 10
    os.utime(partial, (timestamp, timestamp))
    save(local / ".hidden.zip", "hidden")
    outside = remote / "outside.zip"
    save(outside, "linked")
    (local / "link.zip").symlink_to(outside)
    assert run_save_tool(sync_binary, "backup", local, remote) == {
        "copied": False,
        "error": "",
    }
    assert (remote / "Factorio iPad Latest.zip").read_bytes() == expected


def test_import_keeps_existing_local_save(
    sync_binary: Path, folders: tuple[Path, Path]
) -> None:
    """Import a selected legacy copy without changing files in either folder."""
    local, remote = folders
    name = "工場-sync-old.zip"
    original = save(local / name, "iPad")
    selected = remote / name
    expected = save(selected, "Mac", age=40)
    result = run_save_tool(sync_binary, "import", local, selected)
    assert result == {"imported": "工場-sync-old (2).zip", "error": ""}
    target = local / "工場-sync-old (2).zip"
    assert (local / name).read_bytes() == original
    assert target.read_bytes() == selected.read_bytes() == expected
    assert target.stat().st_mtime == pytest.approx(selected.stat().st_mtime)


def test_import_rejects_incomplete_archive(
    sync_binary: Path, folders: tuple[Path, Path]
) -> None:
    """Report a malformed file and leave no visible or temporary local copy."""
    local, remote = folders
    selected = remote / "damaged.zip"
    selected.write_bytes(b"PK\x03\x04")
    result = run_save_tool(sync_binary, "import", local, selected)
    assert result["imported"] == ""
    assert result["error"]
    assert not list(local.iterdir())


def test_backup_reports_missing_folder(
    sync_binary: Path, folders: tuple[Path, Path]
) -> None:
    """Report a deleted or unavailable backup location."""
    local, remote = folders
    save(local / "_autosave1.zip", "local")
    result = run_save_tool(sync_binary, "backup", local, remote / "missing")
    assert result["copied"] is False
    assert result["error"]
