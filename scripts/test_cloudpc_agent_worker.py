"""Dependency-free tests for the isolated Cloud PC agent worker."""
import importlib.util
from pathlib import Path
import os
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location(
    "vortex_agent_worker", Path(__file__).with_name("cloudpc-agent-worker.py"))
worker = importlib.util.module_from_spec(spec)
spec.loader.exec_module(worker)


class FakeGateway:
    def __init__(self, replies=None):
        self.replies = replies or []
        self.messages = []
        self.checks = 0
    def check(self, job):
        self.checks += 1
    def model(self, model, messages):
        self.messages.append(list(messages))
        return self.replies.pop(0)


class CloudPCWorkerTests(unittest.TestCase):
    def test_model_tool_call_only_accepts_json_schema(self):
        call = '<tool_call>{"name":"read_file","arguments":{"path":"notes.txt"}}</tool_call>'
        self.assertEqual(worker.parse_tool_call(call), ("read_file", {"path":"notes.txt"}))
        self.assertIsNone(worker.parse_tool_call("I have sent your message"))
        self.assertIsNone(worker.parse_tool_call('<tool_call>{"name":"__import__","arguments":{}}</tool_call>'))
        self.assertIsNone(worker.parse_tool_call('<tool_call>{"name":"write_file","arguments":"hello"}</tool_call>'))

    def test_private_paths_symlinks_and_secrets_are_not_accessible(self):
        with tempfile.TemporaryDirectory() as tmp, tempfile.TemporaryDirectory() as other:
            root = Path(tmp)
            (root / "docs").mkdir()
            self.assertEqual(worker.safe_workpath(root, "docs/notes.txt"), root / "docs/notes.txt")
            for name in ("../outside.txt", "/etc/passwd", "~/secrets"):
                with self.assertRaises(worker.WorkerError):
                    worker.safe_workpath(root, name)
            (root / "outside-link").symlink_to(other, target_is_directory=True)
            with self.assertRaises(worker.WorkerError):
                worker.safe_workpath(root, "outside-link/protected.txt")

    def test_mutating_operations_require_both_agent_and_host_consent(self):
        with tempfile.TemporaryDirectory() as tmp:
            job = {"id":"aj_test","agent_id":"agent-test",
                   "permissions":["files-read", "files-write", "shell"],
                   "allow_actions":False}
            gateway = FakeGateway()
            actions = worker.Actions(job, gateway, tmp, worker.Browser(tmp+"/browser", ""))
            with self.assertRaises(worker.WorkerError):
                actions.call("write_file", {"path":"test.txt","content":"data"})
            with self.assertRaises(worker.WorkerError):
                actions.call("run_command", {"command":"echo okay"})
            self.assertFalse((Path(tmp)/"test.txt").exists())
            job["allow_actions"] = True
            with patch.dict(os.environ, {"VORTEX_ALLOW_WRITES":"1"}):
                actions = worker.Actions(job,gateway,tmp,worker.Browser(tmp+"/browser",""))
                self.assertIn("Wrote", actions.call("write_file", {"path":"test.txt","content":"data"}))
                self.assertEqual(actions.call("read_file", {"path":"test.txt"}),"data")
                with self.assertRaises(worker.WorkerError):
                    actions.call("write_file", {"path":".","content":"must not escape"})
            self.assertEqual((Path(tmp)/"test.txt").read_text(),"data")
            with self.assertRaises(worker.WorkerError):
                actions.call("run_command",{"command":"echo not-approved-by-host"})

    def test_agent_uses_actual_tool_result_without_claiming_an_action(self):
        with tempfile.TemporaryDirectory() as tmp:
            (Path(tmp)/"notes.txt").write_text("verified testing evidence")
            goal="Read notes.txt and report its contents"
            job={"id":"aj_test","agent_id":"ag1","model":"vortex",
                 "goal":goal,"system":"Be accurate", "permissions":["files-read"],
                 "allow_actions":False,"history":[]}
            gateway=FakeGateway([
                '<tool_call>{"name":"read_file","arguments":{"path":"notes.txt"}}</tool_call>',
                "File contents are: verified testing evidence.",
            ])
            actions=worker.Actions(job,gateway,tmp,worker.Browser(tmp+"/browser",""))
            answer=worker.execute_job(job,gateway,actions)
            self.assertIn("verified testing evidence",answer)
            self.assertEqual(len(gateway.messages),2)
            self.assertIn("TOOL_RESULT read_file",gateway.messages[1][-1]["content"])
            self.assertGreater(gateway.checks,1)

    def test_browser_domain_allowlist_uses_exact_hostname_boundary(self):
        # Stub DNS results so tests run offline.
        with patch.object(worker.socket,"getaddrinfo",
                          return_value=[(2,1,6,"",("93.184.215.14",443))]):
            self.assertEqual(worker.permitted_site("https://chat.example.com/help",["example.com"]),
                             "https://chat.example.com/help")
            with self.assertRaises(worker.WorkerError):
                worker.permitted_site("https://notexample.com/",["example.com"])
            with self.assertRaises(worker.WorkerError):
                worker.permitted_site("https://127.0.0.1/private",["127.0.0.1"])
            with self.assertRaises(worker.WorkerError):
                worker.permitted_site("http://chat.example.com/",["example.com"])

    def test_gateway_base_and_key_contract(self):
        self.assertEqual(worker.safe_base("https://example.org/v1/"),"https://example.org/v1")
        with self.assertRaises(worker.WorkerError):worker.safe_base("http://public.example/v1")
        with self.assertRaises(worker.WorkerError):worker.safe_base("https://api.example.org/v1?token=secret")
        with self.assertRaises(worker.WorkerError):
            worker.Gateway("https://example.org/v1","not-a-vortex-api-key","cloudpc-test")


if __name__ == "__main__":
    unittest.main()
