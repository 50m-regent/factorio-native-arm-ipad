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


def save(path: Path, content: str = "factory", *, fresh: bool = False) -> bytes:
    """Create a complete ZIP and normally age it past the write stability window."""
    path.parent.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(path, "w") as archive:
        archive.writestr("level.dat", content)
    if not fresh:
        timestamp = time.time() - 10
        os.utime(path, (timestamp, timestamp))
    return path.read_bytes()


def sync(binary: Path, local: Path, remote: Path, *, mode: str = "") -> dict:
    """Run two consecutive scans to check copying and idempotence with one cache."""
    result = subprocess.run(
        [str(binary), str(local), str(remote), *([mode] if mode else [])],
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


def test_copies_both_directions_once(
    sync_binary: Path, folders: tuple[Path, Path]
) -> None:
    """Copy new saves both ways and leave unrelated configuration files alone."""
    local, remote = folders
    ipad = save(local / "ipad.zip", "iPad")
    mac = save(remote / "mac.zip", "Mac")
    (local / "config.ini").write_text("private")
    assert sync(sync_binary, local, remote) == {
        "copied": 2,
        "secondCopied": 0,
        "error": "",
    }
    assert (remote / "ipad.zip").read_bytes() == ipad
    assert (local / "mac.zip").read_bytes() == mac
    assert not (remote / "config.ini").exists()


def test_preserves_both_conflicting_saves(
    sync_binary: Path, folders: tuple[Path, Path]
) -> None:
    """Never replace a same-name save and do not generate duplicate conflict copies."""
    local, remote = folders
    ipad = save(local / "factory.zip", "iPad progress")
    mac = save(remote / "factory.zip", "Mac progress")
    result = sync(sync_binary, local, remote)
    assert result == {"copied": 2, "secondCopied": 0, "error": ""}
    assert (local / "factory.zip").read_bytes() == ipad
    assert (remote / "factory.zip").read_bytes() == mac
    assert {p.read_bytes() for p in local.iterdir()} == {ipad, mac}
    assert {p.read_bytes() for p in remote.iterdir()} == {ipad, mac}


def test_deduplicates_content_and_restores_deleted_copy(
    sync_binary: Path, folders: tuple[Path, Path]
) -> None:
    """Match saves by content even after rename and never propagate deletions."""
    local, remote = folders
    save(local / "factory.zip")
    shutil.copy2(local / "factory.zip", remote / "renamed.zip")
    assert sync(sync_binary, local, remote)["copied"] == 0
    (local / "factory.zip").unlink()
    assert sync(sync_binary, local, remote)["copied"] == 1
    assert (local / "renamed.zip").exists()


def test_skips_incomplete_recent_hidden_and_linked_saves(
    sync_binary: Path, folders: tuple[Path, Path]
) -> None:
    """Exclude pending writes, malformed archives, links, hidden files, and subfolders."""
    local, remote = folders
    complete = save(local / "source.bin")
    (local / "partial.zip").write_bytes(complete[:-8])
    old = time.time() - 10
    os.utime(local / "partial.zip", (old, old))
    save(local / "fresh.zip", fresh=True)
    save(local / ".hidden.zip")
    save(local / "nested/factory.zip")
    (local / "link.zip").symlink_to(local / "source.bin")
    assert sync(sync_binary, local, remote) == {
        "copied": 0,
        "secondCopied": 0,
        "error": "",
    }
    assert not list(remote.iterdir())


def test_source_changed_after_inventory_is_not_published(
    sync_binary: Path, folders: tuple[Path, Path]
) -> None:
    """Reject a staged copy whose content differs from the sampled source digest."""
    local, remote = folders
    save(local / "race.zip", "before save")
    save(local / "replacement.bin", "during save")
    assert sync(sync_binary, local, remote, mode="race") == {
        "copied": 0,
        "secondCopied": 0,
        "error": "",
    }
    assert not list(remote.iterdir())


def test_long_unicode_conflict_names(
    sync_binary: Path, folders: tuple[Path, Path]
) -> None:
    """Keep generated conflict names within filesystem component length limits."""
    local, remote = folders
    name = "工場" * 35 + ".zip"
    save(local / name, "iPad")
    save(remote / name, "Mac")
    assert sync(sync_binary, local, remote)["copied"] == 2
    assert len(list(remote.glob("*.zip"))) == 2


def test_reports_missing_folder_and_rejects_self_sync(
    sync_binary: Path, folders: tuple[Path, Path]
) -> None:
    """Return an actionable error when the shared folder cannot be used."""
    local, remote = folders
    save(local / "factory.zip")
    assert sync(sync_binary, local, remote / "missing")["error"]
    assert "separate folder" in sync(sync_binary, local, local)["error"]
    assert len(list(local.iterdir())) == 1


def test_later_save_is_exported_without_overwriting_previous_version(
    sync_binary: Path, folders: tuple[Path, Path]
) -> None:
    """Invalidate the digest cache when the game atomically replaces a saved file."""
    local, remote = folders
    old = save(local / "factory.zip", "before playing")
    new = save(local / "replacement.bin", "after playing")
    assert sync(sync_binary, local, remote, mode="rewrite") == {
        "copied": 1,
        "secondCopied": 2,
        "error": "",
    }
    assert (local / "factory.zip").read_bytes() == new
    assert (remote / "factory.zip").read_bytes() == old
    assert {p.read_bytes() for p in remote.iterdir()} == {old, new}
