import io
import json
import unittest
import ui_fixture_server as fixture


class Request:
    def __init__(self, raw):
        self.input = io.BytesIO(raw)
        self.output = bytearray()

    def makefile(self, *_):
        return self.input

    def sendall(self, data):
        self.output.extend(data)


def request(path, method="GET", headers=""):
    connection = Request(f"{method} {path} HTTP/1.0\r\n{headers}\r\n".encode())
    fixture.Handler(connection, ("127.0.0.1", 1234), None)
    head, body = bytes(connection.output).split(b"\r\n\r\n", 1)
    return head.decode(), body


class FixtureTests(unittest.TestCase):
    def setUp(self):
        request("/__reset", "POST")

    def test_sign_in_requires_fixture_credentials(self):
        _, body = request("/rest/ping.view?u=wrong&p=wrong")
        self.assertEqual(json.loads(body)["subsonic-response"]["status"], "failed")
        _, body = request("/rest/ping.view?u=fixture&p=fixture")
        self.assertEqual(json.loads(body)["subsonic-response"]["status"], "ok")

    def test_catalog_paging_and_byte_ranges(self):
        _, first = request("/rest/search3.view?u=fixture&p=fixture")
        _, last = request("/rest/search3.view?u=fixture&p=fixture&songOffset=1")
        self.assertEqual(len(json.loads(first)["subsonic-response"]["searchResult3"]["song"]), 1)
        self.assertEqual(json.loads(last)["subsonic-response"]["searchResult3"]["song"], [])
        head, body = request("/rest/stream.view?u=fixture&p=fixture", headers="Range: bytes=10-19\r\n")
        self.assertIn("206", head)
        self.assertEqual(body, fixture.AUDIO[10:20])

    def test_offline_counts_failed_network_attempts(self):
        request("/__offline", "POST")
        head, _ = request("/rest/stream.view?u=fixture&p=fixture")
        self.assertIn("503", head)
        _, state = request("/__state")
        self.assertEqual(json.loads(state)["mediaRequests"], 1)


if __name__ == "__main__":
    unittest.main()
