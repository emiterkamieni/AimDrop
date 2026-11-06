import errno
import http.client
import json
import os
from pathlib import Path
import plistlib
import socket
import ssl
import subprocess
import sys
import tempfile
import unittest
import uuid
from concurrent.futures import ThreadPoolExecutor
from unittest.mock import patch

from receiver import localization as l10n
from receiver.configuration import normalized_receiver_name
from tests.fixtures import archive, request
from tests.test_buffered_flow import ROOT, Worker


class LocalizationTests(unittest.TestCase):
    def setUp(self):
        previous = l10n.language_code()
        self.addCleanup(l10n.configure, previous)
        l10n.configure("en")

    def test_supported_languages_and_invalid_selection(self):
        self.assertEqual(len(l10n.LANGUAGES), 15)
        for language in l10n.LANGUAGES:
            l10n.configure(language)
            self.assertEqual(l10n.language_code(), language)
            self.assertEqual(l10n.text("Unique test fallback", "Zapasowy tekst próby"),
                             "Zapasowy tekst próby" if language == "pl" else "Unique test fallback")
        for invalid in (None, [], "system", "fr-FR", "xx", True):
            with self.assertRaises(ValueError):
                l10n.configure(invalid)
            self.assertEqual(l10n.language_code(), "zh-Hant")

    def test_authored_error_is_localized_when_rendered(self):
        with self.assertRaises(ValueError) as caught:
            normalized_receiver_name(None)
        self.assertEqual(l10n.error_message(caught.exception), "The receiver name must be text.")
        l10n.configure("pl")
        self.assertEqual(l10n.error_message(caught.exception), "Nazwa odbiornika musi być tekstem.")
        nested = RuntimeError(l10n.message("Cannot use the selected folder: %s", "Nie można użyć wybranego folderu: %s",
                                          PermissionError(errno.EACCES, "raw operating system message")))
        self.assertEqual(l10n.error_message(nested), "Nie można użyć wybranego folderu: Brak uprawnień do pliku lub folderu.")
        l10n.configure("en")
        self.assertEqual(l10n.error_message(nested), "Cannot use the selected folder: Permission to access the file or folder was denied.")

    def test_system_errors_use_selected_language_and_keep_relevant_paths(self):
        error = FileNotFoundError(errno.ENOENT, "raw system message", "/Volumes/Example/photo.jpg")
        self.assertEqual(l10n.error_message(error), "The file or folder no longer exists. /Volumes/Example/photo.jpg")
        l10n.configure("pl")
        self.assertEqual(l10n.error_message(error), "Plik lub folder już nie istnieje. /Volumes/Example/photo.jpg")
        self.assertEqual(l10n.error_message(TimeoutError()), "Upłynął czas oczekiwania na połączenie.")
        self.assertNotIn("private diagnostic", l10n.error_message(ValueError("private diagnostic")))

    def test_shared_json_catalog_lookup_in_source_and_bundle_layouts(self):
        with tempfile.TemporaryDirectory(prefix="aimdrop-l10n-") as directory:
            root = Path(directory)
            for source in (root / "source/receiver/localization.py",
                           root / "AimDrop.app/Contents/Resources/receiver/localization.py"):
                resources = source.parent.parent
                if resources.name != "Resources":
                    resources /= "Resources"
                catalogs = resources / "Localizations"
                catalogs.mkdir(parents=True)
                (catalogs / "fr.json").write_text(json.dumps({
                    "The receiver name must be text.": "Le nom du récepteur doit être du texte.",
                    "Test %s": "Essai %s",
                }), encoding="utf-8")
                with self.subTest(source=source), patch.object(l10n, "__file__", str(source)), patch.object(l10n, "_catalogs", {}):
                    l10n.configure("fr")
                    self.assertEqual(l10n.text("The receiver name must be text.", "unused"), "Le nom du récepteur doit être du texte.")
                    self.assertEqual(str(l10n.message("Test %s", "Próba %s", "ok")), "Essai ok")
                    self.assertEqual(l10n.text("Missing source", "unused"), "Missing source")
                    l10n.configure("pl")
                    self.assertEqual(l10n.text("Missing source", "Zapasowy tekst"), "Zapasowy tekst")

    def test_concurrent_switches_keep_complete_translations(self):
        def render(index):
            l10n.configure("en" if index % 2 else "pl")
            return l10n.text("Concurrent fixture", "Próba współbieżności")
        with ThreadPoolExecutor(max_workers=8) as pool:
            self.assertTrue(set(pool.map(render, range(500))) <= {"Concurrent fixture", "Próba współbieżności"})


class WorkerLanguageTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="aimdrop-language-worker-")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name).resolve()
        self.log = (self.root / "worker.log").open("w")
        self.addCleanup(self.log.close)

    def start_worker(self):
        worker = Worker(self.root / "state", self.log, setup="sys.argv += ['--language', 'en', '--name', 'My receiver']")
        self.addCleanup(worker.close)
        worker.event("pending")
        return worker

    def change(self, worker, language):
        request_id = str(uuid.uuid4()).upper()
        worker.command(dict(command="set_language", request_id=request_id, language=language))
        result = worker.event("language_result")
        self.assertEqual(result["request_id"], request_id)
        return result

    def invalid_name(self, worker):
        worker.command(dict(command="set_name", request_id=str(uuid.uuid4()), name=None))
        result = worker.event("name_result")
        self.assertIs(result["ok"], False)
        self.assertEqual(result["name"], "My receiver")
        return result["message"]

    def test_startup_default_environment_and_cli_precedence_before_validation(self):
        cases = [(None, [], "The receiver name"), ("pl", [], "Nazwa odbiornika"),
                 ("pl", ["--language", "en"], "The receiver name"),
                 ("en", ["--language", "pl"], "Nazwa odbiornika")]
        for index, (environment, arguments, expected) in enumerate(cases):
            env = dict(os.environ)
            env.pop("AIMDROP_LANGUAGE", None)
            if environment is not None:
                env["AIMDROP_LANGUAGE"] = environment
            state = self.root / str(index)
            with self.subTest(environment=environment, arguments=arguments):
                result = subprocess.run([sys.executable, "-I", "-B", str(ROOT / "receiver/main.py"),
                                         "--state-dir", str(state), "--name", "Private\nname", *arguments],
                                        input="", text=True, capture_output=True, env=env, timeout=10)
                self.assertNotEqual(result.returncode, 0)
                event = json.loads(result.stdout)
                self.assertTrue(event["fatal"])
                self.assertIn(expected, event["message"])
                self.assertFalse(state.exists())
                self.assertNotIn("Private", result.stdout + result.stderr)

    def test_language_switch_during_upload_preserves_socket_profile_and_identity(self):
        worker = self.start_worker()
        state = self.root / "state"
        pairing = state / "Pairing"
        pairing.mkdir()
        (pairing / "profile-fixture").write_bytes(b"name-and-avatar-pairing-must-survive")
        preserved = {path: path.read_bytes() for path in
                     [state / "identity.json", state / "certificate.pem", state / "private-key.pem", pairing / "profile-fixture"]}
        before = worker.post("/Discover", plistlib.dumps({}))[1]
        pid, port = worker.process.pid, worker.port
        transfer = str(uuid.uuid4())
        self.assertEqual(worker.post("/Ask", plistlib.dumps(request(transfer)))[0], 200)
        incoming = worker.event("incoming")
        contents = bytes(range(256)) * 1024
        payload = archive([("test.txt", contents)])
        raw = socket.create_connection(("::1", port), timeout=5)
        with ssl._create_unverified_context().wrap_socket(raw, server_hostname="localhost") as secure:
            headers = ("POST /Upload HTTP/1.1\r\nContent-Type: application/x-cpio\r\n"
                       "TransferID: %s\r\nContent-Length: %d\r\n\r\n" % (transfer, len(payload))).encode()
            secure.sendall(headers + payload[:65536])
            worker.event("progress")
            self.assertEqual(self.invalid_name(worker), "The receiver name must be text.")
            for language in l10n.LANGUAGES:
                result = self.change(worker, language)
                self.assertIs(result["ok"], True)
                self.assertEqual(result["language"], language)
                self.assertNotIn("pairing_reset", result)
            self.change(worker, "pl")
            self.assertEqual(self.invalid_name(worker), "Nazwa odbiornika musi być tekstem.")
            for invalid in ("system", "xx", None, [], True):
                failure = self.change(worker, invalid)
                self.assertIs(failure["ok"], False)
                self.assertEqual(failure["language"], "pl")
                self.assertEqual(failure["message"], "Nieobsługiwany język aplikacji.")
            secure.sendall(payload[65536:])
            response = http.client.HTTPResponse(secure)
            response.begin()
            self.assertEqual(response.status, 200)
            response.read()
        downloaded = worker.event("downloaded")
        self.assertEqual(downloaded["id"], incoming["id"])
        self.assertEqual(Path(downloaded["paths"][0]).read_bytes(), contents)
        self.assertEqual(worker.post("/Discover", plistlib.dumps({}))[1], before)
        self.assertEqual(worker.process.pid, pid)
        self.assertEqual(worker.port, port)
        self.assertIsNone(worker.process.poll())
        for path, data in preserved.items():
            self.assertEqual(path.read_bytes(), data)
        self.assertEqual(sum(event["event"] == "ready" for event in worker.observed), 1)
        self.assertFalse(any(event["event"] in ("error", "canceled", "pairing_pin") for event in worker.observed))

    def test_save_error_uses_live_language_and_retains_buffer(self):
        worker = self.start_worker()
        ident = str(uuid.uuid4())
        self.assertEqual(worker.post("/Ask", plistlib.dumps(request(ident)))[0], 200)
        self.assertEqual(worker.post("/Upload", archive([("test.txt", b"keep this")]),
                                     {"TransferID": ident, "Content-Type": "application/x-cpio"})[0], 200)
        receipt = worker.event("downloaded")
        for language, expected in (("pl", "Plik lub folder już nie istnieje."),
                                   ("en", "The file or folder no longer exists.")):
            self.change(worker, language)
            worker.command(dict(command="save", id=receipt["id"], directory=str(self.root / "missing")))
            while True:
                event = worker.events.get(timeout=10)
                if event["event"] == "error":
                    break
            self.assertEqual(event["id"], receipt["id"])
            self.assertEqual(event["phase"], "saving")
            self.assertTrue(event["message"].startswith(expected))
            worker.event("pending")
            self.assertEqual(Path(receipt["paths"][0]).read_bytes(), b"keep this")
