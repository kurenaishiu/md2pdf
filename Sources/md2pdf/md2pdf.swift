import Foundation
import ArgumentParser
import Cocoa
import WebKit
import PDFKit

@main
struct MD2PDF: ParsableCommand {
    static var configuration = CommandConfiguration(
        commandName: "md2pdf",
        abstract: "A native tool to convert Markdown to high-quality PDF.",
    )

    @Argument(help: "Input Markdown file path")
    var inputPath: String

    @Argument(help: "Output PDF file path (optional)")
    var outputPath: String?

    @Option(name: .long, help: "Top margin (cm)")
    var marginTop: String = "2"

    @Option(name: .long, help: "Bottom margin (cm)")
    var marginBottom: String = "2"

    @Option(name: .long, help: "Left margin (cm)")
    var marginLeft: String = "2"

    @Option(name: .long, help: "Right margin (cm)")
    var marginRight: String = "2"

    func run() throws {
        let globalStartTime = CFAbsoluteTimeGetCurrent()

        let finalOutput: String
        if let out = outputPath {
            finalOutput = out
        } else {
            let inputURL = URL(fileURLWithPath: inputPath)
            finalOutput = inputURL.deletingPathExtension().appendingPathExtension("pdf").path
        }

        if FileManager.default.fileExists(atPath: finalOutput) {
            try? FileManager.default.removeItem(atPath: finalOutput)
        }

        let mdURL = URL(fileURLWithPath: inputPath)
        let parentDir = mdURL.deletingLastPathComponent()

        guard let originalContent = try? String(contentsOf: mdURL, encoding: .utf8) else {
            print("File not found: \(inputPath)")
            throw ExitCode.failure
        }
        
        print("[0/2] Parsing Markdown and resolving @import statements...")
        var attachments: [String: URL] = [:] 
        let finalMdContent = resolveImports(in: originalContent, baseDirectory: parentDir, attachments: &attachments)
        
        print("[1/2] Converting Markdown to HTML...")
        guard let htmlString = convertMarkdownToHTML(mdContent: finalMdContent) else {
            print("Pandoc conversion failed")
            throw ExitCode.failure
        }

        print("[2/2] Rendering PDF (WebKit)...")
        let converter = PDFConverter(
            htmlContent: htmlString,
            baseURL: parentDir,
            destPath: finalOutput,
            top: marginTop,
            bottom: marginBottom,
            left: marginLeft,
            right: marginRight,
            startTime: globalStartTime,
            attachments: attachments
        )
        converter.run()
    }

    private func convertMarkdownToHTML(mdContent: String) -> String? {
        let process = Process()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        let inputPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        
        guard let cssPath = Bundle.module.path(forResource: "github-markdown-light", ofType: "css") else {
            print("❌ File not found: github-markdown-light.css")
            return nil
        }
        
        process.arguments = [
            "pandoc",
            "-f", "markdown",
            "-t", "html",
            "--standalone",
            "--embed-resources",
            "-c", cssPath,
            "--metadata", "title=",
            "-V", "body-class=markdown-body",
            "--id-prefix=v",
            "--quiet"
        ]
        
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        process.standardInput = inputPipe
        
        do {
            try process.run()

            if let data = mdContent.data(using: .utf8) {
                try inputPipe.fileHandleForWriting.write(contentsOf: data)
                try inputPipe.fileHandleForWriting.close()
            }

            let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()

            if process.terminationStatus != 0 {
                let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
                let errorString = String(data: errorData, encoding: .utf8) ?? "未知錯誤"
                print("Error:\n\(errorString)")
                return nil
            }

            return String(data: data, encoding: .utf8)
        } catch {
            print("[Error] Error occurred while running Pandoc: \(error)")
            return nil
        }
    }

    private func resolveImports(in content: String, baseDirectory: URL, attachments: inout [String: URL]) -> String {
        let pattern = #"@import\s+["']([^"']+)["']"#
        let regex = try? NSRegularExpression(pattern: pattern, options: [])
        
        var newContent = content
        var offset = 0
        
        let matches = regex?.matches(in: content, options: [], range: NSRange(location: 0, length: content.utf16.count)) ?? []
        
        for match in matches {
            let fullRange = NSRange(location: match.range.location + offset, length: match.range.length)
            let fileNameRange = NSRange(location: match.range(at: 1).location + offset, length: match.range(at: 1).length)
            
            let fileName = (newContent as NSString).substring(with: fileNameRange)
            let fileURL = baseDirectory.appendingPathComponent(fileName)
            let fileExtension = fileURL.pathExtension.lowercased()
            
            var replacementString = ""
            
            if fileExtension == "md" {
                if let importedContent = try? String(contentsOf: fileURL, encoding: .utf8) {
                    replacementString = resolveImports(in: importedContent, baseDirectory: baseDirectory, attachments: &attachments)
                }
            } else if ["png", "jpg", "jpeg", "gif", "svg"].contains(fileExtension) {
                replacementString = "![](\(fileName))"
            } else if fileExtension == "pdf" {
                let id = "ATTACHMENT" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
                attachments[id] = fileURL
                
                replacementString = "\n\n<div style=\"page-break-before: always; page-break-after: always; font-size: 8px; color: white; white-space: nowrap;\">\(id)</div>\n\n"
            } else {
                replacementString = "> [MD2PDF Error] File not supported: \(fileName)"
            }
            
            if !replacementString.isEmpty {
                newContent = (newContent as NSString).replacingCharacters(in: fullRange, with: replacementString)
                offset += (replacementString.utf16.count - match.range.length)
            }
        }
        
        return newContent
    }
}

