/**
 * Copyright 2019 - 2022 Ayogo Health Inc.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     https://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

#if canImport(Cordova)
import Cordova
#endif

import os.log
import Foundation
import AuthenticationServices
import SafariServices

extension NSNotification.Name {
    static let CDVPluginOAuthCancelled = NSNotification.Name("CDVPluginOAuthCancelledNotification");
}

@objc protocol OAuthSessionProvider {
    init(_ endpoint : URL, callbackScheme : String)
    func start() -> Void
    func cancel() -> Void
}

@available(iOS 12.0, *)
class ASWebAuthenticationSessionOAuthSessionProvider : OAuthSessionProvider {
    private var aswas : ASWebAuthenticationSession

    var delegate : AnyObject?

    required init(_ endpoint : URL, callbackScheme : String) {
        let url: URL = URL(string: callbackScheme)!
        let callbackURLScheme: String = url.scheme ?? callbackScheme
        self.aswas = ASWebAuthenticationSession(url: endpoint, callbackURLScheme: callbackURLScheme, completionHandler: { (callBack:URL?, error:Error?) in
            if let incomingUrl = callBack {
                NotificationCenter.default.post(name: NSNotification.Name.CDVPluginHandleOpenURL, object: incomingUrl)
            } else {
                NotificationCenter.default.post(name: NSNotification.Name.CDVPluginOAuthCancelled, object: nil)
            }
        })
    }

    func start() {
        if #available(iOS 13.0, *) {
            if let provider = self.delegate as? ASWebAuthenticationPresentationContextProviding {
                self.aswas.presentationContextProvider = provider
            }
        }

        self.aswas.start()
    }

    func cancel() {
        self.aswas.cancel()
    }
}

@available(iOS 11.0, *)
class SFAuthenticationSessionOAuthSessionProvider : OAuthSessionProvider {
    private var sfas : SFAuthenticationSession

    required init(_ endpoint : URL, callbackScheme : String) {
        self.sfas = SFAuthenticationSession(url: endpoint, callbackURLScheme: callbackScheme, completionHandler: { (callBack:URL?, error:Error?) in
            if let incomingUrl = callBack {
                NotificationCenter.default.post(name: NSNotification.Name.CDVPluginHandleOpenURL, object: incomingUrl)
            } else {
                NotificationCenter.default.post(name: NSNotification.Name.CDVPluginOAuthCancelled, object: nil)
            }
        })
    }

    func start() {
        self.sfas.start()
    }

    func cancel() {
        self.sfas.cancel()
    }
}

@available(iOS 9.0, *)
class SFSafariViewControllerOAuthSessionProvider : OAuthSessionProvider {
    private var sfvc : SFSafariViewController

    var viewController : UIViewController?
    var delegate : SFSafariViewControllerDelegate?

    required init(_ endpoint : URL, callbackScheme : String) {
        self.sfvc = SFSafariViewController(url: endpoint)
        if #available(iOS 11.0, *) {
            self.sfvc.dismissButtonStyle = .cancel
        }
    }

    func start() {
        if self.delegate != nil {
            self.sfvc.delegate = self.delegate
        }

        self.viewController?.present(self.sfvc, animated: true, completion: nil)
    }

    func cancel() {
        self.sfvc.dismiss(animated: true, completion:nil)
    }
}

class SafariAppOAuthSessionProvider : OAuthSessionProvider {
    var url : URL;

    required init(_ endpoint : URL, callbackScheme : String) {
        self.url = endpoint
    }

    func start() {
        UIApplication.shared.openURL(url)
    }

    // We can't do anything here
    func cancel() { }
}


@objc(CDVOAuthPlugin)
class OAuthPlugin : CDVPlugin, SFSafariViewControllerDelegate, ASWebAuthenticationPresentationContextProviding {
    /** This exists for testing purposes */
    static var forcedVersion : UInt32 = UInt32.max

    var authSystem : OAuthSessionProvider?
    var closeCallbackId : String?
    var callbackScheme : String?
    var logger : OSLog?

    override func pluginInitialize() {
        let urlScheme = self.commandDelegate.settings["oauthscheme"] as! String
        let urlHostname = self.commandDelegate.settings["oauthhostname"] as? String ?? "oauth_callback";

        self.callbackScheme = "\(urlScheme)://\(urlHostname)"
        if #available(iOS 10.0, *) {
            self.logger = OSLog(subsystem: urlScheme, category: "Cordova")
        }

        NotificationCenter.default.addObserver(self,
                selector: #selector(OAuthPlugin._handleOpenURL(_:)),
                name: NSNotification.Name.CDVPluginHandleOpenURL,
                object: nil)

        NotificationCenter.default.addObserver(self,
                selector: #selector(OAuthPlugin._handleCancel(_:)),
                name: NSNotification.Name.CDVPluginOAuthCancelled,
                object: nil)
    }


    @objc func startOAuth(_ command : CDVInvokedUrlCommand) {
        guard let authEndpoint = command.argument(at: 0) as? String else {
            self.commandDelegate.send(CDVPluginResult(status: .error), callbackId: command.callbackId)
            return
        }

        guard let url = URL(string: authEndpoint) else {
            self.commandDelegate.send(CDVPluginResult(status: .error), callbackId: command.callbackId)
            return
        }

        self.closeCallbackId = command.callbackId

        if OAuthPlugin.forcedVersion >= 12, #available(iOS 12.0, *) {
            self.authSystem = ASWebAuthenticationSessionOAuthSessionProvider(url, callbackScheme:self.callbackScheme!)

            if #available(iOS 13.0, *) {
                if let aswas = self.authSystem as? ASWebAuthenticationSessionOAuthSessionProvider {
                    aswas.delegate = self
                }
            }
        } else if OAuthPlugin.forcedVersion >= 11, #available(iOS 11.0, *) {
            self.authSystem = SFAuthenticationSessionOAuthSessionProvider(url, callbackScheme:self.callbackScheme!)
        } else if OAuthPlugin.forcedVersion >= 9, #available(iOS 9.0, *) {
            self.authSystem = SFSafariViewControllerOAuthSessionProvider(url, callbackScheme:self.callbackScheme!)

            if let sfvc = self.authSystem as? SFSafariViewControllerOAuthSessionProvider {
                sfvc.delegate = self
                sfvc.viewController = self.viewController
            }
        } else {
            self.authSystem = SafariAppOAuthSessionProvider(url, callbackScheme:self.callbackScheme!)
        }

        self.authSystem?.start()

        return
    }


    internal func parseToken(from url: URL) {
        self.authSystem?.cancel()
        self.authSystem = nil

        var jsobj : [String : String] = ["oauth_callback_url": url.absoluteString]
        let queryItems = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
        let fragment = url.fragment

        // Parse fragment parameters
        if let fragment = fragment {
            let pairs = fragment.split(separator: "&")
            for pair in pairs {
                let keyValue = pair.split(separator: "=")
                if keyValue.count == 2,
                   let key = keyValue[0].removingPercentEncoding,
                   let value = keyValue[1].removingPercentEncoding {
                   jsobj[String(key)] = String(value)
                }
            }
        }

        queryItems?.forEach {
           jsobj[$0.name] = $0.value
        }

        if #available(iOS 10.0, *) {
            os_log("OAuth called back with parameters.", log: self.logger!, type: .info)
        } else {
            NSLog("OAuth called back with parameters.")
        }

        do {
            let data = try JSONSerialization.data(withJSONObject: jsobj)
            let msg = String(data: data, encoding: .utf8)!
                .replacingOccurrences(of: "'", with: "\\'")
                .replacingOccurrences(of: "\n", with: "\\n")
                .replacingOccurrences(of: "\r", with: "\\r")
                .replacingOccurrences(of: "\t", with: "\\t")

            if let msg = String(data: data, encoding: .utf8) {
                self.webViewEngine.evaluateJavaScript("window.dispatchEvent(new MessageEvent('message', { data: 'oauth::\(msg)' }));", completionHandler: nil)
            }
        } catch {
            let errStr = "JSON Serialization failed: \(error)"
            if #available(iOS 10.0, *) {
                os_log("%@", log: self.logger!, type: .error, errStr)
            } else {
                NSLog(errStr)
            }
        }
    }


    @objc internal func _handleOpenURL(_ notification : NSNotification) {
        guard let url = notification.object as? URL else {
            return
        }

        if !url.absoluteString.hasPrefix(self.callbackScheme!) {
            return
        }

        self.parseToken(from: url)

        if let cb = self.closeCallbackId {
            self.commandDelegate.send(CDVPluginResult(status: .ok), callbackId: cb)
        }
        self.closeCallbackId = nil
    }


    @objc internal func _handleCancel(_ notification : NSNotification) {
        if let cb = self.closeCallbackId {
            self.commandDelegate.send(CDVPluginResult(status: .ok), callbackId: cb)
        }
        self.closeCallbackId = nil
    }


    @available(iOS 9.0, *)
    func safariViewControllerDidFinish(_ controller: SFSafariViewController) {
        self.authSystem?.cancel()
        self.authSystem = nil

        NotificationCenter.default.post(name: NSNotification.Name.CDVPluginOAuthCancelled, object: nil)
    }

    @available(iOS 13.0, *)
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        return self.viewController.view.window ?? ASPresentationAnchor()
    }
}
