import Foundation
import Network

struct FileFingerprint: Equatable {
    let size: Int
    let modificationDate: Date
}

func fail(_ message: String, status: Int32 = 1) -> Never {
    fputs("\(message)\n", stderr)
    exit(status)
}

func fileFingerprint(at url: URL) throws -> FileFingerprint? {
    guard FileManager.default.fileExists(atPath: url.path) else {
        return nil
    }

    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    guard let size = attributes[.size] as? Int,
          let modificationDate = attributes[.modificationDate] as? Date else {
        throw NSError(
            domain: "md2safari",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Could not read PDF file attributes."]
        )
    }
    return FileFingerprint(size: size, modificationDate: modificationDate)
}

final class InMemoryHTMLServer {
    private let html: Data
    private let mermaidJavaScript: Data?
    private let documentRoute = "/document.html"
    private let mermaidRoute = "/mermaid.min.js"
    private let queue = DispatchQueue(label: "md2pdf.html-server")
    private let listener: NWListener

    init(html: Data, mermaidJavaScript: Data?) throws {
        self.html = html
        self.mermaidJavaScript = mermaidJavaScript
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(
            host: NWEndpoint.Host("127.0.0.1"),
            port: .any
        )
        listener = try NWListener(using: parameters, on: .any)
    }

    func start() throws -> URL {
        let ready = DispatchSemaphore(value: 0)
        var result: Result<UInt16, Error>?

        listener.newConnectionHandler = { [weak self] connection in
            guard let self else {
                connection.cancel()
                return
            }
            connection.start(queue: self.queue)
            self.receiveRequest(on: connection)
        }

        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                if let port = self.listener.port?.rawValue {
                    result = .success(port)
                } else {
                    result = .failure(NSError(
                        domain: "md2pdf.html-server",
                        code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "The local HTML server has no listening port."]
                    ))
                }
                ready.signal()
            case .failed(let error):
                result = .failure(error)
                ready.signal()
            default:
                break
            }
        }
        listener.start(queue: queue)
        ready.wait()

        guard let result else {
            throw NSError(
                domain: "md2pdf.html-server",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "The local HTML server did not start."]
            )
        }
        let port = try result.get()
        guard let url = URL(string: "http://127.0.0.1:\(port)\(documentRoute)") else {
            throw NSError(
                domain: "md2pdf.html-server",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: "Could not create the local HTML URL."]
            )
        }
        return url
    }

    func stop() {
        listener.cancel()
    }

    private func receiveRequest(on connection: NWConnection, accumulatedData: Data = Data()) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) {
            [weak self] data, _, isComplete, error in
            guard let self else {
                connection.cancel()
                return
            }
            var requestData = accumulatedData
            if let data {
                requestData.append(data)
            }

            let request = String(decoding: requestData, as: UTF8.self)
            if request.contains("\r\n\r\n") || isComplete || error != nil {
                let requestPath = request
                    .components(separatedBy: "\r\n")
                    .first?
                    .split(separator: " ")
                    .dropFirst()
                    .first
                let responseContent: (status: String, contentType: String, body: Data)
                if requestPath == Substring(self.documentRoute) {
                    responseContent = ("200 OK", "text/html; charset=utf-8", self.html)
                } else if requestPath == Substring(self.mermaidRoute),
                          let mermaidJavaScript = self.mermaidJavaScript {
                    responseContent = ("200 OK", "text/javascript; charset=utf-8", mermaidJavaScript)
                } else {
                    responseContent = ("404 Not Found", "text/plain; charset=utf-8", Data("Not Found".utf8))
                }
                var response = Data(
                    "HTTP/1.1 \(responseContent.status)\r\nContent-Type: \(responseContent.contentType)\r\nContent-Length: \(responseContent.body.count)\r\nConnection: close\r\nCache-Control: no-store\r\n\r\n".utf8
                )
                response.append(responseContent.body)
                connection.send(content: response, completion: .contentProcessed { _ in
                    connection.cancel()
                })
            } else {
                self.receiveRequest(on: connection, accumulatedData: requestData)
            }
        }
    }
}

