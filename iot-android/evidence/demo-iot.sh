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
import shutil
import socket
import subprocess
import tempfile
import time
from urllib.request import Request, urlopen

ROOT = "https://git.cvv-sandbox.eu.cc/Nazar/iot-diagnostic"
REMOTE_API = "https://git.cvv-sandbox.eu.cc/iot-diagnostic/"
SCENARIO = "https://tzahorskyi.github.io/mpp-defense/iot-android/"
REV = "7198faf5999718bc87c5e4a0b99be4c6899aee0d"
PACKAGE = "com.companyname.iot.mobile"
CACHE = Path.home() / "Library/Caches/mpp-iot-defense"
STEPS = (
    ("android-connect", "Підключення до API", "В Android введи адресу й токен. Натисни «Підключити / оновити», обери свій демонстраційний пристрій."),
    ("opening", "Вступ", "Покажи шапку, картку підключення та пристрої. Назви свою частину проєкту."),
    ("architecture", "Код і редизайн", "У VS Code покажи IoT.Mobile.csproj, BindingContext, MainPage.xaml і команди ViewModel."),
    ("devices", "Пристрої", "Покажи список. Для створення й редагування використай свій тестовий запис Demo CRUD."),
    ("http", "HTTP-тест", "Обери GET, шлях simulator/normal, таймаут 5000. Натисни «Виконати тест» і покажи HTTP 200 та JSON."),
    ("alerts", "Аномалія і графік", "Виконай simulator/out-of-range. Покажи температуру 150, попередження та пік на графіку."),
    ("offline", "Офлайн", "Увімкни режим польоту, вимкни Wi-Fi. Збережи опис android-offline-demo та покажи одну зміну в черзі."),
    ("sync", "Синхронізація", "Віднови Wi-Fi. Натисни «Синхронізувати» та покажи «надіслано 1, відхилено 0» і новий опис."),
    ("git-proof", "Forgejo і мій внесок", "Покажи PR №112, №122 і №124, потім свій коментар та повторне рев’ю у №102."),
    ("actions", "Тести, Actions і підсумок", "Покажи тест перерваної синхронізації, IoT validation №61 і SonarQube №62. Підсумуй показ."),
)

def run(*args, timeout=40):
    return subprocess.check_output(args, timeout=timeout, text=True).strip()

def wait_for(label, read, timeout):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        try:
            result = read()
            if result is not None and result is not False:
                return result
        except subprocess.SubprocessError:
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

def check_remote_api():
    request = Request(REMOTE_API, headers={"User-Agent": "IoTDiagnostics/1.0"})
    try:
        with urlopen(request, timeout=5) as response:
            health = json.load(response)
        if isinstance(health, dict) and health.get("name") == "IoT Diagnostics API" and health.get("status") == "ok":
            print(f"Спільний API відповідає: {REMOTE_API}")
            return
    except (OSError, ValueError):
        pass
    print(f"Перевір доступ до спільного API: {REMOTE_API}")

def show_guide(terminal):
    index = 0
    while index < len(STEPS):
        anchor, title, cue = STEPS[index]
        section = f"{SCENARIO}#{anchor}"
        print(f"\nКрок {index + 1:02}/{len(STEPS):02} · {title}\n{cue}\n{section}")
        if anchor == "android-connect":
            print(f"Адреса сервера в Android · {REMOTE_API}")
            print("Встав виданий командою токен у «Токен доступу» до поширення екрана.")
        while True:
            print("Enter · далі | o · відкрити розділ | b · назад | q · завершити підказки > ", end="", flush=True)
            answer = terminal.readline()
            if not answer or answer.strip().lower() == "q":
                return
            command = answer.strip().lower()
            if command == "":
                index += 1
                break
            if command == "b" and index > 0:
                index -= 1
                break
            if command == "o":
                subprocess.run(["open", section], check=False)
            else:
                print("Натисни Enter або введи одну з команд вище.")
    print("Усі кроки показу завершено.")

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
                    ROOT + "/actions/runs/62", SCENARIO + "#android-connect"], check=False)

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
    parser = argparse.ArgumentParser(prog="demo-iot.sh", description="Запустити Android і вести показ зі спільним API IoT Diagnostic Platform.")
    parser.add_argument("--source", type=Path, help=f"Використати наявний чистий клон {REV[:7]}.")
    parser.add_argument("--no-tabs", action="store_true", help="Запустити Android без браузера та VS Code.")
    parser.add_argument("--guide", action="store_true", help="Відкрити лише покрокові підказки для вже запущеного проєкту.")
    args = parser.parse_args()
    try:
        terminal = open("/dev/tty", encoding="utf-8")
    except OSError:
        raise RuntimeError("Відкрий скрипт в інтерактивному терміналі для керування через Enter.") from None
    with terminal:
        check_remote_api()
        if args.guide:
            show_guide(terminal)
        else:
            launch_demo(args, terminal)

