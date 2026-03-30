#!/usr/bin/env python3
import sys
import os
import subprocess
import time
import fitz  # PyMuPDF
import argparse

def main():
    parser = argparse.ArgumentParser(description="Markdown to PDF")
    parser.add_argument("md_file", help="Markdown file path")
    parser.add_argument("--margin-top", help="Top margin (cm)", type=str)
    parser.add_argument("--margin-bottom", help="Bottom margin (cm)", type=str)
    parser.add_argument("--margin-left", help="Left margin (cm)", type=str)
    parser.add_argument("--margin-right", help="Right margin (cm)", type=str)
    
    args = parser.parse_args()
        
    md_file = args.md_file
    file_dir = os.path.dirname(md_file)
    if not file_dir: 
        file_dir = "."
    base_name = os.path.splitext(os.path.basename(md_file))[0]
    
    temp_html = os.path.join(file_dir, "temp.html")
    temp_pdf = os.path.join(file_dir, "temp.pdf")
    final_pdf = os.path.join(file_dir, f"{base_name}.pdf")
    
    script_dir = os.path.dirname(os.path.realpath(__file__))
    css_path = os.path.join(script_dir, "github-markdown-light.css")
    native_engine_path = os.path.join(script_dir, "md2pdf_native")
    
    pipeline_start = time.time()
    
    try:
        t0 = time.time()
        print(f"[1/4] Markdown to HTML with Pandoc...")
        subprocess.run([
            "pandoc", "-f", "markdown", "-t", "html", "--standalone", "--embed-resources",
            "-c", css_path, "--metadata", "title=", "-V", "body-class=markdown-body",
            "--id-prefix=v", md_file, "-o", temp_html
        ], check=True)
        print(f"[1/4]: {time.time() - t0:.2f}\n")
        
        t0 = time.time()
        print(f"[2/4] HTML to PDF with md2pdf_native...")
        cmd = [native_engine_path, temp_html, temp_pdf]
        if args.margin_top:
            cmd.extend(["--margin-top", args.margin_top])
        if args.margin_bottom:
            cmd.extend(["--margin-bottom", args.margin_bottom])
        if args.margin_left:
            cmd.extend(["--margin-left", args.margin_left])
        if args.margin_right:
            cmd.extend(["--margin-right", args.margin_right])
            
        subprocess.run(cmd, check=True)
        print(f"[2/4]: {time.time() - t0:.2f}\n")
        
        t0 = time.time()
        print(f"[3/4] Printing page numbers with PyMuPDF...")
        doc = fitz.open(temp_pdf)
        total_pages = len(doc)
        helv_font = fitz.Font("helv")
        
        for i in range(total_pages):
            page = doc[i]
            text = f"{i + 1} / {total_pages}"
            target_y = page.rect.height - 35
            
            text_width = helv_font.text_length(text, fontsize=10)
            start_x = (page.rect.width / 2) - (text_width / 2)
            
            page.insert_text(fitz.Point(start_x, target_y), text, fontsize=10, fontname="helv", color=(0, 0, 0))
        
        doc.save(final_pdf)
        doc.close()
        print(f"[3/4]: {time.time() - t0:.2f}\n")
        
        # [Step 4]
        t0 = time.time()
        print(f"[4/4] Cleaning up temporary files.")
        if os.path.exists(temp_html): os.remove(temp_html)
        if os.path.exists(temp_pdf): os.remove(temp_pdf)
        subprocess.run(["osascript", "-e", f'display notification "{base_name}.pdf is done" with title "MD2PDF"'], check=True)
        print(f"[4/4]: {time.time() - t0:.2f}\n")
        
        print(f"Total: {time.time() - pipeline_start:.2f}")
        
    except Exception as e:
        print(f"Error: {e}")
        sys.exit(1)

if __name__ == "__main__":
    main()