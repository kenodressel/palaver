"""The user's own notes on a meeting (#44): what they write before, during
and after it, with pasted images, next to the transcript.

One document per meeting, in the recording folder:

- ``my-notes.json``: a list of paragraphs ``{"text", "at"}``. ``at`` is the
  meeting time in seconds when the paragraph was started, or None (written
  before or after the meeting). A paragraph with ``"image"`` stands for a
  pasted image; its ``text`` is an optional caption. Plain JSON, so search
  can read it as it is.
- ``my-notes/``: the images, and the text macOS Vision read from each
  (``<image>.txt``). Images never leave this Mac: a language model, local
  or in the cloud, gets the text read from them, never the image.

Notes written before a meeting (prep, #31) wait in the config folder under
the calendar event's key until the recording is matched to the event
(``adopt``). Every write is atomic: the app quitting mid-call loses nothing
that was saved.
"""

from __future__ import annotations

import contextlib
import fcntl
import hashlib
import json
import logging
import math
import os
import re
import shutil
import threading
import uuid
from pathlib import Path
from typing import Any, Callable

from ._xdg import xdg_config_home

LOGGER = logging.getLogger(__name__)

FILE = "my-notes.json"
IMAGES = "my-notes"
MAX_PARAGRAPHS = 5000
MAX_TEXT = 20_000  # characters in one paragraph
MAX_IMAGE_BYTES = 25 * 1024 * 1024
MAX_AT = 7 * 24 * 3600.0
IMAGE_NAME = re.compile(r"img-[0-9a-f]{12}\.(?:png|jpg|gif|webp|heic)")
CONTENT_TYPES = {".png": "image/png", ".jpg": "image/jpeg", ".gif": "image/gif", ".webp": "image/webp",
                 ".heic": "image/heic"}
LANGUAGES = ["de-DE", "en-US"]
MAX_READ_PIXELS = 4096  # an image is read scaled down to at most this wide and high
LOCK = ".my-notes.lock"

# One text recognition at a time: pasting ten screenshots runs them in turn.
_READING = threading.Lock()


class Conflict(Exception):
    """The notes changed since the editor read them; ``document`` is how they are now."""

    def __init__(self, document: dict[str, Any]):
        super().__init__("your notes were changed elsewhere in the meantime")
        self.document = document


def _file(folder: Path) -> Path:
    return Path(folder) / FILE


_HELD = threading.local()


@contextlib.contextmanager
def locked(folder: Path):
    """One writer of a folder's notes at a time, across processes (the
    window's server, the processing run matching the calendar event, a
    join after a restart): an flock on a file in the folder. Taken again
    by the same thread, it is already held."""
    folder = Path(folder)
    held = _HELD.__dict__.setdefault("folders", set())
    key = str(folder.resolve()) if folder.exists() else str(folder)
    if key in held:
        yield
        return
    folder.mkdir(parents=True, exist_ok=True)
    with open(folder / LOCK, "a") as f:
        fcntl.flock(f, fcntl.LOCK_EX)
        held.add(key)
        try:
            yield
        finally:
            held.discard(key)
            fcntl.flock(f, fcntl.LOCK_UN)


@contextlib.contextmanager
def _both(a: Path, b: Path):
    """Two folders' locks, always in the same order (no deadlock)."""
    first, second = sorted([Path(a), Path(b)], key=str)
    with locked(first), locked(second):
        yield


def revision(folder: Path) -> str:
    """Changes whenever the notes do; "" for none. An editor saves on the
    revision it read, so nothing written meanwhile is overwritten."""
    try:
        return hashlib.sha256(_file(folder).read_bytes()).hexdigest()[:16]
    except OSError:
        return ""


def _images(folder: Path) -> Path:
    return Path(folder) / IMAGES


