"""Read Security Central's monthly statement PDF into account lines.

Security Central emails the dealer a statement on the 25th ("Your
MM/DD/YYYY alarm monitoring statement is attached", AP:… "Statement EMail").
It is the only Security Central document that arrives on its own, and it is
a roster: every billed account is a line, with the account holder, street,
Security Central account number (A1651…, the same number Alarm.com carries
as CS Account), the service and the amount. Three sections:

  Customer Activations   accounts started since the last statement, prorated
  (unheaded)             accounts disconnected, credited back, no account no.
  Current Recurring Charges  next month's charge for every active account

then a Current Charges Summary whose Totals row gives the count and amount
of each section, and the total due.

Pure functions over pdftext.rows (coordinates, not draw order). Nothing is
accepted on trust: each section must add up to its printed total and its
count to the summary's, and the sections to the total due, or parse raises
and the file lands nothing. A silent misread of a bill is worse than a
missing one.
"""

import re

from ..lib import pdftext

PROBE = "SECURITY CENTRAL"
_PERIOD = re.compile(r"^(\d\d/\d\d/\d\d)\s*-\s*(\d\d/\d\d/\d\d)$")
_MONEY = re.compile(r"^-?[\d,]+\.\d\d$")
_ACCOUNT = re.compile(r"^([A-Z]\d{5,})\s+(.+)$")
_DATE = re.compile(r"^\d\d/\d\d/\d\d$")


def money(s):
    return round(float(s.replace(",", "")), 2)


def iso(mmddyy):
    m, d, y = mmddyy.split("/")
    return f"20{y}-{m}-{d}"


def _after(row, label):
    """The cell after `label` in a row, or None."""
    for i, c in enumerate(row[:-1]):
        if c.strip().rstrip(":") == label.rstrip(":"):
            return row[i + 1]
    return None


def _line(row):
    """(name, street, account, service, start, end, amount) or None."""
    pi = next((i for i, c in enumerate(row) if _PERIOD.match(c)), None)
    if pi is None or pi < 2 or pi != len(row) - 2 or not _MONEY.match(row[-1]):
        return None
    start, end = _PERIOD.match(row[pi]).groups()
    service_cell = row[pi - 1]
    m = _ACCOUNT.match(service_cell)
    account, service = (m.group(1), m.group(2).strip()) if m else (None, service_cell.strip())
    if pi == 2:
        # Street, service, period, amount: the name cell is taller than the
        # row and printed on the rows around it.
        name, street = None, row[0].strip()
    else:
        name = row[0].strip()
        street = " ".join(c.strip() for c in row[1:pi - 1]) or None
    return name, street, account, service, iso(start), iso(end), money(row[-1])


def parse_rows(rows):
    """{"statement": {...}, "lines": [...]} from a statement's rows.

    Raises ValueError naming every total that does not reconcile.
    """
    head = {"statement_date": None, "account_number": None, "total_due": None}
    lines, totals, summary = [], {}, None
    section, invoice, invoice_date = None, None, None
    last_was_line, pending = False, []
    for row in rows:
        cells = [c.strip() for c in row]
        if head["statement_date"] is None and _after(cells, "Stmt Date:"):
            head["statement_date"] = iso(_after(cells, "Stmt Date:"))
        if head["account_number"] is None and _after(cells, "Account No.:"):
            head["account_number"] = _after(cells, "Account No.:")
        if head["total_due"] is None and _after(cells, "Total Amount Due ="):
            head["total_due"] = money(_after(cells, "Total Amount Due ="))
        if "Customer Activations" in cells or "Current Recurring Charges" in cells:
            section = "activation" if "Customer Activations" in cells else "recurring"
            invoice = next((c.split(":", 1)[1].strip() for c in cells
                            if c.startswith("Invoice No.:")), None)
            invoice_date = next((iso(c.split(":", 1)[1].strip()) for c in cells
                                 if c.startswith("Invoice Date:")), None)
            last_was_line = False
            continue
        label = cells[0].rstrip(":") if cells else ""
        if label in ("Total Activations", "Total Disconnects", "Total Recurring Charges") \
                and _MONEY.match(cells[-1]):
            totals[label] = money(cells[-1])
            # Disconnects follow the activations' total with no heading.
            section = "disconnect" if label == "Total Activations" else None
            invoice = invoice if label == "Total Activations" else None
            last_was_line = False
            continue
        if cells and cells[0] == "Totals" and len(cells) == 8:
            summary = [money(c) for c in cells[1:]]
            continue
        parsed = _line(cells) if section else None
        if parsed:
            name, street, account, service, start, end, amount = parsed
            if name is None:
                name = " ".join(pending) or None
            pending = []
            lines.append({
                "section": section, "customer_name": name, "street": street,
                "account_number": account, "service": service,
                "period_start": start, "period_end": end, "amount": amount,
                "invoice_number": invoice if section != "disconnect" else None,
                "invoice_date": invoice_date,
            })
            last_was_line = True
            continue
        # Text too long for its cell wraps onto a row of its own directly
        # under its line. Names are printed in capitals ("ZACH SHAFFER -
        # GREENTECH" / "RENEWABLES"), services are not ("Security Package
        # with" / "Cellular").
        if section and last_was_line and len(cells) == 1 and not _MONEY.match(cells[0]):
            key = "customer_name" if cells[0].isupper() else "service"
            lines[-1][key] = f"{lines[-1][key] or ''} {cells[0]}".strip()
            continue
        # Capitals between lines may be the top of a name whose line has no
        # name cell (it straddles the row); held until that line or dropped.
        if section and cells and all(c.isupper() and not _MONEY.match(c) for c in cells):
            pending = pending + cells
        else:
            pending = []
        last_was_line = False
    problems = reconcile(lines, totals, summary, head["total_due"])
    if head["statement_date"] is None:
        problems.append("Stmt Date not found")
    if problems:
        raise ValueError("Security Central statement does not reconcile: " + "; ".join(problems))
    for n, line in enumerate(lines):
        line["line"] = n + 1
    return {"statement": dict(head, lines=len(lines), totals=totals), "lines": lines}


def reconcile(lines, totals, summary, total_due):
    """Every way the statement's own numbers can disagree with its lines."""
    problems = []
    by = {s: [l for l in lines if l["section"] == s]
          for s in ("activation", "disconnect", "recurring")}
    labels = {"activation": "Total Activations", "disconnect": "Total Disconnects",
              "recurring": "Total Recurring Charges"}
    for s, label in labels.items():
        got = round(sum(l["amount"] for l in by[s]), 2)
        want = totals.get(label)
        if want is None:
            if by[s]:
                problems.append(f"{label} not found but {len(by[s])} lines read")
        elif abs(got - want) > 0.005:
            problems.append(f"{label} {want:.2f} but lines add to {got:.2f}")
    if summary is None:
        problems.append("Current Charges Summary Totals row not found")
    else:
        aq, aa, dq, da, rq, ra, total = summary
        for s, q in (("activation", aq), ("disconnect", dq), ("recurring", rq)):
            if len(by[s]) != int(q):
                problems.append(f"summary counts {int(q)} {s} lines, read {len(by[s])}")
        if total_due is not None and abs(total - total_due) > 0.005:
            problems.append(f"summary total {total:.2f} but amount due {total_due:.2f}")
    if total_due is None:
        problems.append("Total Amount Due not found")
    return problems


def parse(data):
    """parse_rows over a statement PDF's bytes."""
    return parse_rows(pdftext.rows(data, PROBE))