class PDFConverter: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
    let htmlContent: String
    let baseURL: URL
    let destURL: URL
    var webView: WKWebView!
    var window: NSWindow!
    let startTime: CFAbsoluteTime
    let attachments: [String: URL]
    
    let marginTop: String
    let marginBottom: String
    let marginLeft: String
    let marginRight: String

    init(htmlContent: String, baseURL: URL, destPath: String, top: String, bottom: String, left: String, right: String, startTime: CFAbsoluteTime, attachments: [String: URL]) {
        self.htmlContent = htmlContent
        self.baseURL = baseURL
        self.destURL = URL(fileURLWithPath: destPath)
        self.marginTop = top
        self.marginBottom = bottom
        self.marginLeft = left
        self.marginRight = right
        self.startTime = startTime
        self.attachments = attachments
        super.init()
    }

    func run() {
        
        print("[Start] Initializing headless WebKit environment...")
        let app = NSApplication.shared
        
        let a4Width: CGFloat = 596.0
        let a4Height: CGFloat = 843.0
        let rect = NSRect(x: 0, y: 0, width: a4Width, height: a4Height)
        
        window = NSWindow(contentRect: NSRect(x: -2000, y: -2000, width: a4Width, height: a4Height), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        
        let config = WKWebViewConfiguration()
        config.userContentController.add(self, name: "renderDone")
        
        let jsString = """
            var style = document.createElement('style');
            style.innerHTML = `@page { 
                margin-top: \(marginTop)cm !important; 
                margin-bottom: \(marginBottom)cm !important; 
                margin-left: \(marginLeft)cm !important; 
                margin-right: \(marginRight)cm !important; 
            }`;
            document.head.appendChild(style);

            var script = document.createElement('script');
            script.src = 'https://cdn.jsdelivr.net/npm/mermaid@10/dist/mermaid.min.js';
            script.onload = function() {
                document.querySelectorAll('pre.mermaid').forEach(function(el) {
                    var codeNode = el.querySelector('code');
                    if (codeNode) {
                        el.textContent = codeNode.textContent.trim();
                    } else {
                        el.textContent = el.textContent.trim();
                    }
                });
                
                mermaid.initialize({ startOnLoad: false, theme: 'default' });
                mermaid.run({ querySelector: 'pre.mermaid' }).then(function() {
                    window.webkit.messageHandlers.renderDone.postMessage("done");
                });
            };
            document.head.appendChild(script);
        """
        
        let script = WKUserScript(source: jsString, injectionTime: .atDocumentEnd, forMainFrameOnly: true)
        config.userContentController.addUserScript(script)
        
        webView = WKWebView(frame: rect, configuration: config)
        webView.navigationDelegate = self
        window.contentView = webView
        
        print("[Load] Loading HTML string into memory...")
        webView.loadHTMLString(self.htmlContent, baseURL: self.baseURL)
        
        app.run()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        print("[Render] HTML loaded. Waiting for layout reflow...")
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        if message.name == "renderDone" {
            self.generatePDF()
        }
    }
    
    func generatePDF() {
        let printInfo = NSPrintInfo.shared
        
        printInfo.paperSize = NSMakeSize(596.0, 843.0)
        printInfo.topMargin = 0
        printInfo.bottomMargin = 0
        printInfo.leftMargin = 0
        printInfo.rightMargin = 0
        
        printInfo.dictionary().setValue(NSNumber(value: false), forKey: NSPrintInfo.AttributeKey.headerAndFooter.rawValue)
        printInfo.jobDisposition = .save
        printInfo.dictionary().setValue(self.destURL, forKey: NSPrintInfo.AttributeKey.jobSavingURL.rawValue)
        
        let printOp = self.webView.printOperation(with: printInfo)
        printOp.showsPrintPanel = false
        printOp.showsProgressPanel = false
        
        let finalInfo = printOp.printInfo
        finalInfo.dictionary().removeObject(forKey: NSPrintInfo.AttributeKey.printer)
        finalInfo.dictionary().removeObject(forKey: NSPrintInfo.AttributeKey.printerName)
        
        print("=== Debug Info ===")
        print("Margins (cm): Top \(marginTop), Bottom \(marginBottom), Left \(marginLeft), Right \(marginRight)")
        print("System Margins: Disabled (0 pts)")
        print("==================")
        
        print("[Finish] Executing Print Operation modally...")
        printOp.runModal(for: self.window, delegate: self, didRun: #selector(printOperationDidRun(_:success:contextInfo:)), contextInfo: nil)
    }
    
    @objc func printOperationDidRun(_ printOperation: NSPrintOperation, success: Bool, contextInfo: UnsafeMutableRawPointer?) {
        let duration = (CFAbsoluteTimeGetCurrent() - self.startTime) * 1000
        if success {
            print(String(format: "✅ PDF rendered successfully! Duration: %.2f ms.", duration))
            
            // 👉 在程式結束前，攔截它並呼叫蓋章功能
            self.addPageNumbers(to: self.destURL)
            
            
        } else {
            print("❌ Error: PDF rendering failed")
            
        }
    }
    
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        print("[Error] Navigation failed: \(error.localizedDescription)")
        exit(1)
    }
    
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        print("[Error] Provisional navigation failed: \(error.localizedDescription)")
        exit(1)
    }

    private func addPageNumbers(to pdfURL: URL) {
        print("[3/3] Rendering page numbers with PDFKit...")
        
        // 🔥 關鍵 1：用陣列把附件的生命週期硬撐到存檔結束
        var keepAliveDocs: [PDFDocument] = []
        var attachmentPages = Set<Int>()
        
        guard let pdfData = try? Data(contentsOf: pdfURL),
              let document = PDFDocument(data: pdfData) else {
            print("Cannot read main PDF file to add page numbers")
            return
        }

        var i = 0
        while i < document.pageCount {
            guard let page = document.page(at: i) else {
                i += 1
                continue
            }
            
            let pageText = page.string ?? ""
            var foundAttachment = false
            
            // 👇 直接拿對照表裡的 ID 去檢查，有對到就塞檔案
            for (id, fileURL) in self.attachments {
                if pageText.contains(id) {
                    foundAttachment = true
                    print("Successfully found attachment tag, preparing to insert: \(fileURL.lastPathComponent)")
                    
                    document.removePage(at: i)
                    
                    if let insertData = try? Data(contentsOf: fileURL),
                       let insertDoc = PDFDocument(data: insertData) {
                        
                        keepAliveDocs.append(insertDoc)
                        
                        for j in 0..<insertDoc.pageCount {
                            if let pageToInsert = insertDoc.page(at: j) {
                                document.insert(pageToInsert, at: i + j)
                                attachmentPages.insert(i + j)
                            }
                        }
                        i += insertDoc.pageCount
                    } else {
                        print("Cannot read attachment file, please check the path: \(fileURL.path)")
                    }
                    break 
                }
            }
            
            if !foundAttachment {
                i += 1
            }
        }

        let totalPages = document.pageCount
        let mainPageCount = totalPages - attachmentPages.count 
        var currentMainPage = 0

        for i in 0..<totalPages {
            guard let page = document.page(at: i) else { continue }
            
            if attachmentPages.contains(i) {
                continue
            }
            
            currentMainPage += 1
            
            let bounds = page.bounds(for: .mediaBox)
            
            let text = "\(currentMainPage) / \(mainPageCount)"
            let font = NSFont(name: "Helvetica", size: 10) ?? NSFont.systemFont(ofSize: 10)
            
            let attributes: [NSAttributedString.Key: Any] = [.font: font]
            let textSize = (text as NSString).size(withAttributes: attributes)
            
            let startX = bounds.midX - (textSize.width / 2)
            let startY: CGFloat = 25.0 
            
            let annotationBounds = NSRect(x: startX - 5, y: startY, width: textSize.width + 10, height: textSize.height + 5)
            
            let annotation = PDFAnnotation(bounds: annotationBounds, forType: .widget, withProperties: nil)
            
            annotation.widgetFieldType = .text
            annotation.widgetStringValue = text
            annotation.font = font
            annotation.fontColor = NSColor.black
            annotation.alignment = .center
            annotation.color = NSColor.clear 
            
            annotation.isReadOnly = true 
            
            annotation.shouldPrint = true
            annotation.shouldDisplay = true
            
            page.addAnnotation(annotation)
        }
        
        if document.write(to: pdfURL) {
            print("Completed writing page numbers and attachments!")
            keepAliveDocs.removeAll() 
            self.sendSystemNotification()
            exit(0)
        } else {
            print("Failed to save page numbers")
            exit(1)
        }
    }

    private func sendSystemNotification() {
        let duration = (CFAbsoluteTimeGetCurrent() - self.startTime) * 1000
        let message = String(format: "PDF conversion completed! Total time: %.2f ms", duration)
        let fileName = self.destURL.lastPathComponent
        
        let script = "display notification \"\(message)\" with title \"MD2PDF\" subtitle \"\(fileName)\""
        
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        try? process.run()
    }
}