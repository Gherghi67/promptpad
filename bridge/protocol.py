"""Strict wire validation; deliberately has no iTerm2 dependency."""

import json
import re
import struct
import unicodedata

MAX_FRAME = 65536
MAX_LINE = 9007199254740991
CONTROLS = {"enter": "\r", "escape": "\x1b", "tab": "\t", "interrupt": "\x03"}
DIRECTIONS = {"left", "right", "up", "down"}
FIELDS = {
    "ping": set(), "capture_target": set(), "insert_text": {"text"},
    "control": {"control"}, "select_tab": {"tab_direction"},
    "select_pane": {"direction"}, "authorize_key": {"direction"},
    "read_scrollback": {"line_count"},
}
UUID = re.compile(r"[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}\Z")
WHITESPACE = set(range(9, 14)) | {32, 0x85, 0xA0, 0x1680, 0x2028, 0x2029,
                                          0x202F, 0x205F, 0x3000} | set(range(0x2000, 0x200B))


class Failure(Exception):
    def __init__(self, code, message):
        super().__init__(message)
        self.code = code
        self.message = message


class Invalid(Failure):
    def __init__(self):
        super().__init__("invalid_request", "Request does not match protocol 1.")


def utf8(value):
    if type(value) is not str:
        raise Invalid()
    try:
        return value.encode("utf-8")
    except UnicodeError:
        raise Invalid() from None


def sanitize(text):
    output = []
    space = False
    for char in text:
        category = unicodedata.category(char)
        if category == "Cf":
            continue
        if ord(char) in WHITESPACE:
            space = bool(output)
            continue
        if category == "Cc":
            continue
        if space:
            output.append(" ")
            space = False
        output.append(char)
    return "".join(output)


def validate_target(target):
    if type(target) is not dict or set(target) != {"session_id", "window_id", "tab_id", "title"}:
        raise Invalid()
    for key in ("session_id", "window_id", "tab_id"):
        value = target[key]
        if not 1 <= len(utf8(value)) <= 256 or any(ord(c) < 32 or ord(c) == 127 for c in value):
            raise Invalid()
    if len(utf8(target["title"])) > 1024:
        raise Invalid()


def valid_id(value):
    return type(value) is str and UUID.fullmatch(value) is not None


def validate(request):
    if type(request) is not dict or not valid_id(request.get("id")):
        raise Invalid()
    if type(request.get("version")) is not int:
        raise Invalid()
    if request["version"] != 1:
        raise Failure("unsupported_version", "Expected protocol version 1.")
    operation = request.get("operation")
    if type(operation) is not str or operation not in FIELDS:
        raise Invalid()
    required = {"version", "id", "operation"} | FIELDS[operation]
    if operation not in {"ping", "capture_target"}:
        required.add("target")
        validate_target(request.get("target"))
    optional = {"first_line"} if operation == "read_scrollback" else set()
    if not required <= set(request) or not set(request) <= required | optional:
        raise Invalid()
    for key, choices in (("control", CONTROLS), ("direction", DIRECTIONS),
                         ("tab_direction", {"previous", "next"})):
        if key in request and (type(request[key]) is not str or request[key] not in choices):
            raise Invalid()
    if operation == "insert_text":
        text = request["text"]
        if len(utf8(text)) > 8192:
            raise Failure("too_large", "Transcript exceeds 8192 UTF-8 bytes.")
        if not text or sanitize(text) != text:
            raise Invalid()
    for key, low, high in (("line_count", 1, 128), ("first_line", 0, MAX_LINE)):
        if key in request and (type(request[key]) is not int or not low <= request[key] <= high):
            raise Invalid()
    return request


def _unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise Invalid()
        result[key] = value
    return result


def decode(payload):
    try:
        return json.loads(payload.decode("utf-8"), object_pairs_hook=_unique_object,
                          parse_constant=lambda _: (_ for _ in ()).throw(Invalid()))
    except (ValueError, UnicodeError, RecursionError):
        raise Invalid() from None


def json_bytes(value):
    return json.dumps(value, ensure_ascii=False, separators=(",", ":"), allow_nan=False).encode("utf-8")


def encode(value):
    payload = json_bytes(value)
    if not 1 <= len(payload) <= MAX_FRAME:
        raise Failure("too_large", "Response exceeds 65536 UTF-8 bytes.")
    return struct.pack("!I", len(payload)) + payload


def success(request, **fields):
    return {"version": 1, "id": request["id"], "ok": True, **fields}


def error(request_id, failure):
    return {"version": 1, "id": request_id, "ok": False,
            "error": {"code": failure.code, "message": failure.message}}
