//
//  FlutterWebViewController.swift
//  flutter_inappwebview
//
//  Created by Lorenzo on 13/11/18.
//

import Foundation
import WebKit
import FlutterMacOS

public class FlutterWebViewController: NSObject, /*FlutterPlatformView,*/ Disposable {
    
    var myView: NSView?
    var keepAliveId: String?
    private var embeddedWebView: InAppWebView?
    private var didDisposeEmbeddedWebView = false

    init(plugin: InAppWebViewFlutterPlugin, withFrame frame: CGRect, viewIdentifier viewId: Any, params: NSDictionary) {
        super.init()
        
        myView = NSView(frame: frame)
        
        keepAliveId = params["keepAliveId"] as? String
        
        let initialSettings = params["initialSettings"] as! [String: Any?]
        let windowId = params["windowId"] as? Int64
        let initialUserScripts = params["initialUserScripts"] as? [[String: Any]]
        
        var userScripts: [UserScript] = []
        if let initialUserScripts = initialUserScripts {
            for initialUserScript in initialUserScripts {
                userScripts.append(UserScript.fromMap(map: initialUserScript, windowId: windowId)!)
            }
        }
        
        let settings = InAppWebViewSettings()
        let _ = settings.parse(settings: initialSettings)
        let preWebviewConfiguration = InAppWebView.preWKWebViewConfiguration(settings: settings)
        
        var webView: InAppWebView?
        
        if let wId = windowId, let webViewTransport = plugin.inAppWebViewManager?.windowWebViews[wId] {
            webView = webViewTransport.webView
            webView!.id = viewId
            webView!.plugin = plugin
            let channel = FlutterMethodChannel(name: InAppWebView.METHOD_CHANNEL_NAME_PREFIX + String(describing: viewId),
                                               binaryMessenger: plugin.registrar.messenger)
            webView!.channelDelegate = WebViewChannelDelegate(webView: webView!, channel: channel)
            webView!.frame = myView!.bounds
            webView!.initialUserScripts = userScripts
        } else {
            webView = InAppWebView(id: viewId,
                                   plugin: plugin,
                                   frame: myView!.bounds,
                                   configuration: preWebviewConfiguration,
                                   userScripts: userScripts)
        }

        let findInteractionController = FindInteractionController(
            plugin: plugin,
            id: viewId, webView: webView!, settings: nil)
        webView!.findInteractionController = findInteractionController
        findInteractionController.prepare()
        
        webView!.autoresizingMask = [.width, .height]
        myView!.autoresizesSubviews = true
        myView!.autoresizingMask = [.width, .height]
        myView!.addSubview(webView!)

        webView!.settings = settings
        webView!.prepare()
        webView!.windowCreated = true
        embeddedWebView = webView
    }
    
    public func webView() -> InAppWebView? {
        if let embedded = embeddedWebView {
            return embedded
        }
        for subview in myView?.subviews ?? []
        {
            if let item = subview as? InAppWebView
            {
                return item
            }
        }
        return nil
    }
    
    public func view() -> NSView {
        return myView!
    }
    
