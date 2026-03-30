import Cocoa
import WebKit

class PDFConverter: NSObject, WKNavigationDelegate {
    let sourceURL: URL
    let destURL: URL
    var webView: WKWebView!
    var window: NSWindow!
    let startTime = CFAbsoluteTimeGetCurrent()
    
    let marginTop: String
    let marginBottom: String
    let marginLeft: String
    let marginRight: String

    init(sourcePath: String, destPath: String, top: String, bottom: String, left: String, right: String) {
        self.sourceURL = URL(fileURLWithPath: sourcePath)
        self.destURL = URL(fileURLWithPath: destPath)
        self.marginTop = top
        self.marginBottom = bottom
        self.marginLeft = left
        self.marginRight = right
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
        
        let jsString = """
            var style = document.createElement('style');
            style.innerHTML = `@page { 
                margin-top: \(marginTop)cm !important; 
                margin-bottom: \(marginBottom)cm !important; 
                margin-left: \(marginLeft)cm !important; 
                margin-right: \(marginRight)cm !important; 
            }`;
            document.head.appendChild(style);
        """
        
        let script = WKUserScript(source: jsString, injectionTime: .atDocumentEnd, forMainFrameOnly: true)
        config.userContentController.addUserScript(script)
        
        webView = WKWebView(frame: rect, configuration: config)
        webView.navigationDelegate = self
        window.contentView = webView
        
        let parentDir = sourceURL.deletingLastPathComponent()
        print("[Load] Loading HTML file: \(sourceURL.path)")
        webView.loadFileURL(sourceURL, allowingReadAccessTo: parentDir)
        
        app.run()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        print("[Render] HTML loaded. Waiting for layout reflow...")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
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
            print(String(format: "[Done] PDF generated successfully in %.2f ms.", duration))
            exit(0)
        } else {
            print("[Error] Print operation failed.")
            exit(1)
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
}

let args = CommandLine.arguments

var inputPath: String?
var outputPath: String?

var mTop = "2"
var mBottom = "2"
var mLeft = "2"
var mRight = "2"

var i = 1
while i < args.count {
    let arg = args[i]
    
    switch arg {
    case "--margin-top":
        if i + 1 < args.count { mTop = args[i + 1]; i += 1 }
    case "--margin-bottom":
        if i + 1 < args.count { mBottom = args[i + 1]; i += 1 }
    case "--margin-left":
        if i + 1 < args.count { mLeft = args[i + 1]; i += 1 }
    case "--margin-right":
        if i + 1 < args.count { mRight = args[i + 1]; i += 1 }
    default:
        if !arg.hasPrefix("--") {
            if inputPath == nil {
                inputPath = arg
            } else if outputPath == nil {
                outputPath = arg
            }
        }
    }
    i += 1
}

guard let input = inputPath, let output = outputPath else {
    print("Usage: md2pdf_native <input.html> <output.pdf> [--margin-top <val>] [--margin-bottom <val>] [--margin-left <val>] [--margin-right <val>]")
    print("Example: md2pdf_native in.html out.pdf --margin-top 2.5 --margin-left 3")
    exit(1)
}

let converter = PDFConverter(sourcePath: input, destPath: output, top: mTop, bottom: mBottom, left: mLeft, right: mRight)
converter.run()