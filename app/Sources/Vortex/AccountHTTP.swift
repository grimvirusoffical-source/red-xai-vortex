import Foundation

final class AccountHTTP: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    static let delegate = AccountHTTP()
    static let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}