def _write_atomic(path: Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name(f".{path.name}.{uuid.uuid4().hex[:8]}.tmp")
    tmp.write_text(text)
    os.replace(tmp, path)


# --- the document ------------------------------------------------------------------------


def _paragraph(p: Any, folder: Path, *, check_image: bool = True) -> dict[str, Any]:
    if not isinstance(p, dict):
        raise ValueError(f"a paragraph is not an object: {p!r}"[:200])
    text, at = p.get("text"), p.get("at")
    if not isinstance(text, str):
        raise ValueError("a paragraph without its text")
    if len(text) > MAX_TEXT:
        raise ValueError(f"a paragraph is longer than {MAX_TEXT:,} characters")
    if at is not None:
        if isinstance(at, bool) or not isinstance(at, (int, float)) or not math.isfinite(at) \
                or not 0 <= at <= MAX_AT:
            raise ValueError(f"not a meeting time: {at!r}"[:200])
        at = round(float(at), 1)
        at = int(at) if at.is_integer() else at
    out: dict[str, Any] = {"text": text, "at": at}
    if p.get("image") is not None:
        name = p["image"]
        if not isinstance(name, str) or not IMAGE_NAME.fullmatch(name):
            raise ValueError(f"not an image of these notes: {name!r}"[:200])
        if check_image and not (_images(folder) / name).is_file():
            raise ValueError(f"no image {name}")
        out["image"] = name
    return out


def _has_content(paragraphs: list[dict]) -> bool:
    return any(p["text"].strip() or p.get("image") for p in paragraphs)


def load(folder: Path) -> list[dict[str, Any]]:
    """The paragraphs; none when there are no notes (or a file no longer
    readable — the paragraphs that still make sense are kept)."""
    try:
        raw = json.loads(_file(folder).read_text())
    except (OSError, ValueError):
        return []
    out = []
    for p in raw if isinstance(raw, list) else []:
        try:
            out.append(_paragraph(p, folder, check_image=False))
        except ValueError:
            continue
    return out


def save(folder: Path, paragraphs: Any, *, base: str | None = None) -> dict[str, Any]:
    """Replace the document (validated: garbage raises ValueError and
    changes nothing). A document with nothing in it leaves no file.
    ``base``: the revision the editor read; when the notes changed since,
    Conflict (with them as they are now) and nothing is written. Returns
    the paragraphs as saved and the new revision."""
    if not isinstance(paragraphs, list):
        raise ValueError("the notes are not a list of paragraphs")
    if len(paragraphs) > MAX_PARAGRAPHS:
        raise ValueError(f"more than {MAX_PARAGRAPHS} paragraphs")
    clean = [_paragraph(p, folder) for p in paragraphs]
    with locked(folder):
        if base is not None and base != revision(folder):
            raise Conflict(document(folder))
        _write(folder, clean)
        return {"paragraphs": clean, "revision": revision(folder)}


def put_back(folder: Path, paragraphs: list[dict], *, after: dict | None = None) -> None:
    """Paragraphs taken out (an image deleted, the notes cleared) back into
    the notes as they are now, whatever was written since: after ``after``
    when it is still there, else by time — those without one before the
    first with one. Paragraphs already there are not put in twice."""
    with locked(folder):
        current = load(folder)
        anchor = current.index(after) + 1 if after is not None and after in current else None
        untimed = 0
        for p in paragraphs:
            p = _paragraph(p, folder, check_image=False)
            if p in current:
                continue
            if anchor is not None:
                i = anchor
                anchor += 1
            elif p["at"] is None:
                i = next((k for k, q in enumerate(current) if q["at"] is not None), len(current))
                i = min(i, untimed) if untimed else i
                untimed = i + 1
            else:
                later = [k for k, q in enumerate(current) if q["at"] is not None and q["at"] > p["at"]]
                timed = [k for k, q in enumerate(current) if q["at"] is not None]
                i = later[0] if later else (timed[-1] + 1 if timed else len(current))
            current.insert(i, p)
        _write(folder, current)


def _write(folder: Path, paragraphs: list[dict]) -> None:
    paragraphs = [_paragraph(p, folder, check_image=False) for p in paragraphs]  # times rounded alike
    if _has_content(paragraphs):
        _write_atomic(_file(folder), json.dumps(paragraphs, indent=1, ensure_ascii=False))
    else:
        _file(folder).unlink(missing_ok=True)


def document(folder: Path) -> dict[str, Any]:
    """What the editor shows: the paragraphs, and for each image the text
    read from it (None while it is still being read)."""
    paragraphs = load(folder)
    return {"paragraphs": paragraphs,
            "images": {p["image"]: {"text": image_text(folder, p["image"])} for p in paragraphs if p.get("image")},
            "revision": revision(folder)}


def files(folder: Path) -> list[Path]:
    """Every file of the notes: what an undo snapshot of them holds."""
    out = [_file(folder)]
    images = _images(folder)
    if images.is_dir():
        out += sorted(p for p in images.iterdir() if p.is_file() and not p.name.startswith("."))
    return out


def clear(folder: Path) -> None:
    """No notes any more: the document, the images and their text."""
    with locked(folder):
        for f in files(folder):
            f.unlink(missing_ok=True)


# --- images ------------------------------------------------------------------------------


def _kind(data: bytes) -> str | None:
    """The file extension for image bytes, by their signature."""
    if data.startswith(b"\x89PNG\r\n\x1a\n"):
        return "png"
    if data.startswith(b"\xff\xd8\xff"):
        return "jpg"
    if data[:6] in (b"GIF87a", b"GIF89a"):
        return "gif"
    if data[:4] == b"RIFF" and data[8:12] == b"WEBP":
        return "webp"
    if data[4:8] == b"ftyp" and data[8:12] in (b"heic", b"heix", b"mif1", b"msf1", b"heim", b"heis"):
        return "heic"
    return None


def add_image(folder: Path, data: bytes) -> str:
    """Store a pasted or dropped image; returns its name. Only images."""
    if len(data) > MAX_IMAGE_BYTES:
        raise ValueError(f"the image is too large (at most {MAX_IMAGE_BYTES // (1024 * 1024)} MB)")
    kind = _kind(data)
    if kind is None:
        raise ValueError("not an image (PNG, JPEG, GIF, WebP or HEIC)")
    name = f"img-{uuid.uuid4().hex[:12]}.{kind}"
    path = _images(folder) / name
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name(f".{name}.tmp")
    tmp.write_bytes(data)
    os.replace(tmp, path)
    return name


def image_path(folder: Path, name: str) -> Path:
    if not IMAGE_NAME.fullmatch(name or ""):
        raise ValueError(f"not an image name: {name!r}"[:200])
    path = _images(folder) / name
    if not path.is_file():
        raise FileNotFoundError(name)
    return path


def content_type(name: str) -> str:
    return CONTENT_TYPES.get(Path(name).suffix.lower(), "application/octet-stream")


def _text_file(folder: Path, name: str) -> Path:
    return _images(folder) / f"{name}.txt"


def image_text(folder: Path, name: str) -> str | None:
    """The text read from an image; None when it was not read yet."""
    try:
        return _text_file(folder, name).read_text()
    except OSError:
        return None


def _scaled_image(path: Path):
    """The image as a CGImage at most MAX_READ_PIXELS wide and high, decoded
    scaled down (ImageIO): a huge image never reaches Vision whole."""
    import Foundation
    import Quartz

    source = Quartz.CGImageSourceCreateWithURL(Foundation.NSURL.fileURLWithPath_(str(path)), None)
    if source is None:
        raise RuntimeError("not an image ImageIO can read")
    image = Quartz.CGImageSourceCreateThumbnailAtIndex(source, 0, {
        Quartz.kCGImageSourceCreateThumbnailFromImageAlways: True,
        Quartz.kCGImageSourceThumbnailMaxPixelSize: MAX_READ_PIXELS,
        Quartz.kCGImageSourceCreateThumbnailWithTransform: True,
    })
    if image is None:
        raise RuntimeError("the image could not be decoded")
    return image


def recognize_text(path: Path) -> str:
    """The text in an image, by macOS Vision (German and English), line by
    line from the top. On this Mac; nothing is downloaded."""
    import Vision

    request = Vision.VNRecognizeTextRequest.alloc().init()
    request.setRecognitionLevel_(Vision.VNRequestTextRecognitionLevelAccurate)
    request.setRecognitionLanguages_(LANGUAGES)
    request.setUsesLanguageCorrection_(True)
    handler = Vision.VNImageRequestHandler.alloc().initWithCGImage_options_(_scaled_image(path), {})
    ok, error = handler.performRequests_error_([request], None)
    if not ok:
        raise RuntimeError(f"Vision could not read the image: {error}")
    lines = []
    for observation in request.results() or []:
        candidates = observation.topCandidates_(1)
        if not candidates:
            continue
        box = observation.boundingBox()
        # Vision's origin is the bottom left: top to bottom, then left to right.
        lines.append((-round(box.origin.y + box.size.height, 2), box.origin.x, str(candidates[0].string())))
    return "\n".join(text for _, _, text in sorted(lines))


def read_image(folder: Path, name: str, *, recognize: Callable[[Path], str] | None = None) -> str:
    """Read the text in an image once and keep it next to the image. A
    reading that fails counts as no text. An image deleted meanwhile leaves
    no text behind."""
    cached = image_text(folder, name)
    if cached is not None:
        return cached
    path = image_path(folder, name)
    with _READING:
        cached = image_text(folder, name)
        if cached is not None:
            return cached
        try:
            text = (recognize or recognize_text)(path).strip()
        except Exception as exc:
            LOGGER.warning("reading the text in %s failed: %s", name, exc)
            text = ""
        if not path.exists():  # deleted while it was read
            return text
        target = _text_file(folder, name)
        try:
            tmp = target.with_name(f".{target.name}.tmp")
            tmp.write_text(text)
            os.replace(tmp, target)
        except OSError:  # the notes were cleared meanwhile
            pass
        if not path.exists():
            target.unlink(missing_ok=True)
    return text


def read_all(folder: Path, *, recognize: Callable[[Path], str] | None = None) -> None:
    """Read every image of the notes not read yet (e.g. the app quit first)."""
    for p in load(folder):
        name = p.get("image")
        if name and image_text(folder, name) is None:
            try:
                read_image(folder, name, recognize=recognize)
            except (ValueError, FileNotFoundError):
                continue


def read_in_background(folder: Path, name: str) -> threading.Thread:
    thread = threading.Thread(target=_read_quietly, args=(Path(folder), name), name="my-notes-ocr", daemon=True)
    thread.start()
    return thread


def _read_quietly(folder: Path, name: str) -> None:
    try:
        read_image(folder, name)
    except Exception:
        LOGGER.exception("reading the text in %s failed", name)


def image_files(folder: Path, name: str) -> list[Path]:
    """An image and the text read from it: what deleting it removes."""
    return [image_path(folder, name), _text_file(folder, name)]


def remove_image(folder: Path, name: str) -> tuple[dict | None, dict | None]:
    """Delete an image: its paragraph, the file and its text. Returns the
    paragraph and the one before it (where an undo puts it back)."""
    path = image_path(folder, name)
    with locked(folder):
        paragraphs = load(folder)
        i = next((k for k, p in enumerate(paragraphs) if p.get("image") == name), None)
        removed = paragraphs[i] if i is not None else None
        before = paragraphs[i - 1] if i else None
        _write(folder, [p for p in paragraphs if p.get("image") != name])
        path.unlink(missing_ok=True)
        _text_file(folder, name).unlink(missing_ok=True)
    return removed, before


# --- for the notes prompt, and for MCP ----------------------------------------------------


def _clock(seconds: float) -> str:
    minutes, secs = divmod(int(seconds), 60)
    hours, minutes = divmod(minutes, 60)
    return f"{hours}:{minutes:02d}:{secs:02d}" if hours else f"{minutes:02d}:{secs:02d}"


_BLOCK_TAG = re.compile(r"<(\s*/?\s*my-notes)", re.IGNORECASE)


def neutralize(text: str) -> str:
    """No text of the user's or read from an image can open or close the
    prompt's <my-notes> block."""
    return _BLOCK_TAG.sub(lambda m: "‹" + m.group(1), text)


def prompt_text(folder: Path) -> str:
    """The notes as text: one paragraph after the other, with the meeting
    time it was written at (on the transcript's clock); for an image, the
    text read from it. Empty when there are none."""
    out = []
    for p in load(folder):
        text = p["text"].strip()
        if p.get("image"):
            read = (image_text(folder, p["image"]) or "").strip()
            image = (f"[image; text on it, not written by the user: "
                     f"{' / '.join(l.strip() for l in read.splitlines() if l.strip())}]" if read else "[image without text]")
            text = f"{text} {image}" if text else image
        if not text:
            continue
        lines = text.splitlines()
        first = f"[{_clock(p['at'])}] {lines[0]}" if p["at"] is not None else lines[0]
        out.append("\n".join([first, *(f"  {line}" for line in lines[1:])]))
    return neutralize("\n".join(out))


def prompt_hash(text: str) -> str:
    """Changes with what the notes model would read; "" for no notes."""
    return hashlib.sha256(text.encode()).hexdigest()[:16] if text.strip() else ""


# --- before the meeting; cut and joined recordings -----------------------------------------


def prep_folder(key: str) -> Path:
    """Where the notes for a calendar event wait until it is recorded."""
    digest = hashlib.sha256(key.encode()).hexdigest()[:24]
    return xdg_config_home() / "palaver" / "prepared-notes" / digest


def has_prepared() -> bool:
    root = xdg_config_home() / "palaver" / "prepared-notes"
    return root.is_dir() and any(root.iterdir())


def _move_images(src: Path, dst: Path, names: list[str], *, copy: bool = False) -> None:
    for name in names:
        for f in (_images(src) / name, _text_file(src, name)):
            if f.exists():
                (dst / IMAGES).mkdir(parents=True, exist_ok=True)
                (shutil.copy2 if copy else shutil.move)(str(f), str(_images(dst) / f.name))


def adopt(src: Path, dst: Path) -> bool:
    """Move the notes written before a meeting into its recording, in front
    of what was written during it. False when there were none."""
    if not Path(src).is_dir():
        return False
    with _both(src, dst):
        before = load(src)
        if _has_content(before):
            _move_images(src, dst, [p["image"] for p in before if p.get("image")])
            _write(dst, before + load(dst))
        shutil.rmtree(src, ignore_errors=True)
    return _has_content(before)


def join(first: Path, second: Path, *, keep: Path, offset: float) -> None:
    """Two recordings joined into ``keep``: both notes, the second's times
    moved by ``offset`` (where it starts on the joined clock). The images
    are copied, so the other recording (going to the trash) stays whole."""
    if not (_has_content(load(first)) or _has_content(load(second))):
        return
    with _both(first, second):
        a, b = load(first), load(second)
        b = [{**p, "at": None if p["at"] is None else round(p["at"] + offset, 1)} for p in b]
        other = second if Path(keep) == Path(first) else first
        _move_images(other, keep, [p["image"] for p in (b if other == second else a) if p.get("image")], copy=True)
        # By time; what has none (written before or after) first, each part in its order.
        untimed = [p for p in a + b if p["at"] is None]
        timed = sorted((p for p in a + b if p["at"] is not None), key=lambda p: p["at"])
        _write(keep, untimed + timed)


def split(head: Path, tail: Path, *, at: float) -> None:
    """A recording cut ``at`` seconds: what was written from then on goes
    with the part after it, on its clock."""
    after = lambda p: p["at"] is not None and p["at"] >= at  # noqa: E731
    if not any(after(p) for p in load(head)):
        return
    with _both(head, tail):
        paragraphs = load(head)
        later = [p for p in paragraphs if after(p)]
        _move_images(head, tail, [p["image"] for p in later if p.get("image")])
        _write(tail, [{**p, "at": round(p["at"] - at, 1)} for p in later] + load(tail))
        _write(head, [p for p in paragraphs if not after(p)])