func loadMermaidJavaScript() throws -> Data {
    let fileManager = FileManager.default
    guard let cachesDirectory = fileManager.urls(
        for: .cachesDirectory,
        in: .userDomainMask
    ).first else {
        throw NSError(
            domain: "md2pdf.mermaid",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Could not locate the user cache directory."]
        )
    }

    let cacheDirectory = cachesDirectory.appendingPathComponent("md2pdf", isDirectory: true)
    let cacheURL = cacheDirectory.appendingPathComponent("mermaid-v11.17.min.js")
    if fileManager.fileExists(atPath: cacheURL.path) {
        let cachedJavaScript = try Data(contentsOf: cacheURL)
        guard !cachedJavaScript.isEmpty else {
            throw NSError(
                domain: "md2pdf.mermaid",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Cached Mermaid JavaScript is empty."]
            )
        }
        return cachedJavaScript
    }

    guard let remoteURL = URL(string: "https://cdn.jsdelivr.net/npm/mermaid@11.17.0/dist/mermaid.min.js") else {
        throw NSError(
            domain: "md2pdf.mermaid",
            code: 3,
            userInfo: [NSLocalizedDescriptionKey: "Could not create the Mermaid download URL."]
        )
    }
    let javaScript = try Data(contentsOf: remoteURL)
    guard !javaScript.isEmpty else {
        throw NSError(
            domain: "md2pdf.mermaid",
            code: 4,
            userInfo: [NSLocalizedDescriptionKey: "Downloaded Mermaid JavaScript is empty."]
        )
    }
    try fileManager.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
    try javaScript.write(to: cacheURL, options: .atomic)
    return javaScript
}

guard CommandLine.arguments.count == 2 else {
    fail("Usage: md2pdf <input.md>", status: 64)
}

let inputPath = CommandLine.arguments[1]
let currentDirectoryURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let inputURL = URL(fileURLWithPath: inputPath, relativeTo: currentDirectoryURL)
let documentTitle = inputURL.deletingPathExtension().lastPathComponent
let pdfURL = currentDirectoryURL
    .appendingPathComponent(inputURL.deletingPathExtension().lastPathComponent)
    .appendingPathExtension("pdf")
let maskScriptURL = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .appendingPathComponent("mask_pdf_corners.py")
let rowHeaderFilterURL = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .appendingPathComponent("row-header-table.lua")
let cssURL = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .appendingPathComponent("github-markdown-light.css")
let cssPath = cssURL.path
// App to return to after the PDF is saved. Set MD2PDF_RETURN_APP in the editor task
// (e.g. "Visual Studio Code" or "Antigravity IDE"); defaults to VS Code.
let returnAppName: String = {
    let value = ProcessInfo.processInfo.environment["MD2PDF_RETURN_APP"]?
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return value.isEmpty ? "Visual Studio Code" : value
}()
let pythonPath = "/opt/homebrew/Caskroom/miniforge/base/envs/MD2PDF/bin/python"

guard FileManager.default.fileExists(atPath: maskScriptURL.path) else {
    fail("Could not find \(maskScriptURL.path).")
}
guard FileManager.default.fileExists(atPath: cssURL.path) else {
    fail("Could not find \(cssURL.path).")
}
guard FileManager.default.fileExists(atPath: rowHeaderFilterURL.path) else {
    fail("Could not find \(rowHeaderFilterURL.path).")
}

let originalPDFFingerprint: FileFingerprint?
do {
    originalPDFFingerprint = try fileFingerprint(at: pdfURL)
} catch {
    fail("Could not inspect \(pdfURL.path): \(error.localizedDescription)")
}

let pandoc = Process()
let pandocOutput = Pipe()
pandoc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
pandoc.arguments = [
    "pandoc",
    "-f", "markdown",
    "-t", "html",
    "--standalone",
    "--embed-resources",
    "--katex",
    "-c", cssPath,
    "--lua-filter=\(rowHeaderFilterURL.path)",
    "--resource-path", ".",
    "--metadata", "title=",
    "-V", "body-class=markdown-body",
    "--quiet",
    inputPath,
    "-o", "-"
]
pandoc.standardOutput = pandocOutput
pandoc.standardError = FileHandle.standardError

