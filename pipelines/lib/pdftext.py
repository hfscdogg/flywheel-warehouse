"""Extract text lines from a PDF. Standard library only.

Vendors that bill per account often send no roster at all — the invoice is
the roster. Parsing one is not elegant, but a monthly PDF that already exists
beats waiting on a vendor to build an export.

Scope is deliberately narrow: uncompressed or Flate-compressed content
streams, text drawn with Tj/TJ, and simple single-byte or two-byte font
encodings. No CMap parsing, no xref traversal, no encryption. Enough for a
generated invoice, nowhere near enough for arbitrary PDFs — and it raises
rather than guessing when the file is outside that scope.
"""

import re
import zlib

# Text-showing operators: (str) Tj, and [(a) -250 (b)] TJ for kerned runs.
_SHOW = re.compile(rb"\[(?:[^\[\]]*)\]\s*TJ|\((?:\\.|[^()\\])*\)\s*Tj", re.S)
_LITERAL = re.compile(rb"\((?:\\.|[^()\\])*\)", re.S)
_STREAM = re.compile(rb"stream\r?\n(.*?)endstream", re.S)
_ESCAPE = re.compile(rb"\\([()\\])")
_PRINTABLE = re.compile(r"[ -~]")


def content_streams(data):
    """Every content stream in the file, inflated where it is compressed.

    Streams that are neither plain text nor Flate — images, fonts, anything
    with another filter — simply yield nothing useful and are skipped. There
    is no manifest to consult without parsing the xref table, so this tries
    and moves on rather than deciding in advance.
    """
    for match in _STREAM.finditer(data):
        raw = match.group(1)
        try:
            yield zlib.decompress(raw)
        except zlib.error:
            yield raw


def _decode(raw, shift):
    """One PDF string literal to text, applying the font's code shift.

    Generated PDFs frequently subset a font and renumber its glyphs, so the
    bytes in the file are not ASCII: a fixed offset separates them from the
    characters they draw. `shift` is that offset (0 for a normal font).

    Two-byte encodings leave a high byte of 0 between characters, which lands
    on an unprintable code point after shifting; dropping unprintables handles
    both cases without needing to know which one this file uses.
    """
    text = _ESCAPE.sub(rb"\1", raw)
    out = []
    for byte in text:
        char = chr((byte + shift) & 0xFF)
        if _PRINTABLE.match(char):
            out.append(char)
    return "".join(out)


def detect_shift(data, probe):
    """The font code offset that makes `probe` appear in the content.

    Rather than hard-coding an offset that is really a property of one
    vendor's font subset, look for the shift that makes a string we know is
    on the page — the vendor's own name — actually show up. A template change
    that renumbers the font is then self-correcting; one that removes the
    probe string fails loudly, which is the right outcome for a parser whose
    silent failure mode is an empty roster.
    """
    blob = b"\n".join(content_streams(data))
    for shift in range(-128, 128):
        sample = "".join(_decode(m.group(0)[1:-1], shift)
                         for m in _LITERAL.finditer(blob[:400_000]))
        if probe in sample:
            return shift
    raise ValueError(
        f"could not find {probe!r} in the PDF at any font offset — the "
        f"document is not the expected format, or its text is not extractable")


def lines(data, probe):
    """Text runs in document order, one string per Tj/TJ operator.

    A generated invoice draws each table cell as its own run, so runs are a
    usable proxy for fields. Nothing here reconstructs layout: callers match
    on content, not on position.
    """
    shift = detect_shift(data, probe)
    out = []
    for stream in content_streams(data):
        for show in _SHOW.finditer(stream):
            text = "".join(_decode(m.group(0)[1:-1], shift)
                           for m in _LITERAL.finditer(show.group(0)))
            text = text.strip()
            if text:
                out.append(text)
    return out
