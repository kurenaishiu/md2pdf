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
        
        let t1 = CFAbsoluteTimeGetCurrent()
        print(" [Init]  File reading and initialization time: \(String(format: "%.2f", (t1 - globalStartTime) * 1000)) ms")

        print("[0/2] Parsing Markdown and resolving @import statements...")
        var attachments: [String: URL] = [:] 
        let finalMdContent = resolveImports(in: originalContent, baseDirectory: parentDir, attachments: &attachments)
        
        let t2 = CFAbsoluteTimeGetCurrent()
        print(" [Parse] @import recursive parsing and attachment fetching time: \(String(format: "%.2f", (t2 - t1) * 1000)) ms")
        
        print("[1/2] Converting Markdown to HTML...")
        guard let htmlString = convertMarkdownToHTML(mdContent: finalMdContent, baseDir: parentDir) else {
            print("Pandoc conversion failed")
            throw ExitCode.failure
        }

        let t3 = CFAbsoluteTimeGetCurrent()
        print(" [Pandoc]  HTML transformation and Base64 processing time: \(String(format: "%.2f", (t3 - t2) * 1000)) ms")

        print("[2/2] Rendering PDF (WebKit)...")
        let converter = PDFConverter(
            htmlContent: htmlString,
            markdownContent: finalMdContent,
            baseURL: parentDir,
            destPath: finalOutput,
            top: marginTop,
            bottom: marginBottom,
            left: marginLeft,
            right: marginRight,
            startTime: globalStartTime,
            webkitStartTime: t3,
            attachments: attachments
        )
        converter.run()
    }

    private func convertMarkdownToHTML(mdContent: String, baseDir: URL) -> String? {
        let process = Process()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        let inputPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        
        guard let cssPath = Bundle.module.path(forResource: "github-markdown-light", ofType: "css") else {
            print(" File not found: github-markdown-light.css")
            return nil
        }
        
        process.arguments = [
            "pandoc",
            "-f", "markdown",
            "-t", "html",
            "--standalone",
            "--embed-resources",
            "-c", cssPath,
            "--resource-path", baseDir.path,
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
                let errorString = String(data: errorData, encoding: .utf8) ?? "Unknown error"
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
        var visited = Set<URL>()
        return resolveImportsHelper(in: content, baseDirectory: baseDirectory, attachments: &attachments, visited: &visited)
    }

    private func resolveImportsHelper(in content: String, baseDirectory: URL, attachments: inout [String: URL], visited: inout Set<URL>) -> String {
        let pattern = #"@import\s+["']([^"']+)["']"#
        let regex = try? NSRegularExpression(pattern: pattern, options: [])
        
        var newContent = content
        let matches = regex?.matches(in: content, options: [], range: NSRange(location: 0, length: content.utf16.count)) ?? []
        
        for match in matches.reversed() {
            let fullRange = match.range
            let fileNameRange = match.range(at: 1)
            
            let fileName = (content as NSString).substring(with: fileNameRange)
            let fileURL = baseDirectory.appendingPathComponent(fileName).standardizedFileURL
            let fileExtension = fileURL.pathExtension.lowercased()
            
            var replacementString = ""
            
            if fileExtension == "md" {
                if visited.contains(fileURL) {
                    replacementString = "> [MD2PDF Warning] Ignoring circular reference: \(fileName)"
                } else {
                    visited.insert(fileURL)
                    if let importedContent = try? String(contentsOf: fileURL, encoding: .utf8) {
                        let newBaseDir = fileURL.deletingLastPathComponent()
                        replacementString = resolveImportsHelper(in: importedContent, baseDirectory: newBaseDir, attachments: &attachments, visited: &visited)
                    } else {
                        replacementString = "> [MD2PDF Error] Unable to read file: \(fileName)"
                    }
                }
            } else if ["png", "jpg", "jpeg", "gif", "svg"].contains(fileExtension) {
                replacementString = "![](\(fileURL.path))"
            } else if fileExtension == "pdf" {
                let id = "ATTACHMENT" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
                attachments[id] = fileURL
                
                replacementString = "\n\n<div style=\"page-break-before: always; page-break-after: always; padding: 20px; font-size: 16px; color: black; font-family: monospace;\">\(id)</div>\n\n"
            } else {
                replacementString = "> [MD2PDF Error] File not supported: \(fileName)"
            }
            
            if !replacementString.isEmpty {
                newContent = (newContent as NSString).replacingCharacters(in: fullRange, with: replacementString)
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
    let webkitStartTime: CFAbsoluteTime
    var ramStartTime: CFAbsoluteTime = 0
    var webviewInitTime: CFAbsoluteTime = 0
    var domLoadTime: CFAbsoluteTime = 0
    var jsRenderTime: CFAbsoluteTime = 0
    let attachments: [String: URL]
    let markdownContent: String
    
    let marginTop: String
    let marginBottom: String
    let marginLeft: String
    let marginRight: String
    
    var extractedTOC: [[String: Any]] = []

    init(htmlContent: String, markdownContent: String, baseURL: URL, destPath: String, top: String, bottom: String, left: String, right: String, startTime: CFAbsoluteTime, webkitStartTime: CFAbsoluteTime, attachments: [String: URL]) {
        self.htmlContent = htmlContent
        self.markdownContent = markdownContent
        self.baseURL = baseURL
        self.destURL = URL(fileURLWithPath: destPath)
        self.marginTop = top
        self.marginBottom = bottom
        self.marginLeft = left
        self.marginRight = right
        self.startTime = startTime
        self.webkitStartTime = webkitStartTime
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
        
        let styleScript = WKUserScript(source: """
            var style = document.createElement('style');
            style.innerHTML = `@page { 
                margin-top: \(marginTop)cm !important; 
                margin-bottom: \(marginBottom)cm !important; 
                margin-left: \(marginLeft)cm !important; 
                margin-right: \(marginRight)cm !important; 
            }`;
            document.head.appendChild(style);
        """, injectionTime: .atDocumentEnd, forMainFrameOnly: true)
        config.userContentController.addUserScript(styleScript)
        
        let tocExtractionJS = """
            function sendRenderDone() {
                var toc = [];
                document.querySelectorAll('h1, h2, h3, h4, h5, h6').forEach(function(h, index) {
                    var titleText = h.innerText.trim();
                    var marker = '{{TOC:' + index + '}}';
                    var span = document.createElement('span');
                    span.style.cssText = 'font-size: 1px; color: #fefefe; position: absolute; opacity: 0.01; pointer-events: none;';
                    span.innerText = marker;
                    h.appendChild(span);
                    
                    toc.push({ level: parseInt(h.tagName.substring(1)), title: titleText, marker: marker });
                });
                
                window.webkit.messageHandlers.renderDone.postMessage(JSON.stringify({ status: 'done', toc: toc }));
            }
        """
        let tocScript = WKUserScript(source: tocExtractionJS, injectionTime: .atDocumentEnd, forMainFrameOnly: true)
        config.userContentController.addUserScript(tocScript)

        if self.markdownContent.contains("```mermaid") {
            if let mermaidJS = self.getMermaidJS() {
                let coreScript = WKUserScript(source: mermaidJS, injectionTime: .atDocumentEnd, forMainFrameOnly: true)
                config.userContentController.addUserScript(coreScript)
                
                let runScript = WKUserScript(source: """
                    document.querySelectorAll('pre.mermaid').forEach(function(el) {
                        var codeNode = el.querySelector('code');
                        el.textContent = codeNode ? codeNode.textContent.trim() : el.textContent.trim();
                    });
                    mermaid.initialize({ startOnLoad: false, theme: 'default' });
                    mermaid.run({ querySelector: 'pre.mermaid' }).then(function() {
                        sendRenderDone();
                    }).catch(function(e) {
                        sendRenderDone();
                    });
                """, injectionTime: .atDocumentEnd, forMainFrameOnly: true)
                config.userContentController.addUserScript(runScript)
            } else {
                print(" [MD2PDF Warning] Unable to fetch Mermaid engine, charts may not render correctly.")
                let fallbackScript = WKUserScript(source: "sendRenderDone();", injectionTime: .atDocumentEnd, forMainFrameOnly: true)
                config.userContentController.addUserScript(fallbackScript)
            }
        } else {
            let instantDoneScript = WKUserScript(source: "sendRenderDone();", injectionTime: .atDocumentEnd, forMainFrameOnly: true)
            config.userContentController.addUserScript(instantDoneScript)
        }
        
        webView = WKWebView(frame: rect, configuration: config)
        webView.navigationDelegate = self
        window.contentView = webView
        
        print("[Load] Loading HTML string into memory...")
        webView.loadHTMLString(self.htmlContent, baseURL: self.baseURL)
        print("[Load] Loading HTML string with baseURL: \(self.baseURL.path)")
        self.webviewInitTime = CFAbsoluteTimeGetCurrent()
        print(" ↳ [1/4]  WebKit and JS : \(String(format: "%.2f", (self.webviewInitTime - self.webkitStartTime) * 1000)) ms")
        app.run()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        print("[Render] HTML loaded. Waiting for layout reflow...")
        self.domLoadTime = CFAbsoluteTimeGetCurrent()
        print(" ↳ [2/4] DOM: \(String(format: "%.2f", (self.domLoadTime - self.webviewInitTime) * 1000)) ms")
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        if message.name == "renderDone" {
            self.jsRenderTime = CFAbsoluteTimeGetCurrent()
            let previousTime = self.domLoadTime > 0 ? self.domLoadTime : self.webviewInitTime
            print(" ↳ [3/4] JS conduct: \(String(format: "%.2f", (self.jsRenderTime - previousTime) * 1000)) ms")
            if let bodyString = message.body as? String,
               let data = bodyString.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
               let status = json["status"] as? String, status == "done" {
                
                if let toc = json["toc"] as? [[String: Any]] {
                    self.extractedTOC = toc
                }
            }
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
        
        print("=== Debug Info ===")
        print("Margins (cm): Top \(marginTop), Bottom \(marginBottom), Left \(marginLeft), Right \(marginRight)")
        print("System Margins: Disabled (0 pts)")
        print("==================")
        
        print("[Finish] Executing Print Operation modally...")
        printOp.runModal(for: self.window, delegate: self, didRun: #selector(printOperationDidRun(_:success:contextInfo:)), contextInfo: nil)
    }
    
    @objc func printOperationDidRun(_ printOperation: NSPrintOperation, success: Bool, contextInfo: UnsafeMutableRawPointer?) {
        if success {
            let printDoneTime = CFAbsoluteTimeGetCurrent()
            print(" ↳ [4/4] print PDF : \(String(format: "%.2f", (printDoneTime - self.jsRenderTime) * 1000)) ms")
            
            let webkitDuration = (printDoneTime - self.webkitStartTime) * 1000
            print(" [WebKit Total] Browser cold start, layout, and initial PDF output total time: \(String(format: "%.2f", webkitDuration)) ms")
            
            self.ramStartTime = CFAbsoluteTimeGetCurrent()
            self.processPDF(at: self.destURL)
            
        } else {
            print("Error: PDF rendering failed")
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

    private func processPDF(at pdfURL: URL) {
        print("[3/3] Using (RAM) to insert attachments, outline, and page numbers...")
        
        guard let document = PDFDocument(url: pdfURL) else {
            print("Unable to read main PDF file")
            exit(1)
        }

        var keepAliveDocs: [PDFDocument] = []
        var attachmentPages = Set<Int>()
        var attachmentNames = [Int: String]()

        injectAttachments(into: document, keepAliveDocs: &keepAliveDocs, attachmentPages: &attachmentPages, attachmentNames: &attachmentNames)

        let tempOutlineNodes = buildOutlineData(for: document, attachmentNames: attachmentNames)

        let outlineRoot = PDFOutline()
        applyOutlineData(tempOutlineNodes, to: document, root: outlineRoot)
        if outlineRoot.numberOfChildren > 0 {
            document.outlineRoot = outlineRoot
        }

        let totalPages = document.pageCount
        let mainPageCount = totalPages - attachmentPages.count
        var currentMainPage = 0

        for i in 0..<totalPages {
            guard let page = document.page(at: i) else { continue }
            
            if attachmentPages.contains(i) { continue } 
            
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
            let ramDuration = (CFAbsoluteTimeGetCurrent() - self.ramStartTime) * 1000
            print(" [PDFKit] RAM processing and saving time: \(String(format: "%.2f", ramDuration)) ms")
            
            let totalDuration = (CFAbsoluteTimeGetCurrent() - self.startTime) * 1000
            print("[Total Time] Perfectly completed: \(String(format: "%.2f", totalDuration)) ms")
            
            keepAliveDocs.removeAll()
            self.sendSystemNotification()
            exit(0)
        } else {
            print("Failed to save file")
            exit(1)
        }
    }

    struct OutlineNode {
        let level: Int
        let label: String
        let pageIndex: Int
        let point: NSPoint
    }

    private func buildOutlineData(for document: PDFDocument, attachmentNames: [Int: String]) -> [OutlineNode] {
        var nodes: [OutlineNode] = []
        for item in self.extractedTOC {
            guard let level = item["level"] as? Int,
                  let title = item["title"] as? String,
                  let marker = item["marker"] as? String else { continue }
            
            let selections = document.findString(marker, withOptions: [])
            if let firstSelection = selections.first, let page = firstSelection.pages.first {
                let pageIndex = document.index(for: page)
                let bounds = firstSelection.bounds(for: page)
                let point = NSPoint(x: 0, y: bounds.maxY + 20)
                nodes.append(OutlineNode(level: level, label: title.isEmpty ? "Untitled" : title, pageIndex: pageIndex, point: point))
            } else {
                print(" [Debug] Unable to find marker: \(marker) (\(title))")
            }
        }
        
        let sortedAttachmentPages = attachmentNames.keys.sorted()
        for pageIndex in sortedAttachmentPages {
            guard let page = document.page(at: pageIndex) else { continue }
            let point = NSPoint(x: 0, y: page.bounds(for: .mediaBox).height)
            nodes.append(OutlineNode(level: 1, label: attachmentNames[pageIndex] ?? "attachment", pageIndex: pageIndex, point: point))
        }
        return nodes
    }

    private func applyOutlineData(_ nodes: [OutlineNode], to document: PDFDocument, root: PDFOutline) {
        var lastNodeAtLevel: [Int: PDFOutline] = [0: root]
        for node in nodes {
            guard let page = document.page(at: node.pageIndex) else { continue }
            let outline = PDFOutline()
            outline.label = node.label
            outline.isOpen = true
            outline.destination = PDFDestination(page: page, at: node.point)
            
            var parentLevel = node.level - 1
            while parentLevel > 0 && lastNodeAtLevel[parentLevel] == nil { parentLevel -= 1 }
            
            let parentNode = lastNodeAtLevel[parentLevel] ?? root
            parentNode.insertChild(outline, at: parentNode.numberOfChildren)
            
            lastNodeAtLevel[node.level] = outline
            for i in (node.level + 1)...6 { lastNodeAtLevel[i] = nil }
        }
    }

    private func injectAttachments(into document: PDFDocument, keepAliveDocs: inout [PDFDocument], attachmentPages: inout Set<Int>, attachmentNames: inout [Int: String]) {
        var i = 0
        while i < document.pageCount {
            guard let page = document.page(at: i) else { i += 1; continue }
            let cleanPageText = (page.string ?? "").components(separatedBy: .alphanumerics.inverted).joined()
            var foundAttachment = false
            
            for (id, fileURL) in self.attachments {
                if cleanPageText.contains(id) {
                    foundAttachment = true
                    document.removePage(at: i)
                    if let insertData = try? Data(contentsOf: fileURL),
                       let insertDoc = PDFDocument(data: insertData) {
                        keepAliveDocs.append(insertDoc)
                        let fileNameWithoutExtension = fileURL.deletingPathExtension().lastPathComponent
                        for j in 0..<insertDoc.pageCount {
                            if let pageToInsert = insertDoc.page(at: j) {
                                document.insert(pageToInsert, at: i + j)
                                let absoluteIndex = i + j
                                attachmentPages.insert(absoluteIndex)
                                if j == 0 { attachmentNames[absoluteIndex] = fileNameWithoutExtension }
                            }
                        }
                        i += insertDoc.pageCount
                    }
                    break 
                }
            }
            if !foundAttachment { i += 1 }
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

    private func getMermaidJS() -> String? {
        let fileManager = FileManager.default
        guard let cacheDir = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first?.appendingPathComponent("md2pdf") else {
            return nil
        }
        let localJSURL = cacheDir.appendingPathComponent("mermaid.min.js")
        if fileManager.fileExists(atPath: localJSURL.path) {
            return try? String(contentsOf: localJSURL, encoding: .utf8)
        }
        guard let remoteURL = URL(string: "[https://cdn.jsdelivr.net/npm/mermaid@10/dist/mermaid.min.js](https://cdn.jsdelivr.net/npm/mermaid@10/dist/mermaid.min.js)") else { return nil }
        do {
            let jsString = try String(contentsOf: remoteURL, encoding: .utf8)
            try fileManager.createDirectory(at: cacheDir, withIntermediateDirectories: true, attributes: nil)
            try jsString.write(to: localJSURL, atomically: true, encoding: .utf8)
            return jsString
        } catch {
            return nil
        }
    }
}