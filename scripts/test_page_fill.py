#!/usr/bin/env python3
"""Page fill never echoes a value, and it refuses a password box that is not one."""
import os
import unittest
from importlib.machinery import SourceFileLoader

HERE = os.path.dirname(os.path.abspath(__file__))
page_fill = SourceFileLoader("page_fill", os.path.join(HERE, "page-fill.py")).load_module()


class FakeSession:
    def __init__(self, password_type="password"):
        self.calls = []
        self.password_type = password_type

    def call(self, method, params=None):
        self.calls.append((method, params))
        if method == "Runtime.evaluate":
            return {}
        if method == "DOM.getDocument":
            return {"root": {"nodeId": 1}}
        if method == "DOM.querySelector":
            return {"nodeId": 9 if "pass" in params["selector"] else 4}
        if method == "DOM.describeNode":
            return {
                "node": {
                    "nodeName": "INPUT",
                    "attributes": ["type", self.password_type],
                }
            }
        return {}

    def close(self):
        return None


SECRET = "s3cret-value"


class PageFillTest(unittest.TestCase):
    def test_display_port_matches_chromium(self):
        self.assertEqual(page_fill.cdp_port(":1"), 9223)
        self.assertEqual(page_fill.cdp_port(":20"), 9242)

    def test_inserts_text_and_forgets_it(self):
        session = FakeSession()
        fields = [
            {"id": "username", "selector": "#user", "input": "text", "value": "ada"},
            {"id": "password", "selector": "#pass", "input": "password", "value": SECRET},
        ]
        filled = page_fill.fill_with(session, fields)
        self.assertEqual(filled, ["username", "password"])
        inserted = [
            params["text"]
            for method, params in session.calls
            if method == "Input.insertText"
        ]
        self.assertEqual(inserted, ["ada", SECRET])
        self.assertTrue(all(field["value"] == "" for field in fields))

    def test_a_password_target_that_is_plain_text_is_refused(self):
        session = FakeSession(password_type="text")
        fields = [
            {"id": "password", "selector": "#pass", "input": "password", "value": SECRET},
        ]
        with self.assertRaises(page_fill.FillError) as caught:
            page_fill.fill_with(session, fields)
        self.assertEqual(caught.exception.code, "not_a_password_field")
        self.assertNotIn(SECRET, str(caught.exception))
        self.assertTrue(
            all(
                method != "Input.insertText" or SECRET not in (params or {}).get("text", "")
                for method, params in session.calls
            )
        )

    def test_page_script_can_fill_without_dom_fallback(self):
        session = FakeSession()

        def call(method, params=None):
            session.calls.append((method, params))
            if method == "Runtime.enable":
                return {}
            if method == "Runtime.evaluate":
                return {"result": {"value": "ok"}}
            raise AssertionError(method)

        session.call = call
        fields = [{"id": "username", "selector": "#user", "input": "text", "value": "ada"}]
        self.assertEqual(page_fill.fill_with(session, fields), ["username"])
        self.assertEqual(fields[0]["value"], "")
        self.assertTrue(any(method == "Runtime.evaluate" for method, _ in session.calls))

    def test_missing_browser_does_not_include_the_value(self):
        with self.assertRaises(page_fill.FillError) as caught:
            page_fill.fill_display(
                ":20",
                [{"id": "password", "selector": "#pass", "input": "password", "value": SECRET}],
                list_pages_fn=lambda _port: [],
            )
        self.assertEqual(caught.exception.code, "browser_not_open")
        self.assertNotIn(SECRET, str(caught.exception))


if __name__ == "__main__":
    unittest.main()
