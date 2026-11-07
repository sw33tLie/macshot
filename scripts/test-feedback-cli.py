#!/usr/bin/env python3
"""Exercise the compiled CLI without launching a GUI or using real captures."""
import json
import os
import base64
import pathlib
import plistlib
import shutil
import subprocess
import sys
import tempfile


def check(binary):
    with tempfile.TemporaryDirectory(prefix="macshot-cli-test-") as temporary:
        root = pathlib.Path(temporary)
        help_text = subprocess.run([binary, "--help"], check=True, capture_output=True, text=True).stdout
        assert 'skill install --target codex --handoff "/absolute/macshot-ai"' in help_text
        app = root / "Fixture.app"
        (app / "Contents").mkdir(parents=True)
        (app / "Contents/Info.plist").write_bytes(plistlib.dumps({
            "CFBundlePackageType": "APPL", "CFBundleIdentifier": "org.macshot.cli-fixture",
            "CFBundleShortVersionString": "1.2.3", "CFBundleVersion": "7",
        }))
        result = subprocess.run([binary, "version", "--app", str(app)], check=True, capture_output=True, text=True)
        version = json.loads(result.stdout)
        assert version["version"] == "1.2.3" and version["build"] == "7", version
        assert version["protocol"] == "1"
        handoff = root / "handoff"
        handoff.mkdir(mode=0o700)
        for target in ["codex", "claude", "antigravity"]:
            directory = root / f"skills {target}"
            install = [binary, "skill", "install", "--target", target, "--directory", str(directory),
                       "--handoff", str(handoff)]
            result = subprocess.run(install, check=True, capture_output=True, text=True, timeout=10)
            receipt = json.loads(result.stdout)
            skill = directory / "macshot-feedback"
            assert receipt["target"] == target and receipt["directory"] == str(skill)
            assert receipt["state"] == "installed"
            assert (skill / "SKILL.md").read_text().startswith("---\nname: macshot-feedback\n")
            config = json.loads((skill / "references/local.json").read_text())
            assert pathlib.Path(config["cli"]).samefile(binary)
            assert config["handoff"] == str(handoff)
            marker = skill / "custom-user-note.txt"
            marker.write_text("preserve")
            assert subprocess.run(install, capture_output=True, timeout=10).returncode == 2
            assert marker.read_text() == "preserve"
            assert not list(directory.glob(".macshot-feedback-*")), "Installation left staging files"

        directory = root / "without-handoff"
        install = [binary, "skill", "install", "--target", "codex", "--directory", str(directory)]
        environment = dict(os.environ)
        environment.pop("MACSHOT_FEEDBACK_HANDOFF", None)
        result = subprocess.run(install, check=True, capture_output=True, text=True, env=environment, timeout=10)
        assert "No handoff folder recorded in references/local.json" in result.stderr
        assert 'reinstall with --handoff "/absolute/macshot-ai"' in result.stderr
        config = json.loads((directory / "macshot-feedback/references/local.json").read_text())
        assert "handoff" not in config

        configured_app = root / "Configured.app"
        configured_cli = configured_app / "Contents/MacOS/macshot-cli"
        configured_cli.parent.mkdir(parents=True)
        shutil.copy2(binary, configured_cli)
        bundle_id = "org.macshot.cli-configured"
        (configured_app / "Contents/Info.plist").write_bytes(plistlib.dumps({
            "CFBundlePackageType": "APPL", "CFBundleIdentifier": bundle_id,
            "CFBundleExecutable": "macshot-cli",
        }))
        fixed_home = root / "configured-home"
        preferences = fixed_home / f"Library/Containers/{bundle_id}/Data/Library/Preferences/{bundle_id}.plist"
        preferences.parent.mkdir(parents=True)
        preferences.write_bytes(plistlib.dumps({"feedbackHandoffPath": str(handoff)}))
        configured_environment = dict(environment)
        configured_environment["CFFIXED_USER_HOME"] = str(fixed_home)
        configured_directory = root / "configured-skills"
        subprocess.run([
            configured_cli, "skill", "install", "--target", "codex",
            "--directory", configured_directory,
        ], check=True, capture_output=True, env=configured_environment, timeout=10)
        config = json.loads((configured_directory / "macshot-feedback/references/local.json").read_text())
        assert pathlib.Path(config["cli"]).samefile(configured_cli)
        assert config["handoff"] == str(handoff)

        concurrent_directory = root / "concurrent"
        concurrent = [binary, "skill", "install", "--target", "codex", "--directory", str(concurrent_directory)]
        processes = [subprocess.Popen(concurrent, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=environment)
                     for _ in range(4)]
        for process in processes:
            process.communicate(timeout=10)
        assert sorted(process.returncode for process in processes) == [0, 2, 2, 2]
        assert sorted(path.name for path in concurrent_directory.iterdir()) == ["macshot-feedback"]
        assert (concurrent_directory / "macshot-feedback/references/local.json").is_file()

        environment_directory = root / "environment-handoff"
        environment["MACSHOT_FEEDBACK_HANDOFF"] = str(handoff)
        subprocess.run([binary, "skill", "install", "--target", "antigravity", "--directory", str(environment_directory)],
                       check=True, capture_output=True, env=environment, timeout=10)
        config = json.loads((environment_directory / "macshot-feedback/references/local.json").read_text())
        assert config["handoff"] == str(handoff)

        invalid_directory = root / "invalid-target"
        for args in [
            ["--target", "unsupported"], [], ["--target", "codex", "--target", "claude"],
            ["--target", "codex", "--unexpected", "value"], ["--target"],
            ["--target", "codex", "--handoff", "relative"],
        ]:
            result = subprocess.run([binary, "skill", "install", "--directory", str(invalid_directory), *args],
                                    capture_output=True, timeout=10)
            assert result.returncode == 2, (args, result.stderr)
            assert not invalid_directory.exists()

        symlink_parent = root / "symlink-skill"
        symlink_parent.mkdir()
        (symlink_parent / "macshot-feedback").symlink_to(root / "missing")
        result = subprocess.run([binary, "skill", "install", "--target", "claude", "--directory", str(symlink_parent)],
                                capture_output=True, timeout=10)
        assert result.returncode == 2
        assert (symlink_parent / "macshot-feedback").is_symlink()
        assert not (root / "missing").exists()
        output = root / "output"
        output.mkdir()
        image = root / "invalid.png"
        image.write_text("This is not an image.")
        base = [binary, "annotate", str(image), "--app", str(app), "--handoff", str(handoff),
                "--output", str(output / "feedback.json")]

        def rejects(arguments):
            result = subprocess.run(arguments, capture_output=True, timeout=10)
            assert result.returncode == 2, (result.returncode, result.stderr)
            assert not list(handoff.iterdir()), "An invalid invocation created a session"

        rejects(base)
        rejects(base + ["--timeout", "0"])
        existing = output / "feedback.json"
        existing.write_text("preserve")
        rejects(base)
        assert existing.read_text() == "preserve"
        existing.unlink()
        image.write_bytes(base64.b64decode("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aYdwAAAAASUVORK5CYII="))
        handoff.chmod(0o755)
        rejects(base)
        handoff.chmod(0o700)
        assert not list(output.iterdir()), "Invalid input published output files"
        capture = [binary, "capture", "--app", str(app), "--handoff", str(handoff),
                   "--output", str(output / "feedback.json")]
        for extra in [["--timeout", "0"], ["unexpected.png"], ["--unknown"], ["--timeout"],
                      ["--offline", "--offline"]]:
            rejects(capture + extra)
        existing.write_text("preserve")
        rejects(capture)
        assert existing.read_text() == "preserve"
        existing.unlink()

        # This incomplete fixture app cannot launch. Capture must still publish
        # the right request and cancel it on launch failure without an input file.
        result = subprocess.run(capture, capture_output=True, timeout=15)
        assert result.returncode == 2, (result.returncode, result.stderr)
        sessions = list(handoff.iterdir())
        assert len(sessions) == 1
        request = json.loads((sessions[0] / "request.json").read_text())
        assert request["mode"] == "capture" and request["version"] == 1
        assert not (sessions[0] / "input.png").exists()
        assert (sessions[0] / "cancel.json").is_file()
        assert not list(output.iterdir())
    print("CLI passed: three skill targets, local configuration, duplicate/symlink protection, invalid arguments, GUI version, invalid image/timeout, private handoff, no overwrite or partial output")


if __name__ == "__main__":
    check(str(pathlib.Path(sys.argv[1]).resolve()))
