#!/usr/bin/env bash
# IoT Diagnostic Platform · локальний Android-показ на macOS.
exec python3 -u - "$@" <<'PY'
import argparse
from contextlib import ExitStack
import fcntl
import json
import os
from pathlib import Path
import platform
import re
import secrets
import shutil
import socket
import subprocess
import tempfile
import time
from urllib.error import URLError
from urllib.request import Request, urlopen
from xml.etree import ElementTree as ET

ROOT = "https://git.cvv-sandbox.eu.cc/Nazar/iot-diagnostic"
REV = "7198faf5999718bc87c5e4a0b99be4c6899aee0d"
PACKAGE = "com.companyname.iot.mobile"
CACHE = Path.home() / "Library/Caches/mpp-iot-defense"

def run(*args, timeout=40):
    return subprocess.check_output(args, timeout=timeout, text=True).strip()

def wait_for(label, read, timeout):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        try:
            result = read()
            if result is not None and result is not False:
                return result
        except (subprocess.SubprocessError, URLError, ET.ParseError, ValueError):
            pass
        time.sleep(1)
    raise RuntimeError(f"Не вдалося дочекатися: {label}.")

def free(port):
    with socket.socket() as probe:
        try:
            probe.bind(("127.0.0.1", port))
        except OSError:
            return False
    return True

def stop(process):
    if process.poll() is None:
        process.terminate()
        try:
            process.wait(timeout=8)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait()

def prepare_source(supplied):
    source = supplied.resolve() if supplied else CACHE / f"source-{REV[:7]}"
    if not source.exists() and not supplied:
        with tempfile.TemporaryDirectory(dir=CACHE, prefix="clone-") as folder:
            clone = Path(folder) / "source"
            subprocess.run(["git", "clone", "--quiet", ROOT + ".git", str(clone)], check=True, timeout=180)
            run("git", "-C", str(clone), "switch", "--quiet", "--detach", REV)
            clone.rename(source)
    if run("git", "-C", str(source), "rev-parse", "HEAD") != REV:
        raise RuntimeError(f"Для сценарію потрібен коміт {REV[:7]}. Обраний клон: {source}")
    if run("git", "-C", str(source), "status", "--porcelain", "--untracked-files=no"):
        raise RuntimeError(f"У клоні є локальні правки. Для цього запуску потрібен чистий клон: {source}")
    return source

def prepare_api(base):
    def request(path, payload=None, method=None, token=None):
        headers = {"Content-Type": "application/json"}
        if token:
            headers["Authorization"] = f"Bearer {token}"
        body = json.dumps(payload).encode() if payload is not None else None
        with urlopen(Request(base + path, data=body, headers=headers, method=method), timeout=3) as response:
            return json.load(response)

    wait_for("API зі status: ok", lambda: request("/")["status"] == "ok", 35)
    token = request("/api/auth/token", {"user": "defense", "role": "Admin", "group": "default"})["token"]
    device = request("/api/devices", {
        "name": "Demo sensor", "baseUrl": base, "description": "Before sync",
        "monitoringEnabled": False, "monitoringPath": "simulator/normal",
    }, token=token)
    path = f"/api/devices/{device['id']}"
    request(path + "/rules", [{"jsonPath": "temperature", "minimum": 0, "maximum": 40, "required": True}], "PUT", token)
    for _ in range(2):
        result = request(path + "/requests", {"method": "GET", "path": "simulator/normal", "timeoutMs": 1000}, token=token)
        if result["statusCode"] != 200 or result["error"] is not None:
            raise RuntimeError("Симулятор не повернув успішне вимірювання.")
    return token