    public func makeInitialLoad(params: NSDictionary) {
        guard let webView = webView() else {
            return
        }
        
        let windowId = params["windowId"] as? Int64
        let initialUrlRequest = params["initialUrlRequest"] as? [String: Any?]
        let initialFile = params["initialFile"] as? String
        let initialData = params["initialData"] as? [String: String?]
        
        if windowId == nil {
            if #available(macOS 10.13, *) {
                webView.configuration.userContentController.removeAllContentRuleLists()
                if let contentBlockers = webView.settings?.contentBlockers, contentBlockers.count > 0 {
                    do {
                        let jsonData = try JSONSerialization.data(withJSONObject: contentBlockers, options: [])
                        let blockRules = String(data: jsonData, encoding: .utf8)
                        WKContentRuleListStore.default().compileContentRuleList(
                            forIdentifier: "ContentBlockingRules",
                            encodedContentRuleList: blockRules) { (contentRuleList, error) in

                                if let error = error {
                                    print(error.localizedDescription)
                                    return
                                }

                                let configuration = webView.configuration
                                configuration.userContentController.add(contentRuleList!)

                                self.load(initialUrlRequest: initialUrlRequest, initialFile: initialFile, initialData: initialData)
                        }
                        return
                    } catch {
                        print(error.localizedDescription)
                    }
                }
            }
            load(initialUrlRequest: initialUrlRequest, initialFile: initialFile, initialData: initialData)
        }
        else if let wId = windowId {
            webView.runWindowBeforeCreatedCallbacks()
        }
    }
    
    func load(initialUrlRequest: [String:Any?]?, initialFile: String?, initialData: [String: String?]?) {
        guard let webView = webView() else {
            return
        }
        
        if let initialFile = initialFile {
            do {
                try webView.loadFile(assetFilePath: initialFile)
            }
            catch let error as NSError {
                dump(error)
            }
        }
        else if let initialData = initialData, let data = initialData["data"]!,
                let mimeType = initialData["mimeType"]!, let encoding = initialData["encoding"]!,
                let baseUrl = URL(string: initialData["baseUrl"]! ?? "about:blank") {
            var allowingReadAccessToURL: URL? = nil
            if let allowingReadAccessTo = webView.settings?.allowingReadAccessTo, baseUrl.scheme == "file" {
                allowingReadAccessToURL = URL(string: allowingReadAccessTo)
                if allowingReadAccessToURL?.scheme != "file" {
                    allowingReadAccessToURL = nil
                }
            }
            webView.loadData(data: data,
                             mimeType: mimeType,
                             encoding: encoding,
                             baseUrl: baseUrl,
                             allowingReadAccessTo: allowingReadAccessToURL)
        }
        else if let initialUrlRequest = initialUrlRequest {
            let urlRequest = URLRequest.init(fromPluginMap: initialUrlRequest)
            var allowingReadAccessToURL: URL? = nil
            if let allowingReadAccessTo = webView.settings?.allowingReadAccessTo, let url = urlRequest.url, url.scheme == "file" {
                allowingReadAccessToURL = URL(string: allowingReadAccessTo)
                if allowingReadAccessToURL?.scheme != "file" {
                    allowingReadAccessToURL = nil
                }
            }
            webView.loadUrl(urlRequest: urlRequest, allowingReadAccessTo: allowingReadAccessToURL)
        }
    }
    
    // method added to fix:
    // https://github.com/pichillilorenzo/flutter_inappwebview/issues/1837
    public func dispose(removeFromSuperview: Bool) {
        if keepAliveId != nil {
            return
        }
        guard !didDisposeEmbeddedWebView else {
            if removeFromSuperview {
                myView?.removeFromSuperview()
            }
            myView = nil
            return
        }
        didDisposeEmbeddedWebView = true
        var webView = embeddedWebView
        if webView == nil {
            for subview in myView?.subviews ?? [] {
                if let w = subview as? InAppWebView {
                    webView = w
                    break
                }
            }
        }
        embeddedWebView = nil
        if let webView = webView {
            Self.tearDownEmbeddedWebViewSynchronously(webView as WKWebView)
        }
        if removeFromSuperview {
            myView?.removeFromSuperview()
        }
        myView = nil
    }
    
    public func dispose() {
        dispose(removeFromSuperview: false)
    }

    private func disposeDeferredAfterDeinit() {
        if keepAliveId != nil {
            return
        }
        guard !didDisposeEmbeddedWebView else {
            myView = nil
            return
        }
        didDisposeEmbeddedWebView = true
        var webView = embeddedWebView
        if webView == nil {
            for subview in myView?.subviews ?? [] {
                if let w = subview as? InAppWebView {
                    webView = w
                    break
                }
            }
        }
        embeddedWebView = nil
        myView = nil
        guard let webView = webView else { return }
        let wkOnly: WKWebView = webView
        DispatchQueue.main.async {
            Self.tearDownEmbeddedWebViewSynchronously(wkOnly)
        }
    }

    private static let fullDisposeSelector = NSSelectorFromString("iaw_fullDisposeFromController")

    private static func tearDownEmbeddedWebViewSynchronously(_ wk: WKWebView) {
        wk.stopLoading()
        wk.navigationDelegate = nil
        wk.uiDelegate = nil
        wk.removeFromSuperview()
        guard wk.responds(to: fullDisposeSelector) else { return }
        (wk as NSObject).performSelector(onMainThread: fullDisposeSelector, with: nil, waitUntilDone: true)
    }
    
    deinit {
        debugPrint("FlutterWebViewController - dealloc")
        disposeDeferredAfterDeinit()
    }
}
