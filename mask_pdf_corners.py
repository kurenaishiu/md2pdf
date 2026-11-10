#!/usr/bin/env python3
"""Remove text from the three specified page corners using PyMuPDF redactions."""

import os
import sys
import tempfile
from pathlib import Path

import fitz


POINTS_PER_CM = 72 / 2.54
MASK_WIDTH = 10 * POINTS_PER_CM
MASK_HEIGHT = 2 * POINTS_PER_CM


def mask_pdf_corners(input_path: Path, output_path: Path) -> None:
    output_path.parent.mkdir(parents=True, exist_ok=True)
    file_descriptor, temporary_path = tempfile.mkstemp(
        prefix=f".{output_path.stem}.",
        suffix=".pdf",
        dir=output_path.parent,
    )
    os.close(file_descriptor)

    try:
        with fitz.open(input_path) as document:
            if not document.is_pdf or document.page_count == 0:
                raise ValueError(f"Could not open a non-empty PDF: {input_path}")

            for page_number, page in enumerate(document, start=1):
                page_rect = page.rect
                if page_rect.width < MASK_WIDTH or page_rect.height < MASK_HEIGHT:
                    raise ValueError(
                        f"Page {page_number} is too small for the 10 cm by 2 cm masks."
                    )

                masks_on_page = [
                    fitz.Rect(
                        page_rect.x0,
                        page_rect.y0,
                        page_rect.x0 + MASK_WIDTH,
                        page_rect.y0 + MASK_HEIGHT,
                    ),
                    fitz.Rect(
                        page_rect.x1 - MASK_WIDTH,
                        page_rect.y0,
                        page_rect.x1,
                        page_rect.y0 + MASK_HEIGHT,
                    ),
                    fitz.Rect(
                        page_rect.x0,
                        page_rect.y1 - MASK_HEIGHT,
                        page_rect.x0 + MASK_WIDTH,
                        page_rect.y1,
                    ),
                ]
                inverse_rotation = page.derotation_matrix
                redaction_rects = [mask * inverse_rotation for mask in masks_on_page]

                links_to_remove = []
                for link in page.get_links():
                    link_rect = fitz.Rect(link["from"]) * page.rotation_matrix
                    if any(link_rect.intersects(mask) for mask in masks_on_page):
                        links_to_remove.append(link)

                for link in links_to_remove:
                    page.delete_link(link)

                for rect in redaction_rects:
                    page.add_redact_annot(rect, fill=None, cross_out=False)
                page.apply_redactions(
                    images=fitz.PDF_REDACT_IMAGE_NONE,
                    graphics=fitz.PDF_REDACT_LINE_ART_NONE,
                    text=fitz.PDF_REDACT_TEXT_REMOVE,
                )

            document.save(temporary_path, garbage=4, deflate=True)

        os.replace(temporary_path, output_path)
    finally:
        if os.path.exists(temporary_path):
            os.remove(temporary_path)


if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise SystemExit("Usage: python3 mask_pdf_corners.py file.pdf")
    pdf_path = Path(sys.argv[1])
    mask_pdf_corners(pdf_path, pdf_path)
    print(f"Updated PDF in place: {pdf_path}")
