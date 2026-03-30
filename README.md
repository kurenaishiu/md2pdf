# MD2PDF

A high-performance Markdown to PDF conversion pipeline optimized for MacOS. 
By leveraging the **Native WebKit Engine** instead of heavy Chrome Headless instances, and utilizing **PyMuPDF** for post-processing.

## Features
- **Extreme Speed**: Powered by native WebKit API for near-instant rendering.
- **Dynamic Margins**: Full control over Top, Bottom, Left, and Right margins via CLI arguments.

**Note:** For further visual adjustments (font size, colors, or line height), simply edit the `github-markdown-light.css` file.

## Prerequisites
Ensure the following are installed on your Mac:
1. **Pandoc**: `brew install pandoc`
2. **Python 3 & PyMuPDF**: `pip install pymupdf`
3. **Swift**: Pre-installed on MacOS.

## Installation
1. **Clone the repository**:
   ```bash
   git clone https://github.com/kurenaishiu/md2pdf.git
   cd MD2PDF
   ```

2. **Compile the Rendering Engine:**
This creates a binary `md2pdf_native`.
    ```bash
    swiftc md2pdf_native.swift -o md2pdf_native
    ```

<details>
  <summary><b> 3. (Optional) Create a Global Command & VS Code Integration </b></summary>
  
  Create a lightweight bash wrapper script in your user directory (`~/.local/bin`) and configure VS Code to call it directly.

  ### 3.1 Create the Wrapper Script

  Run the following commands in your terminal to create a global command:
  ```bash
    mkdir -p ~/.local/bin

    cat << 'EOF' > ~/.local/bin/md2pdf
    #!/bin/bash
    python3 "/PATH/TO/md2pdf.py" "$@"
    EOF

    chmod +x ~/.local/bin/md2pdf
  ```
  **Important:** Ensure `~/.local/bin` is in your system's `$PATH`. You can add `export PATH="$HOME/.local/bin:$PATH"` to your `~/.zshrc` and run `source ~/.zshrc` to apply the changes.

  ### 3.2 VS Code Task Automation (The Ultimate Workflow)
  To compile your Markdown to PDF with a single keyboard shortcut (`Cmd + Shift + P`), add this to your VS Code `.vscode/tasks.json`:
  ```json
    {
        "version": "2.0.0",
        "tasks":[
            {
                "label": "MD2PDF",
                "type": "process",
                "command": "${env:HOME}/.local/bin/md2pdf",
                "args": [
                    "${file}"
                ],
                "group": {
                    "kind": "build",
                    "isDefault": true
                },
                "presentation": {
                    "reveal": "silent",
                    "panel": "shared"
                }
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
</details>


## Usage

Basic Conversion (Default 2cm margins)
```bash
md2pdf document.md
```

Specify margins in centimeters (cm):
```bash
md2pdf document.md --margin-top 2.5 --margin-bottom 1.5 --margin-left 3
```

## Project Structure

- `md2pdf.py`: Main pipeline controller (Pandoc conversion & PDF post-processing).

- `md2pdf_native.swift`: Swift-based WebKit rendering engine.

- `github-markdown-light.css`: Print-optimized stylesheet.

## License
MIT License.