let htmlData: Data
do {
    try pandoc.run()
    htmlData = pandocOutput.fileHandleForReading.readDataToEndOfFile()
    pandoc.waitUntilExit()
} catch {
    fail("Failed to launch Pandoc: \(error.localizedDescription)")
}

guard pandoc.terminationStatus == 0 else {
    fail("Pandoc failed with exit code \(pandoc.terminationStatus).")
}

guard var html = String(data: htmlData, encoding: .utf8),
      let titleStart = html.range(of: "<title>", options: .caseInsensitive),
      let titleEnd = html.range(
        of: "</title>",
        options: .caseInsensitive,
        range: titleStart.upperBound..<html.endIndex
      ) else {
    fail("Pandoc output did not contain a valid HTML title.")
}
let escapedTitle = documentTitle
    .replacingOccurrences(of: "&", with: "&amp;")
    .replacingOccurrences(of: "<", with: "&lt;")
    .replacingOccurrences(of: ">", with: "&gt;")
    .replacingOccurrences(of: "\"", with: "&quot;")
    .replacingOccurrences(of: "'", with: "&#39;")
html.replaceSubrange(titleStart.upperBound..<titleEnd.lowerBound, with: escapedTitle)
guard !html.contains("id=\"title-block-header\""),
      !html.contains("id='title-block-header'") else {
    fail("Pandoc unexpectedly generated a visible title block.")
}
if html.contains("class=\"math") || html.contains("class='math") {
    guard let firstScript = html.range(of: "<script", options: .caseInsensitive) else {
        fail("Pandoc output did not contain a script element for math rendering.")
    }
    html.insert(
        contentsOf: """
        <script>
        document.addEventListener('DOMContentLoaded', function () {
            document.querySelectorAll('.math').forEach(function (element) {
                var source = element.textContent;
                element.textContent = source.replace(/\\d{12,}/g, function (number) {
                    return number.replace(/(\\d{8})(?=\\d)/g, '$1\\\\allowbreak ');
                });
            });
        });
        </script>
        
        """,
        at: firstScript.lowerBound
    )
}
let mermaidJavaScript: Data?
if html.contains("class=\"mermaid\"") || html.contains("class='mermaid'") {
    do {
        mermaidJavaScript = try loadMermaidJavaScript()
    } catch {
        fail("Could not load Mermaid renderer: \(error.localizedDescription)")
    }

    guard let bodyEnd = html.range(of: "</body>", options: .caseInsensitive) else {
        fail("Pandoc output did not contain a valid HTML body.")
    }
    html.insert(
        contentsOf: """
        <script src="/mermaid.min.js"></script>
        <script>
        document.querySelectorAll('pre.mermaid').forEach(function (element) {
            var code = element.querySelector('code');
            if (code) element.textContent = code.textContent.trim();
        });
        mermaid.initialize({ startOnLoad: false, theme: 'default' });
        mermaid.run({ querySelector: 'pre.mermaid' }).catch(function (error) {
            console.error('Mermaid rendering failed:', error);
        });
        </script>
        
        """,
        at: bodyEnd.lowerBound
    )
} else {
    mermaidJavaScript = nil
}
guard let servedHTML = html.data(using: .utf8) else {
    fail("Could not encode the generated HTML.")
}

let htmlServer: InMemoryHTMLServer
let htmlURL: URL
do {
    htmlServer = try InMemoryHTMLServer(
        html: servedHTML,
        mermaidJavaScript: mermaidJavaScript
    )
    htmlURL = try htmlServer.start()
} catch {
    fail("Failed to start the in-memory HTML server: \(error.localizedDescription)")
}

let openSafari = Process()
openSafari.executableURL = URL(fileURLWithPath: "/usr/bin/open")
openSafari.arguments = ["-a", "Safari", htmlURL.absoluteString]

do {
    try openSafari.run()
    openSafari.waitUntilExit()
} catch {
    fail("Failed to open Safari: \(error.localizedDescription)")
}

guard openSafari.terminationStatus == 0 else {
    fail("Safari could not open \(htmlURL.path).")
}

print("Served the generated HTML from memory and opened it in Safari: \(htmlURL.absoluteString)")
print("Print from Safari and save the PDF to: \(pdfURL.path)")
print("Waiting for the PDF to be saved and finish writing...")

