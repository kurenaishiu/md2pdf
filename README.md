# MD2PDF

A high-performance Markdown to PDF conversion pipeline optimized for macOS. 
By leveraging the **Native WebKit Engine** for rendering, **Pandoc** for HTML conversion, and **PDFKit** for post-processing and native merging.

## Features
- **Extreme Speed**: Powered by native WebKit API for near-instant rendering.
- **Dynamic Margins**: Full control over Top, Bottom, Left, and Right margins via CLI arguments.
- **Smart `@import` Resolution**: Seamlessly embed other Markdown files (`@import "file.md"`) or images (`@import "image.png"`) directly into your document.
- **Native PDF Attachments**: Use `@import "appendix.pdf"` to seamlessly append PDFs at your document.
- **Intelligent Page Numbering**: Automatically injects centered page numbers (e.g., `1 / 5`) into the main document. PDF attachments are excluded from both the page count and numbering.
- **Native Notifications**: Triggers a macOS system notification the moment your conversion is complete.

**Note:** For further visual adjustments (font size, colors, or line height), simply edit the `/md2pdf/github-markdown-light.cssgithub-markdown-light.css` file.

## Prerequisites
Ensure the following are installed on your Mac:
1. **Pandoc**: `brew install pandoc`
2. **Swift**: Pre-installed on MacOS.

## Installation
1. **Clone the repository**:
   ```bash
   git clone https://github.com/kurenaishiu/md2pdf.git
   cd MD2PDF
   ```

2. **Compile the CLI Tool:**
    Build the project using Swift Package Manager..
    ```bash
    swift build -c release
    ```

<details>
  <summary><b> 3. (Optional) Create a Global Command & VS Code Integration </b></summary>
  
  ### 3.1 Install the Binary Globally

  Run the following commands in your terminal to move the compiled binary to your local bin directory:
  ```bash
  mkdir -p ~/.local/bin
  cp .build/release/md2pdf ~/.local/bin/md2pdf
  ```
  **Important:** Ensure `~/.local/bin` is in your system's `$PATH`. You can add `export PATH="$HOME/.local/bin:$PATH"` to your `~/.zshrc` and run `source ~/.zshrc` to apply the changes.

  ### 3.2 VS Code Task Automation (The Ultimate Workflow)
  To compile your Markdown to PDF with a single keyboard shortcut (`Cmd + Shift + P`), add this to your VS Code `.vscode/tasks.json`:
  ```json
{
    "version": "2.0.0",
    "tasks": [
        {
            "label": "MD2PDF",
            "type": "shell",
            "command": "md2pdf",
            "args": [
                "${file}"
            ],
            "group": {
                "kind": "build",
                "isDefault": true
            },
            "presentation": {
                "echo": false,
                "reveal": "silent",
                "focus": false,
                "panel": "shared",
                "showReuseMessage": false,
                "clear": true
            },
            "problemMatcher": []
        }
    ]
}
  ``` 
  ### 3.3 Custom Keybinding
  To achieve the true "One-Click Export" experience, bind the task to a custom keyboard shortcut (e.g., `Cmd + Alt + P`).

  Open your VS Code `keybindings.json` (Command Palette -> `Preferences: Open Keyboard Shortcuts (JSON)`) and add the following object to the array:
  ```json 
{
    "key": "cmd+alt+p",
    "command": "workbench.action.tasks.runTask",
    "args": "MD2PDF",
    "when": "editorLangId == 'markdown'"
}
  ```

  You can now generate PDFs directly in VS Code by pressing `Cmd + Alt + P` within any `.md` file.

</details>




## Usage

### Local Execution (Without Global Install)
If you skipped Step 3 and didn't install the binary globally, you can run it directly from the project directory after building:

```bash
.build/release/md2pdf document.md
```

### Global Execution
If you copied the binary to your local bin directory (Step 3), you can run the tool from anywhere in your terminal:

```bash
md2pdf document.md
```

Advanced Options

```bash
md2pdf document.md --margin-top 2.5 --margin-bottom 1.5 --margin-left 3
```

## Project Structure

- `Sources/md2pdf/md2pdf.swift`: Pure Swift-based CLI, WebKit rendering engine, and PDFKit post-processor.

- `Sources/md2pdf/github-markdown-light.css`: Print-optimized stylesheet.

## License
MIT License.