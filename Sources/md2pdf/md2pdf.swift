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
        print("⏱️ [Init] 檔案讀取與初始化耗時: \(String(format: "%.2f", (t1 - globalStartTime) * 1000)) ms")

        print("[0/2] Parsing Markdown and resolving @import statements...")
        var attachments: [String: URL] = [:] 
        let finalMdContent = resolveImports(in: originalContent, baseDirectory: parentDir, attachments: &attachments)
        
        let t2 = CFAbsoluteTimeGetCurrent()
        print("⏱️ [Parse] @import 遞迴解析與附件擷取耗時: \(String(format: "%.2f", (t2 - t1) * 1000)) ms")
        
        print("[1/2] Converting Markdown to HTML...")
        guard let htmlString = convertMarkdownToHTML(mdContent: finalMdContent, baseDir: parentDir) else {
            print("Pandoc conversion failed")
            throw ExitCode.failure
        }

        let t3 = CFAbsoluteTimeGetCurrent()
        print("⏱️ [Pandoc] HTML 轉換與 Base64 處理耗時: \(String(format: "%.2f", (t3 - t2) * 1000)) ms")

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
            webkitStartTime: t3,  // 💡 新增這行：把 WebKit 起跑點傳進去
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
        
        guard let cssPath = Bundle.module.path(forResource: "github-markdown-light", ofType: "css"),
              let cssContent = try? String(contentsOfFile: cssPath, encoding: .utf8) else {
            print("❌ File not found or unreadable: github-markdown-light.css")
            return nil
        }
        
        process.arguments = [
            "pandoc",
            "-f", "markdown",
            "-t", "html",
            "--standalone",
            "--embed-resources",
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
                let errorString = String(data: errorData, encoding: .utf8) ?? "未知錯誤"
                print("Error:\n\(errorString)")
                return nil
            }

            var htmlResult = String(data: data, encoding: .utf8) ?? ""
            // 💡 暴力破解：直接把 CSS 原始碼塞進 HTML 裡面，WKWebView 就絕對會吃！
            htmlResult = htmlResult.replacingOccurrences(of: "</head>", with: "<style>\n\(cssContent)\n</style>\n</head>")
            return htmlResult
            
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
        
        // 💡 關鍵修正 1：從後往前替換 (reversed)，徹底避開 offset 計算錯誤導致的當機
        for match in matches.reversed() {
            let fullRange = match.range
            let fileNameRange = match.range(at: 1)
            
            let fileName = (content as NSString).substring(with: fileNameRange)
            let fileURL = baseDirectory.appendingPathComponent(fileName).standardizedFileURL
            let fileExtension = fileURL.pathExtension.lowercased()
            
            var replacementString = ""
            
            if fileExtension == "md" {
                // 💡 關鍵修正 2：檢查是否循環引用，防止無限遞迴卡死
                if visited.contains(fileURL) {
                    replacementString = "> [MD2PDF 警告] 忽略循環引用: \(fileName)"
                } else {
                    visited.insert(fileURL)
                    if let importedContent = try? String(contentsOf: fileURL, encoding: .utf8) {
                        // 💡 關鍵修正 3：遞迴時更新 baseDirectory，這樣不同資料夾裡的 md 互相引用時，圖片路徑才不會爛掉
                        let newBaseDir = fileURL.deletingLastPathComponent()
                        replacementString = resolveImportsHelper(in: importedContent, baseDirectory: newBaseDir, attachments: &attachments, visited: &visited)
                    } else {
                        replacementString = "> [MD2PDF 錯誤] 無法讀取檔案: \(fileName)"
                    }
                }
            } else if ["png", "jpg", "jpeg", "gif", "svg"].contains(fileExtension) {
                // 順手修復：將圖片轉為絕對路徑，防止 Pandoc 找不到跨資料夾的圖片
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
    // 儲存從 WebKit 傳遞過來的精準目錄結構
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
        self.webkitStartTime = webkitStartTime // 💡 接住起跑時間
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
        
        // 1. 注入 CSS 樣式與 @page 設定
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
        
        // --- 定義抓取目錄的通用 JS 函數 ---
        let tocExtractionJS = """
            function sendRenderDone() {
                var toc = [];
                document.querySelectorAll('h1, h2, h3, h4, h5, h6').forEach(function(h, index) {
                    // 1. 取得畫面上真正顯示的乾淨文字 (完美避開 Markdown 符號)
                    var titleText = h.innerText.trim();
                    
                    // 2. 插入獨一無二的隱形標記供 Swift 尋找
                    var marker = '{{TOC:' + index + '}}';
                    var span = document.createElement('span');
                    span.style.cssText = 'font-size: 1px; color: #fefefe; position: absolute; opacity: 0.01; pointer-events: none;';
                    span.innerText = marker;
                    h.appendChild(span);
                    
                    toc.push({ level: parseInt(h.tagName.substring(1)), title: titleText, marker: marker });
                });
                
                // 將結果包成 JSON 字串傳給 Swift
                window.webkit.messageHandlers.renderDone.postMessage(JSON.stringify({ status: 'done', toc: toc }));
            }
        """
        let tocScript = WKUserScript(source: tocExtractionJS, injectionTime: .atDocumentEnd, forMainFrameOnly: true)
        config.userContentController.addUserScript(tocScript)

        // --- 雙重優化：先檢查 Markdown 內有沒有流程圖 ---
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
                        sendRenderDone(); // 渲染成功後回傳目錄
                    }).catch(function(e) {
                        sendRenderDone(); // 就算失敗也要回傳避免卡死
                    });
                """, injectionTime: .atDocumentEnd, forMainFrameOnly: true)
                config.userContentController.addUserScript(runScript)
            } else {
                print("❌ 警告：無法取得 Mermaid 引擎，圖表可能無法渲染")
                let fallbackScript = WKUserScript(source: "sendRenderDone();", injectionTime: .atDocumentEnd, forMainFrameOnly: true)
                config.userContentController.addUserScript(fallbackScript)
            }
        } else {
            // 🎉 如果沒有圖表，直接秒速抓目錄並通知排版完成！
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
        print("  ⏳ ↳ [1/4] WebKit 實體化與 JS 腳本注入耗時: \(String(format: "%.2f", (self.webviewInitTime - self.webkitStartTime) * 1000)) ms")
        app.run()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        print("[Render] HTML loaded. Waiting for layout reflow...")
        self.domLoadTime = CFAbsoluteTimeGetCurrent()
        print("  ⏳ ↳ [2/4] DOM 結構解析與資源載入耗時: \(String(format: "%.2f", (self.domLoadTime - self.webviewInitTime) * 1000)) ms")
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        if message.name == "renderDone" {
            self.jsRenderTime = CFAbsoluteTimeGetCurrent()
            let previousTime = self.domLoadTime > 0 ? self.domLoadTime : self.webviewInitTime
            print("  ⏳ ↳ [3/4] JS 腳本執行 (含圖表渲染) 耗時: \(String(format: "%.2f", (self.jsRenderTime - previousTime) * 1000)) ms")
            if let bodyString = message.body as? String,
               let data = bodyString.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
               let status = json["status"] as? String, status == "done" {
                
                // 接收並儲存 JS 幫我們建好的精準目錄
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
        //finalInfo.dictionary().removeObject(forKey: NSPrintInfo.AttributeKey.printerName)
        
        print("=== Debug Info ===")
        print("Margins (cm): Top \(marginTop), Bottom \(marginBottom), Left \(marginLeft), Right \(marginRight)")
        print("System Margins: Disabled (0 pts)")
        print("==================")
        
        print("[Finish] Executing Print Operation modally...")
        printOp.runModal(for: self.window, delegate: self, didRun: #selector(printOperationDidRun(_:success:contextInfo:)), contextInfo: nil)
    }
    
    @objc func printOperationDidRun(_ printOperation: NSPrintOperation, success: Bool, contextInfo: UnsafeMutableRawPointer?) {
        if success {
            // 👇 新增列印耗時與修改原本的總耗時輸出
            let printDoneTime = CFAbsoluteTimeGetCurrent()
            print("  ⏳ ↳ [4/4] 系統虛擬列印轉出初版 PDF 耗時: \(String(format: "%.2f", (printDoneTime - self.jsRenderTime) * 1000)) ms")
            
            let webkitDuration = (printDoneTime - self.webkitStartTime) * 1000
            print("⏱️ [WebKit 總結] 瀏覽器冷啟動、排版與初版 PDF 輸出總耗時: \(String(format: "%.2f", webkitDuration)) ms")
            // 👆
            
            // 記錄下一個階段（記憶體處理）的開始時間
            self.ramStartTime = CFAbsoluteTimeGetCurrent()
            
            self.processPDF(at: self.destURL)
            
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

    // MARK: - 1. 總指揮
    private func processPDF(at pdfURL: URL) {
        print("[3/3] 正在透過記憶體 (RAM) 影像化頁碼與處理附件、目錄...")
        
        guard let baseDoc = PDFDocument(url: pdfURL) else {
            print("❌ 無法讀取主文件 PDF")
            exit(1)
        }

        var keepAliveDocs: [PDFDocument] = []
        var attachmentPages = Set<Int>()
        var attachmentNames = [Int: String]()

        // 1. 插入附件
        injectAttachments(into: baseDoc, keepAliveDocs: &keepAliveDocs, attachmentPages: &attachmentPages, attachmentNames: &attachmentNames)

        // 💡 關鍵順序：在影像化「之前」，先用原本未破壞的 baseDoc 算出所有目錄的確切頁數與座標
        let tempOutlineNodes = buildOutlineData(for: baseDoc, attachmentNames: attachmentNames)

        // 2. 記憶體極速燒錄頁碼 (你最在意的防編輯功能回來了！)
        guard let flatDoc = flattenAndAddPageNumbers(to: baseDoc, attachmentPages: attachmentPages) else {
            print("❌ CoreGraphics 處理失敗")
            exit(1)
        }

        // 3. 把剛才算好的目錄座標，掛載到「全新燒好」的 flatDoc 上
        let outlineRoot = PDFOutline()
        applyOutlineData(tempOutlineNodes, to: flatDoc, root: outlineRoot)
        if outlineRoot.numberOfChildren > 0 {
            flatDoc.outlineRoot = outlineRoot
        }

        // 4. 存檔與替換
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".pdf")
        if flatDoc.write(to: tempURL) {
            try? FileManager.default.removeItem(at: pdfURL)
            do {
                try FileManager.default.moveItem(at: tempURL, to: pdfURL)
                
                let ramDuration = (CFAbsoluteTimeGetCurrent() - self.ramStartTime) * 1000
                print("⏱️ [CoreGraphics] 記憶體燒錄頁碼與目錄掛載耗時: \(String(format: "%.2f", ramDuration)) ms")
                
                let totalDuration = (CFAbsoluteTimeGetCurrent() - self.startTime) * 1000
                print("🏁 [總耗時] 完美打完收工：\(String(format: "%.2f", totalDuration)) ms")
                
                keepAliveDocs.removeAll()
                self.sendSystemNotification()
                exit(0)
            } catch {
                print("❌ 替換原檔案失敗: \(error.localizedDescription)")
                exit(1)
            }
        } else {
            print("❌ 存檔失敗")
            exit(1)
        }
    }

    // MARK: - 2. 目錄座標暫存器 (輔助結構)
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
            
            // 在未被破壞的原始 PDF 中尋找隱形標記
            let selections = document.findString(marker, withOptions: [])
            if let firstSelection = selections.first, let page = firstSelection.pages.first {
                let pageIndex = document.index(for: page)
                let bounds = firstSelection.bounds(for: page)
                let point = NSPoint(x: 0, y: bounds.maxY + 20)
                nodes.append(OutlineNode(level: level, label: title.isEmpty ? "Untitled" : title, pageIndex: pageIndex, point: point))
            } else {
                print("⚠️ [Debug] 找不到標記: \(marker) (\(title))")
            }
        }
        
        let sortedAttachmentPages = attachmentNames.keys.sorted()
        for pageIndex in sortedAttachmentPages {
            guard let page = document.page(at: pageIndex) else { continue }
            let point = NSPoint(x: 0, y: page.bounds(for: .mediaBox).height)
            nodes.append(OutlineNode(level: 1, label: attachmentNames[pageIndex] ?? "附件", pageIndex: pageIndex, point: point))
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

    // MARK: - 3. 核心燒錄與連結移植 (記憶體極速版)
    private func flattenAndAddPageNumbers(to oldDoc: PDFDocument, attachmentPages: Set<Int>) -> PDFDocument? {
        let pdfData = NSMutableData()
        guard let dataConsumer = CGDataConsumer(data: pdfData as CFMutableData),
              let writeContext = CGContext(consumer: dataConsumer, mediaBox: nil, nil) else { return nil }

        guard let oldPdfData = oldDoc.dataRepresentation(),
              let dataProvider = CGDataProvider(data: oldPdfData as CFData),
              let cgOldDoc = CGPDFDocument(dataProvider) else { return nil }

        let totalPages = oldDoc.pageCount
        let mainPageCount = totalPages - attachmentPages.count
        var currentMainPage = 0

        for i in 0..<totalPages {
            guard let oldPage = oldDoc.page(at: i),
                  let cgPage = cgOldDoc.page(at: i + 1) else { continue }

            var mediaBox = oldPage.bounds(for: .mediaBox)
            writeContext.beginPage(mediaBox: &mediaBox)
            writeContext.drawPDFPage(cgPage)

            if !attachmentPages.contains(i) {
                currentMainPage += 1
                let text = "\(currentMainPage) / \(mainPageCount)"
                let font = NSFont(name: "Helvetica", size: 10) ?? NSFont.systemFont(ofSize: 10)
                let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.black]
                let attributedString = NSAttributedString(string: text, attributes: attributes)
                let line = CTLineCreateWithAttributedString(attributedString)
                let textBounds = CTLineGetBoundsWithOptions(line, [])

                let startX = mediaBox.midX - (textBounds.width / 2)
                let startY: CGFloat = 25.0

                writeContext.saveGState()
                writeContext.textMatrix = CGAffineTransform.identity
                writeContext.translateBy(x: startX, y: startY)
                CTLineDraw(line, writeContext)
                writeContext.restoreGState()
            }
            writeContext.endPage()
        }
        writeContext.closePDF()

        guard let flatDoc = PDFDocument(data: pdfData as Data) else { return nil }

        // 移植超連結
        for i in 0..<totalPages {
            guard let oldPage = oldDoc.page(at: i),
                  let flatPage = flatDoc.page(at: i) else { continue }

            for annotation in oldPage.annotations {
                if annotation.type == "Link" {
                    if let newAnn = annotation.copy() as? PDFAnnotation {
                        if let oldDest = annotation.destination, let destPage = oldDest.page {
                            let destPageIndex = oldDoc.index(for: destPage)
                            if destPageIndex != NSNotFound, let newDestPage = flatDoc.page(at: destPageIndex) {
                                newAnn.destination = PDFDestination(page: newDestPage, at: oldDest.point)
                            }
                        }
                        flatPage.addAnnotation(newAnn)
                    }
                }
            }
        }
        return flatDoc
    }

    // MARK: - 4. 插入附件
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

    // MARK: - 自動取得並快取 Mermaid JS
    private func getMermaidJS() -> String? {
        let fileManager = FileManager.default
        // 取得 macOS 使用者專用的 Cache 資料夾： ~/Library/Caches/md2pdf/
        guard let cacheDir = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first?.appendingPathComponent("md2pdf") else {
            return nil
        }
        
        let localJSURL = cacheDir.appendingPathComponent("mermaid.min.js")
        
        // 1. 如果本機已經有暫存檔，直接秒殺讀取
        if fileManager.fileExists(atPath: localJSURL.path) {
            print("🌊 從本機快取載入 Mermaid 引擎...")
            return try? String(contentsOf: localJSURL, encoding: .utf8)
        }
        
        // 2. 如果沒有，就自動連網下載
        print("📥 首次遇到圖表，正在自動下載 Mermaid 引擎至本機...")
        guard let remoteURL = URL(string: "https://cdn.jsdelivr.net/npm/mermaid@10/dist/mermaid.min.js") else {
            return nil
        }
        
        do {
            // 同步下載（CLI 工具會在這裡稍微等一下）
            let jsString = try String(contentsOf: remoteURL, encoding: .utf8)
            
            // 建立快取目錄並存檔
            try fileManager.createDirectory(at: cacheDir, withIntermediateDirectories: true, attributes: nil)
            try jsString.write(to: localJSURL, atomically: true, encoding: .utf8)
            
            print("✅ Mermaid 下載完成！已建立本機快取，未來將瞬間載入。")
            return jsString
        } catch {
            print("❌ Mermaid 下載失敗，請檢查網路連線：\(error.localizedDescription)")
            return nil
        }
    }
}

    