let pdfWaitTimeout: TimeInterval = 2 * 60
let pdfWaitStart = Date()
var previousFingerprint: FileFingerprint?
var stableChecks = 0
var isNewOrUpdatedPDF = false

while true {
    if Date().timeIntervalSince(pdfWaitStart) >= pdfWaitTimeout {
        fail("Timed out waiting for the PDF after 2 minutes. Expected path: \(pdfURL.path)")
    }

    do {
        if let fingerprint = try fileFingerprint(at: pdfURL) {
            if originalPDFFingerprint != fingerprint {
                isNewOrUpdatedPDF = true
            }

            if isNewOrUpdatedPDF && fingerprint == previousFingerprint {
                stableChecks += 1
            } else {
                stableChecks = 0
            }
            previousFingerprint = fingerprint

            if stableChecks >= 2 {
                let header = try Data(contentsOf: pdfURL, options: .mappedIfSafe).prefix(5)
                guard header == Data("%PDF-".utf8) else {
                    fail("The saved file is not a valid PDF: \(pdfURL.path)")
                }
                htmlServer.stop()
                break
            }
        } else {
            previousFingerprint = nil
            stableChecks = 0
        }
    } catch {
        fail("Error while waiting for \(pdfURL.path): \(error.localizedDescription)")
    }
    Thread.sleep(forTimeInterval: 0.1)
}

let safariCleanupScript = """
on run argv
    set targetURL to item 1 of argv
    set closedCount to 0
    tell application id "com.apple.Safari"
        repeat with safariWindow in windows
            set matchingTabs to (tabs of safariWindow whose URL is targetURL)
            repeat with safariTab in matchingTabs
                close safariTab
                set closedCount to closedCount + 1
            end repeat
        end repeat
    end tell
    return closedCount
end run
"""

let closeSafariTab = Process()
closeSafariTab.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
closeSafariTab.arguments = ["-e", safariCleanupScript, htmlURL.absoluteString]
let automationOutput = Pipe()
closeSafariTab.standardOutput = automationOutput
closeSafariTab.standardError = FileHandle.standardError

do {
    try closeSafariTab.run()
    closeSafariTab.waitUntilExit()
} catch {
    fail("Failed to close the Safari tab and return to VS Code: \(error.localizedDescription)")
}

guard closeSafariTab.terminationStatus == 0 else {
    fail("Safari/VS Code automation failed with exit code \(closeSafariTab.terminationStatus).")
}

let closedTabCount = String(
    data: automationOutput.fileHandleForReading.readDataToEndOfFile(),
    encoding: .utf8
)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "0"
if closedTabCount == "0" {
    print("No matching Safari tab was found.")
} else {
    print("Closed the generated Safari tab.")
}

let returnToMarkdown = Process()
returnToMarkdown.executableURL = URL(fileURLWithPath: "/usr/bin/open")
returnToMarkdown.arguments = ["-a", returnAppName, inputURL.standardizedFileURL.path]

do {
    try returnToMarkdown.run()
    returnToMarkdown.waitUntilExit()
} catch {
    fail("Failed to return to the Markdown file in \(returnAppName): \(error.localizedDescription)")
}

guard returnToMarkdown.terminationStatus == 0 else {
    fail("\(returnAppName) could not open \(inputURL.path).")
}

print("Returned to the \(returnAppName) window for \(inputURL.lastPathComponent).")
print("PDF saved. Applying corner masking in place...")
let maskPDF = Process()
maskPDF.executableURL = URL(fileURLWithPath: pythonPath)
maskPDF.arguments = [maskScriptURL.path, pdfURL.path]
maskPDF.standardOutput = FileHandle.standardOutput
maskPDF.standardError = FileHandle.standardError

do {
    try maskPDF.run()
    maskPDF.waitUntilExit()
} catch {
    fail("Failed to launch the PDF masking script: \(error.localizedDescription)")
}

guard maskPDF.terminationStatus == 0 else {
    fail("PDF masking failed with exit code \(maskPDF.terminationStatus).")
}

print("Finished processing \(pdfURL.path).")
