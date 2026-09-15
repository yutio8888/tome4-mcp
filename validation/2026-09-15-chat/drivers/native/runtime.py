"""Isolated native engine launch helpers; no existing runtime is modified."""
from __future__ import annotations

import ctypes
import ctypes.util
import errno
import hashlib
import json
import os
from pathlib import Path
import shutil
import socket
import subprocess
import time
import zipfile

WORKSPACE = next(p for p in Path(__file__).resolve().parents if (p / "t-engine").is_file())
ADDON = WORKSPACE / "game/addons/tome-mcp-bridge"
DEFAULT_SOURCE = WORKSPACE / "tmp/battle-companion-validation-20260914/runtime"
DEFAULT_DEPS = WORKSPACE / "tmp/worktrees/yron-profile-20260912/tmp/profile/deps/root/usr"


def sha(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def asset(source: str, destination: str) -> None:
    try:
        os.link(source, destination)
    except OSError as error:
        if error.errno != errno.EXDEV:
            raise
        shutil.copy2(source, destination)


class NativeInput:
    def __init__(self, display: str):
        self.x = ctypes.CDLL(ctypes.util.find_library("X11"))
        self.xt = ctypes.CDLL(ctypes.util.find_library("Xtst"))
        self.x.XOpenDisplay.argtypes = [ctypes.c_char_p]
        self.x.XOpenDisplay.restype = ctypes.c_void_p
        self.x.XStringToKeysym.argtypes = [ctypes.c_char_p]
        self.x.XStringToKeysym.restype = ctypes.c_ulong
        self.x.XKeysymToKeycode.argtypes = [ctypes.c_void_p, ctypes.c_ulong]
        self.x.XKeysymToKeycode.restype = ctypes.c_uint
        self.x.XFlush.argtypes = [ctypes.c_void_p]
        self.x.XCloseDisplay.argtypes = [ctypes.c_void_p]
        self.xt.XTestFakeKeyEvent.argtypes = [ctypes.c_void_p, ctypes.c_uint, ctypes.c_int, ctypes.c_ulong]
        self.display = self.x.XOpenDisplay(display.encode())
        assert self.display, "Cannot open owned Xvfb display"

    def key(self, key: str, down: bool) -> None:
        symbol = self.x.XStringToKeysym(key.encode())
        code = self.x.XKeysymToKeycode(self.display, symbol)
        assert code, key
        assert self.xt.XTestFakeKeyEvent(self.display, code, down, 0)
        self.x.XFlush(self.display)

    def press(self, key: str) -> None:
        self.key(key, True)
        self.key(key, False)

    def chord(self, modifier: str, key: str) -> None:
        self.key(modifier, True)
        time.sleep(0.1)  # Let SDL observe the held modifier before the next key.
        self.press(key)
        time.sleep(0.1)
        self.key(modifier, False)

    def close(self) -> None:
        self.x.XCloseDisplay(self.display)


class Runtime:
    def __init__(self, name: str, source: Path, deps: Path, addon_archive: Path | None = None,
                 extra_addons: dict[str, Path] | None = None, interaction_probe: bool = False):
        assert name.replace("-", "").replace("_", "").isalnum()
        self.session = WORKSPACE / "tmp/tome-mcp-validation/sessions" / name
        self.session.mkdir(parents=True, exist_ok=False)
        self.interaction_probe=interaction_probe
        self.runtime = self.session / "runtime"
        self.runtime.mkdir()
        assert (source / "t-engine").is_file() and (source / "bootstrap").is_dir()
        shutil.copy2(source / "t-engine", self.runtime / "t-engine")
        shutil.copytree(source / "bootstrap", self.runtime / "bootstrap", copy_function=asset)
        (self.runtime / "game").mkdir()
        for path in (source / "game").iterdir():
            if path.name == "addons":
                continue
            target = self.runtime / "game" / path.name
            if path.is_dir():
                shutil.copytree(path, target, copy_function=asset)
            else:
                asset(path, target)
        addons = self.runtime / "game/addons"
        addons.mkdir()
        if addon_archive:
            assert addon_archive.is_file(), addon_archive
            with zipfile.ZipFile(addon_archive) as archive:
                assert "init.lua" in archive.namelist(), "Addon archive must have init.lua at its root"
            shutil.copy2(addon_archive, addons / "tome-mcp-bridge.teaa")
        else:
            shutil.copytree(ADDON, addons / "tome-mcp-bridge", ignore=shutil.ignore_patterns("tests", "__pycache__"))
        shutil.copytree(ADDON / "tests/native/tome-mcp-probe", addons / "tome-mcp-probe")
        for short_name, path in (extra_addons or {}).items():
            assert short_name.replace("-", "").isalnum() and short_name not in {"mcp-bridge", "mcp-probe"}
            if path.is_dir():
                shutil.copytree(path, addons / ("tome-" + short_name),
                                ignore=shutil.ignore_patterns("tests", "dist", "validation", "__pycache__"))
            else:
                assert path.suffix == ".teaa"
                shutil.copy2(path, addons / ("tome-" + short_name + ".teaa"))
        with zipfile.ZipFile(self.session / "candidate.zip", "w", zipfile.ZIP_DEFLATED) as archive:
            for path in sorted(addons.rglob("*")):
                if path.is_file():
                    archive.write(path, path.relative_to(addons))
        self.home = self.session / "home"
        settings = self.home / ".t-engine/4.0/settings"
        settings.mkdir(parents=True)
        with socket.socket() as sock:
            sock.bind(("127.0.0.1", 0))
            self.port = sock.getsockname()[1]
        self.token = "native-acceptance-" + os.urandom(16).hex()
        (settings / "mcp-test.cfg").write_text("\n".join([
            "cheat = true", "audio.enable = false", 'window = {size="1280x800 Windowed"}',
            "firstrun = true", "firstrun_gdpr = true", "disable_all_connectivity = false",
            "allow_online_events = false", "tome.upload_charsheet = false",
            "tome.autoassign_talents_on_birth = true", 'locale = "en_US"',
            'tome.gfx = {tiles="shockbolt",size="64x64",tiles_custom_dir="",tiles_custom_moddable=false,tiles_custom_adv=false}',
            "display_fps = 30", "background_saves = true",
            'tome_mcp_bridge = {enabled=true,port=%d,token="%s"}' % (self.port, self.token), "",
        ]))
        self.display = next(":" + str(n) for n in range(110, 200)
                            if not Path(f"/tmp/.X11-unix/X{n}").exists()
                            and not Path(f"/tmp/.X{n}-lock").exists())
        self.env = dict(os.environ)
        self.env.pop("LD_PRELOAD", None)
        self.env.update(DISPLAY=self.display, LIBGL_ALWAYS_SOFTWARE="1", ALSOFT_DRIVERS="null",
                        LD_LIBRARY_PATH=str(deps / "lib/x86_64-linux-gnu") + ":" + self.env.get("LD_LIBRARY_PATH", ""),
                        MESA_SHADER_CACHE_DIR=str(self.session / "mesa-cache"))
        self.xvfb_binary = deps / "bin/Xvfb-local"
        if not self.xvfb_binary.exists():
            self.xvfb_binary = deps / "bin/Xvfb"
        assert self.xvfb_binary.is_file()
        self.deps = deps
        addon_names = ["mcp-bridge", "mcp-probe", *(extra_addons or {})]
        self.command = [str(self.runtime / "t-engine"), "--no-steam", "--no-web", "--flush-stdout",
                        "--home", str(self.home), "-Mtome", "-n", "-uMCP_" + name[:19],
                        "-Eset_addons={" + ",".join(repr(name) for name in addon_names) + "};no_birth_popup=true"]
        if interaction_probe:
            self.command[-1] += ';mcp_probe_interactions=true'
        metadata = dict(command=self.command, source=str(source), dependencies=str(deps),
                        engine_sha256=sha(self.runtime / "t-engine"),
                        candidate_sha256=sha(self.session / "candidate.zip"),
                        new_character=True, imported_save=False, display=self.display, port=self.port,
                        interaction_probe=interaction_probe,
                        addon_archive=str(addon_archive) if addon_archive else None,
                        addon_archive_sha256=sha(addon_archive) if addon_archive else None,
                        extra_addons={key: str(value) for key, value in (extra_addons or {}).items()},
                        addon_lua_sha256={str(p.relative_to(addons)): sha(p) for p in addons.rglob("*.lua")})
        (self.session / "input.json").write_text(json.dumps(metadata, indent=2))
        self.xvfb = self.process = self.input = None
        self.handles = []
        self.log_paths = []

    def start(self) -> None:
        xlog = (self.session / "xvfb.log").open("w")
        log = (self.session / "game.log").open("w")
        self.log_paths.append(self.session / "game.log")
        self.handles.extend([xlog, log])
        self.xvfb = subprocess.Popen([str(self.xvfb_binary), self.display, "-screen", "0", "1280x800x24",
                                     "-nolisten", "tcp", "-ac", "-fp", str(self.deps / "share/fonts/X11/misc")],
                                    cwd=self.deps, env=self.env, stdout=xlog, stderr=subprocess.STDOUT)
        deadline = time.monotonic() + 5
        while not Path("/tmp/.X11-unix/X" + self.display[1:]).exists():
            assert self.xvfb.poll() is None, "Xvfb exited"
            if time.monotonic() > deadline:
                raise TimeoutError("No Xvfb socket")
            time.sleep(0.05)
        self.input = NativeInput(self.display)
        self.process = subprocess.Popen(self.command, cwd=self.runtime, env=self.env,
                                        stdout=log, stderr=subprocess.STDOUT)
        (self.session / "pid").write_text(str(self.process.pid))

    def restart_from_saved_copy(self) -> Path:
        """Reload only this suite's saved character, keeping the birth save intact."""
        assert self.process and self.process.poll() is None
        self.process.terminate()
        try:
            self.process.wait(timeout=2)
        except subprocess.TimeoutExpired:
            self.process.kill()
            self.process.wait()
        original_home = self.home
        self.home = self.session / "reload-home"
        shutil.copytree(original_home, self.home)
        command = []
        for arg in self.command:
            if arg == "-n":
                continue
            if arg == str(original_home):
                arg = str(self.home)
            if arg.startswith("-E"):
                arg = "-Emcp_probe_reload=true;no_birth_popup=true"
                if self.interaction_probe:
                    arg += ';mcp_probe_interactions=true'
            command.append(arg)
        (self.session / "reload-input.json").write_text(json.dumps(dict(
            command=command, source_home=str(original_home), reloaded_own_test_save=True,
            port=self.port, engine_sha256=sha(self.runtime / "t-engine")), indent=2))
        log_path = self.session / "reload.log"
        log = log_path.open("w")
        self.handles.append(log)
        self.log_paths.append(log_path)
        self.process = subprocess.Popen(command, cwd=self.runtime, env=self.env, stdout=log, stderr=subprocess.STDOUT)
        (self.session / "reload.pid").write_text(str(self.process.pid))
        return original_home

    def records(self) -> list[dict]:
        content = "\n".join(p.read_text(errors="replace") for p in self.log_paths)
        records = []
        for line in content.splitlines():
            if line.startswith("[MCPProbe] "):
                try:
                    records.append(json.loads(line[len("[MCPProbe] "):]))
                except json.JSONDecodeError:
                    pass  # A partial final write will complete on the next poll.
        return records

    def wait_ready(self, timeout: float = 90) -> None:
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            records = self.records()
            errors = [r for r in records if r.get("kind") == "error"]
            assert not errors, errors
            assert self.process.poll() is None, "Game exited before arena_ready"
            if any(r.get("kind") == "arena_ready" for r in records):
                time.sleep(0.3)
                return
            time.sleep(0.05)
        raise TimeoutError("Native birth/arena startup did not finish")

    def latest_state(self) -> dict:
        return next(r for r in reversed(self.records()) if r.get("kind") == "state")

    def close(self) -> None:
        if self.input:
            self.input.close()
        for process in (self.process, self.xvfb):
            if process and process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait()
        for handle in self.handles:
            handle.close()
