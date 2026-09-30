# PDF content parts for vLLM chat: expands OpenAI `file` / Responses `input_file` parts
# (and data:application/pdf image_url) into per-page text + a rendered image of each page.
# Hooked into chat_utils._parse_chat_message_content_parts by patch_pdf_parts.py.
import base64
import os

PDF_DPI = int(os.environ.get("PARO_PDF_DPI", "144"))
PDF_MAX_PAGES = int(os.environ.get("PARO_PDF_MAX_PAGES", "50"))


def _pdf_bytes(part):
    t = part.get("type")
    if t == "file":
        f = part.get("file") or {}
        data, name = f.get("file_data"), f.get("filename")
    elif t == "input_file":
        data, name = part.get("file_data"), part.get("filename")
    elif t == "image_url":
        url = (part.get("image_url") or {}).get("url") or ""
        data, name = (url, None) if url.startswith("data:application/pdf") else (None, None)
    else:
        return None
    if not data:
        if t in ("file", "input_file"):
            raise ValueError("file parts need inline file_data (file_id/file_url unsupported)")
        return None
    if data.startswith("data:"):
        mime, _, data = data.partition(",")
        if "pdf" not in mime:
            raise ValueError(f"unsupported file type {mime[5:].split(';')[0]!r}; only PDF")
    raw = base64.b64decode(data)
    if not raw.startswith(b"%PDF"):
        raise ValueError(f"file {name or ''} is not a PDF")
    return raw, name or "document.pdf"


def _expand(raw, name):
    import pypdfium2 as pdfium

    pdf = pdfium.PdfDocument(raw)
    n = len(pdf)
    out = [{"type": "text", "text": f"[{name}: {n} page(s)]"}]
    for i in range(min(n, PDF_MAX_PAGES)):
        page = pdf[i]
        text = page.get_textpage().get_text_bounded().strip()
        out.append({"type": "text", "text": f"[{name} page {i + 1}]\n{text}" if text else f"[{name} page {i + 1}]"})
        out.append({"type": "image_pil", "image_pil": page.render(scale=PDF_DPI / 72).to_pil().convert("RGB")})
    if n > PDF_MAX_PAGES:
        out.append({"type": "text", "text": f"[{name}: pages {PDF_MAX_PAGES + 1}-{n} omitted]"})
    pdf.close()
    return out


def expand_pdf_parts(parts):
    out = []
    for part in parts:
        pdf = _pdf_bytes(part) if isinstance(part, dict) else None
        out.extend(_expand(*pdf) if pdf else [part])
    return out