def connect_android(adb, address, token):
    def nodes():
        dump_path = "/sdcard/mpp-iot-demo.xml"
        result = adb("shell", "uiautomator", "dump", dump_path, timeout=9)
        if not result.endswith(dump_path):
            raise ValueError("Стан екрана Android ще не оновлено.")
        return list(ET.fromstring(adb("shell", "cat", dump_path)).iter("node"))

    def labels(name):
        return next((n for n in nodes() if n.get("text", "").strip() == name), None)

    def tap(node):
        x0, y0, x1, y1 = map(int, re.findall(r"\d+", node.get("bounds", "")))
        adb("shell", "input", "tap", str((x0 + x1) // 2), str((y0 + y1) // 2))

    def focus_and_clear(node):
        tap(node)
        time.sleep(0.9)
        adb("shell", "input", "keycombination", "113", "29")
        adb("shell", "input", "keyevent", "67")

    def token_entry():
        return next((n for n in nodes() if n.get("password") == "true"), None)

    def address_entry():
        screen = nodes()
        prompt = next((n for n in screen if n.get("text") == "Wait"), None)
        if prompt is not None:
            tap(prompt)
            return None
        return next((n for n in screen
                     if n.get("class") == "android.widget.EditText" and n.get("password") != "true"), None)

    entry = wait_for("поля адреси в Android", address_entry, 90)
    if entry.get("text") != address:
        focus_and_clear(entry)
        adb("shell", "input", "text", address)
        adb("shell", "input", "keyevent", "4")
        wait_for("оновленої адреси API", lambda: labels(address), 15)
    if not re.fullmatch(r"[A-Za-z0-9_.-]+", token):
        raise RuntimeError("API повернув токен у несподіваному форматі.")
    try:
        length = -1
        for chunk_size in (32, 12):
            secret_field = wait_for("поля токена", token_entry, 25)
            focus_and_clear(secret_field)
            for offset in range(0, len(token), chunk_size):
                adb("shell", "input", "text", token[offset:offset + chunk_size])
            visible = wait_for("стану поля токена", token_entry, 25)
            length = len(visible.get("text", ""))
            if length == len(token):
                break
            print(f"Повторю ввід токена: Android прийняв {length} із {len(token)} символів.")
        else:
            raise RuntimeError(f"Поле токена прийняло {length} із {len(token)} символів.")
        adb("shell", "input", "keyevent", "4")
    except subprocess.SubprocessError:
        raise RuntimeError("Android не прийняв тестовий токен.") from None
    tap(wait_for("кнопки підключення", lambda: labels("Підключити / оновити"), 20))
    wait_for("повідомлення «Завантажено пристроїв: 1»", lambda: labels("Завантажено пристроїв: 1"), 30)
    tap(wait_for("списку пристроїв", lambda: labels("Оберіть пристрій"), 20))
    tap(wait_for("пристрою Demo sensor", lambda: labels("Demo sensor"), 20))
    wait_for("картки Demo sensor", lambda: sum(n.get("text") == "Demo sensor" for n in nodes()) >= 2, 20)

def open_materials(source):
    editor = Path("/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code")
    if not editor.is_file():
        print(f"VS Code: відкрий {source}")
    else:
        files = [
            "src/IoT.Mobile/IoT.Mobile.csproj", "src/IoT.Mobile/MainPage.xaml",
            "src/IoT.Mobile/MainViewModel.cs", "src/IoT.Client/Offline/DeviceRepository.cs",
            "src/IoT.Client/Offline/SyncEngine.cs", "src/IoT.Client/Charts/ChartData.cs",
        ]
        subprocess.run([str(editor), "--new-window", str(source), *(str(source / p) for p in files)], check=False)
    subprocess.run(["open",
                    ROOT + "/pulls/122", ROOT + "/pulls/112", ROOT + "/pulls/124",
                    ROOT + "/pulls/102#issuecomment-1698", ROOT + "/actions/runs/61",
                    ROOT + "/actions/runs/62", "https://tzahorskyi.github.io/mpp-defense/iot-android/#prep"], check=False)

def isolate_avd(scope):
    avd_home = Path(os.environ.get("ANDROID_AVD_HOME") or
                    Path(os.environ.get("ANDROID_EMULATOR_HOME") or
                         os.environ.get("ANDROID_USER_HOME") or Path.home() / ".android") / "avd")
    profile = avd_home / "mpp_phone.ini"
    settings = dict(line.split("=", 1) for line in profile.read_text().splitlines() if "=" in line)
    path = settings.get("path")
    original = Path(path).expanduser() if path else None
    if original is None or not original.is_dir():
        original = avd_home.parent / settings.get("path.rel", "avd/mpp_phone.avd")
    # Copy the profile and base disk. The .qcow2 overlay holds the user's changes.
    isolated_home = Path(scope.enter_context(tempfile.TemporaryDirectory(prefix="avd-", dir=CACHE)))
    isolated_device = isolated_home / "mpp_phone.avd"
    isolated_device.mkdir()
    shutil.copyfile(original / "config.ini", isolated_device / "config.ini")
    base_disk = original / "userdata-qemu.img"
    if base_disk.is_file() and (original / "userdata-qemu.img.qcow2").is_file():
        shutil.copyfile(base_disk, isolated_device / base_disk.name)
    settings.pop("path.rel", None)
    settings["path"] = str(isolated_device)
    (isolated_home / profile.name).write_text("".join(f"{key}={value}\n" for key, value in settings.items()))
    return dict(os.environ, ANDROID_AVD_HOME=str(isolated_home))

def main():
    parser = argparse.ArgumentParser(prog="demo-iot.sh", description="Запустити API, Android та матеріали до захисту IoT Diagnostic Platform.")
    parser.add_argument("--source", type=Path, help=f"Використати наявний чистий клон {REV[:7]}.")
    parser.add_argument("--no-tabs", action="store_true", help="Запустити API й Android без браузера та VS Code.")
    args = parser.parse_args()
    sdk = Path(os.getenv("ANDROID_SDK_ROOT") or os.getenv("ANDROID_HOME") or Path.home() / "Library/Android/sdk")
    emulator = sdk / "emulator/emulator"
    platform_adb = sdk / "platform-tools/adb"
    java = Path(os.getenv("JAVA_HOME") or "/opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home")
    for tool in (emulator, platform_adb, java / "bin/java"):
        if not tool.is_file():
            raise RuntimeError(f"Не знайдено {tool}. Потрібні Android SDK і JDK 17.")
    for tool in ("git", "dotnet"):
        if not shutil.which(tool):
            raise RuntimeError(f"Не знайдено {tool}. Потрібні Git та .NET SDK 10 з maui-android.")
    if "mpp_phone" not in run(str(emulator), "-list-avds").splitlines():
        raise RuntimeError("Не знайдено AVD mpp_phone. Створи його в Android Device Manager.")
    CACHE.mkdir(parents=True, exist_ok=True)
    with ExitStack() as scope:
        lock = scope.enter_context((CACHE / "demo.lock").open("a"))
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise RuntimeError("Демо вже запущено. Для повтору натисни Ctrl+C у його терміналі.") from None
        logs = Path(tempfile.mkdtemp(prefix="run-", dir=CACHE))
        print(f"Журнали запуску: {logs}")
        source = prepare_source(args.source)
        android_rid = {"arm64": "android-arm64", "x86_64": "android-x64"}.get(platform.machine())
        if android_rid is None:
            raise RuntimeError("Не вдалося визначити архітектуру Android для цього Mac.")
        port = next((p for p in [5000, *range(15580, 15600)] if free(p)), None)
        emu_port = next((p for p in range(5580, 5600, 2) if free(p) and free(p + 1)), None)
        if port is None or emu_port is None:
            raise RuntimeError("Немає вільного локального порту для API або емулятора.")
        base = f"http://127.0.0.1:{port}"
        address = f"http://10.0.2.2:{port}"
        serial = f"emulator-{emu_port}"
        print(f"Запускаю mpp_phone ({serial}).")
        emu_log = scope.enter_context((logs / "emulator.log").open("w"))
        emulator_process = subprocess.Popen(
            [str(emulator), "-avd", "mpp_phone", "-port", str(emu_port), "-memory", "2048", "-no-snapshot", "-no-audio"],
            stdout=emu_log, stderr=subprocess.STDOUT, start_new_session=True, env=isolate_avd(scope))
        scope.callback(stop, emulator_process)

        def adb(*command, timeout=30):
            if emulator_process.poll() is not None:
                raise RuntimeError(f"Емулятор завершив роботу. Відкрий {logs / 'emulator.log'}.")
            return run(str(platform_adb), "-s", serial, *command, timeout=timeout)

        build_log = scope.enter_context((logs / "build.log").open("w"))
        print(f"Збираю API та Android із {REV[:7]}. Перша Android-збірка може тривати кілька хвилин.")
        try:
            subprocess.run(["dotnet", "build", "src/IoT.Api", "--nologo"],
                           cwd=source, stdout=build_log, stderr=subprocess.STDOUT, check=True, timeout=480)
            subprocess.run(["dotnet", "build", "src/IoT.Mobile", "--nologo", "-f", "net10.0-android",
                            "-r", android_rid, "-p:EmbedAssembliesIntoApk=true", f"-p:JavaSdkDirectory={java}", f"-p:AndroidSdkDirectory={sdk}"],
                           cwd=source, stdout=build_log, stderr=subprocess.STDOUT, check=True, timeout=720)
        except subprocess.SubprocessError:
            raise RuntimeError(f"Помилка або таймаут збірки. Відкрий {logs / 'build.log'}. Якщо бракує MAUI, виконай dotnet workload restore src/IoT.Mobile/IoT.Mobile.csproj у клоні.") from None

        env = dict(os.environ, ASPNETCORE_ENVIRONMENT="Development",
                   Auth__AllowDevTokens="true", Auth__SigningKey=secrets.token_hex(32),
                   ConnectionStrings__Default=f"Data Source={logs / 'demo.db'}")
        api_log = scope.enter_context((logs / "api.log").open("w"))
        api_process = subprocess.Popen(
            ["dotnet", "src/IoT.Api/bin/Debug/net10.0/IoT.Api.dll", "--urls", base],
            cwd=source, env=env, stdout=api_log, stderr=subprocess.STDOUT, start_new_session=True)
        scope.callback(stop, api_process)
        token = prepare_api(base)
        print(f"API готовий на {base}. Створено Demo sensor, правило 0–40 і два вимірювання.")
        wait_for(f"завантаження {serial}", lambda: adb("shell", "getprop", "sys.boot_completed") == "1", 180)
        adb("shell", "cmd", "connectivity", "airplane-mode", "disable")
        adb("shell", "svc", "wifi", "enable")
        apk = source / "src/IoT.Mobile/bin/Debug/net10.0-android" / android_rid / f"{PACKAGE}-Signed.apk"
        print("Встановлюю APK та підключаю Android до API.")
        installed = False
        try:
            # Install from a local file so package extraction does not depend on an ADB stream.
            guest_apk = "/data/local/tmp/mpp-iot-defense.apk"
            adb("push", str(apk), guest_apk, timeout=90)
            if adb("shell", "pm", "install", "-r", guest_apk, timeout=120) != "Success":
                raise RuntimeError("Android не встановив APK.")
            installed = True
            activities = adb("shell", "cmd", "package", "resolve-activity", "--brief", PACKAGE).splitlines()
            component = next((line for line in activities if line.startswith(PACKAGE + "/")), None)
            if component is None:
                raise RuntimeError("Android не знайшов головний екран IoT Diagnostics.")
            wait_for("запуску IoT Diagnostics", lambda: "Starting:" in adb("shell", "am", "start", "-n", component, timeout=10), 55)
            connect_android(adb, address, token)
            print(f"Готово. Android {address} · Demo sensor вибрано.")
        except (RuntimeError, subprocess.SubprocessError) as error:
            try:
                (logs / "android-crash.log").write_text(adb("logcat", "-d", "-b", "crash", timeout=10))
            except (RuntimeError, subprocess.SubprocessError):
                pass
            detail = str(error) if isinstance(error, RuntimeError) else "ADB не завершив операцію."
            print(f"Підготовка Android не завершилася. {detail}")
            if installed:
                print(f"Для ручного підключення введи {address}. Створи свіжий токен за інструкцією E3.")
            else:
                print(f"API працює на {base}. Діагностика Android: {logs}.")
        if not args.no_tabs:
            open_materials(source)
        print("Залиш термінал відкритим на час показу. Ctrl+C зупиняє це демо.")
        while emulator_process.poll() is None:
            if api_process.poll() is not None:
                raise RuntimeError(f"API завершив роботу. Відкрий {logs / 'api.log'}.")
            time.sleep(1)

try:
    main()
except KeyboardInterrupt:
    print("\nДемо завершено.")
except (OSError, RuntimeError, subprocess.SubprocessError) as error:
    if isinstance(error, subprocess.SubprocessError):
        name = Path(error.cmd[0]).name if isinstance(error.cmd, (list, tuple)) else "команда"
        print(f"Не вдалося виконати {name}. Перевір журнали запуску.")
    else:
        print(f"Запуск перервано. {error}")
    raise SystemExit(1)
PY