def launch_demo(args, terminal):
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
            raise RuntimeError("Демо вже запущено. Для підказок у новому терміналі виконай ./demo-iot.sh --guide.") from None
        logs = Path(tempfile.mkdtemp(prefix="run-", dir=CACHE))
        print(f"Журнали запуску: {logs}")
        source = prepare_source(args.source)
        android_rid = {"arm64": "android-arm64", "x86_64": "android-x64"}.get(platform.machine())
        if android_rid is None:
            raise RuntimeError("Не вдалося визначити архітектуру Android для цього Mac.")
        emu_port = next((p for p in range(5580, 5600, 2) if free(p) and free(p + 1)), None)
        if emu_port is None:
            raise RuntimeError("Немає вільного локального порту для емулятора.")
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
        print(f"Збираю Android із {REV[:7]}. Перша збірка може тривати кілька хвилин.")
        try:
            subprocess.run(["dotnet", "build", "src/IoT.Mobile", "--nologo", "-f", "net10.0-android",
                            "-r", android_rid, "-p:EmbedAssembliesIntoApk=true", f"-p:JavaSdkDirectory={java}", f"-p:AndroidSdkDirectory={sdk}"],
                           cwd=source, stdout=build_log, stderr=subprocess.STDOUT, check=True, timeout=720)
        except subprocess.SubprocessError:
            raise RuntimeError(f"Помилка або таймаут збірки. Відкрий {logs / 'build.log'}. Якщо бракує MAUI, виконай dotnet workload restore src/IoT.Mobile/IoT.Mobile.csproj у клоні.") from None

        wait_for(f"завантаження {serial}", lambda: adb("shell", "getprop", "sys.boot_completed") == "1", 180)
        adb("shell", "cmd", "connectivity", "airplane-mode", "disable")
        adb("shell", "svc", "wifi", "enable")
        apk = source / "src/IoT.Mobile/bin/Debug/net10.0-android" / android_rid / f"{PACKAGE}-Signed.apk"
        print("Встановлюю APK та відкриваю IoT Diagnostics.")
        try:
            # Install from a local file so package extraction does not depend on an ADB stream.
            guest_apk = "/data/local/tmp/mpp-iot-defense.apk"
            adb("push", str(apk), guest_apk, timeout=90)
            if adb("shell", "pm", "install", "-r", guest_apk, timeout=120) != "Success":
                raise RuntimeError("Android не встановив APK.")
            activities = adb("shell", "cmd", "package", "resolve-activity", "--brief", PACKAGE).splitlines()
            component = next((line for line in activities if line.startswith(PACKAGE + "/")), None)
            if component is None:
                raise RuntimeError("Android не знайшов головний екран IoT Diagnostics.")
            wait_for("запуску IoT Diagnostics", lambda: "Starting:" in adb("shell", "am", "start", "-n", component, timeout=10), 55)
            print("IoT Diagnostics відкрито. Далі керуй показом у терміналі.")
        except (RuntimeError, subprocess.SubprocessError) as error:
            try:
                (logs / "android-crash.log").write_text(adb("logcat", "-d", "-b", "crash", timeout=10))
            except (RuntimeError, subprocess.SubprocessError):
                pass
            detail = str(error) if isinstance(error, RuntimeError) else "ADB не завершив операцію."
            print(f"Підготовка Android не завершилася. {detail}")
            print(f"В Android відкрий IoT Diagnostics. Діагностика: {logs}.")
        if not args.no_tabs:
            open_materials(source)
        show_guide(terminal)
        print("Емулятор залишається відкритим. Ctrl+C зупиняє цей емулятор.")
        emulator_process.wait()

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
