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


# Text placement. `lines()` above returns runs in the order the file draws
# them, which is all Parasol's invoice needs. Security Central's recurring
# report is a real table and its draw order is not its reading order — whole
# header blocks come out reversed, and a row's cells can be split across the
# stream. Reconstructing rows from coordinates is the only way to read it.
#
# Only the operators a generated report actually uses are tracked: BT resets
# the text matrix, Td/TD move relative to the line start, Tm sets the matrix
# outright, T* advances by the leading set with TL. Anything else leaves the
# position alone, which is the safe direction to be wrong in — a cell lands on
# the previous row rather than vanishing.
_PLACE = re.compile(
    rb"(?P<bt>BT)\b"
    rb"|(?P<tl>-?[\d.]+)\s+TL\b"
    rb"|(?:-?[\d.]+\s+){4}(?P<tmx>-?[\d.]+)\s+(?P<tmy>-?[\d.]+)\s+Tm\b"
    rb"|(?P<tdx>-?[\d.]+)\s+(?P<tdy>-?[\d.]+)\s+T[dD]\b"
    rb"|(?P<star>T\*)"
    rb"|(?P<show>\[(?:[^\[\]]*)\]\s*TJ|\((?:\\.|[^()\\])*\)\s*Tj)",
    re.S)

# Two runs are on the same row when their baselines are within this many text
# units. The reports seen so far set 7pt type on ~9.3 units of leading, so the
# gap between rows is far larger than the wobble within one; 3.0 separates
# them with room to spare in both directions.
_ROW_TOLERANCE = 3.0


def rows(data, probe):
    """Text runs grouped into visual rows, in reading order.

    Returns a list of rows, each a list of the cell strings on that line from
    left to right. Callers still match cells by content rather than by index:
    a report that omits an empty cell shifts every position after it, and
    positional parsing here has already cost this repo eight accounts once.
    What coordinates buy is the row, not the column.
    """
    shift = detect_shift(data, probe)
    out = []
    for page, stream in enumerate(content_streams(data)):
        placed = []
        x = y = leading = 0.0
        for m in _PLACE.finditer(stream):
            if m.group("bt") is not None:
                x = y = 0.0
            elif m.group("tl") is not None:
                leading = float(m.group("tl"))
            elif m.group("tmy") is not None:
                x, y = float(m.group("tmx")), float(m.group("tmy"))
            elif m.group("tdy") is not None:
                x += float(m.group("tdx"))
                y += float(m.group("tdy"))
            elif m.group("star") is not None:
                y -= leading
            else:
                text = "".join(_decode(lit.group(0)[1:-1], shift)
                               for lit in _LITERAL.finditer(m.group("show")))
                text = text.strip()
                if text:
                    placed.append((y, x, text))

        # Down the page to find the rows, then across each one. The two steps
        # cannot be collapsed into a single sort: cells on one printed line
        # differ slightly in baseline, so sorting by y before x orders a row
        # by its wobble rather than left to right.
        placed.sort(key=lambda c: -c[0])
        bands = []
        for cell_y, cell_x, text in placed:
            if bands and abs(cell_y - bands[-1][0]) <= _ROW_TOLERANCE:
                bands[-1][1].append((cell_x, text))
            else:
                bands.append((cell_y, [(cell_x, text)]))
        out.extend([text for _, text in sorted(cells)] for _, cells in bands)
    return out
