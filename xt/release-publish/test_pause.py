import hashlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import subprocess
import tempfile
import threading
import unittest


HERE = Path(__file__).resolve().parent
FILENAME = "Test-Mutation-0.001.tar.gz"
PUBLISHED = "/authors/id/Y/YA/YASUNOBU/" + FILENAME
CONTENT = b"verified archive\x00\xff\n"
DIGEST = hashlib.sha256(CONTENT).hexdigest()


class Request(BaseHTTPRequestHandler):
    def do_GET(self):
        self.server.requests.append((self.command, self.path, self.headers, b""))
        status, body = self.server.replies[self.path]
        self.send_response(status)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass


class Pause(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.build = tempfile.TemporaryDirectory()
        cls.addClassCleanup(cls.build.cleanup)
        cls.binary = Path(cls.build.name) / "pause-fixture"
        subprocess.run(
            ["rustc", "--edition=2021", "-D", "warnings", HERE / "fixture.rs", "-o", cls.binary],
            check=True,
        )

    def setUp(self):
        self.work = tempfile.TemporaryDirectory()
        self.addCleanup(self.work.cleanup)
        self.archive = Path(self.work.name) / FILENAME
        self.archive.write_bytes(CONTENT)
        self.server = ThreadingHTTPServer(("127.0.0.1", 0), Request)
        self.server.requests = []
        self.server.replies = {}
        thread = threading.Thread(target=self.server.serve_forever, kwargs={"poll_interval": 0.01})
        thread.start()
        self.addCleanup(self.server.server_close)
        self.addCleanup(thread.join)
        self.addCleanup(self.server.shutdown)

    def run_adapter(self, *args, token=None):
        env = {"PAUSE_FIXTURE": f"http://127.0.0.1:{self.server.server_port}"}
        if token is not None:
            env["PAUSE_TOKEN"] = token
        return subprocess.run([self.binary, *args], cwd=self.work.name, env=env, capture_output=True)

    def test_matches_the_exact_author_archive(self):
        self.server.replies[PUBLISHED] = (200, CONTENT)
        result = self.run_adapter("reconcile", self.archive, DIGEST)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(DIGEST.encode(), result.stdout)
        self.assertEqual([(method, path) for method, path, _, _ in self.server.requests], [("GET", PUBLISHED)])

    def test_missing_archive_is_distinct_from_a_conflicting_upload_or_provider_error(self):
        for status, body, code in [(404, b"", 3), (200, b"other bytes", 1), (502, CONTENT, 1)]:
            with self.subTest(status=status):
                self.server.replies[PUBLISHED] = (status, body)
                result = self.run_adapter("reconcile", self.archive, DIGEST)
                self.assertEqual(result.returncode, code, result.stderr)

    def test_refuses_changed_local_bytes_before_accessing_the_registry(self):
        self.archive.write_bytes(CONTENT + b"changed")
        result = self.run_adapter("reconcile", self.archive, DIGEST)
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertEqual(self.server.requests, [])

    def test_refuses_another_distribution_or_a_non_release_version(self):
        for name in ["Other-0.001.tar.gz", "Test-Mutation-0.001_01.tar.gz", "Test-Mutation-.tar.gz"]:
            with self.subTest(name=name):
                path = Path(self.work.name) / name
                path.write_bytes(CONTENT)
                self.assertEqual(self.run_adapter("reconcile", path, DIGEST).returncode, 1)
        self.assertEqual(self.server.requests, [])


if __name__ == "__main__":
    unittest.main()
