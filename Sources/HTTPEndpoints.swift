// HTTPEndpoints.swift
//
// Copyright (c) 2015 - 2016, Justin Pawela & The LogKit Project
// http://www.logkit.info/
//
// Permission to use, copy, modify, and/or distribute this software for any
// purpose with or without fee is hereby granted, provided that the above
// copyright notice and this permission notice appear in all copies.
//
// THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
// WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
// MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
// ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
// WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
// ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
// OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.

import Foundation


/// A default selection of HTTP status codes that will be interpreted as a successful upload.
public let defaultSuccessCodes = Set([200, 201, 202, 204])


//MARK: Persisted Cache

/// This utility class holds data until the Endpoint is ready to upload it.
///
/// The data is also persisted to a file, in case the upload does not succeed while the application is running.
/// We always read the file on startup to see if there are any left-over uploads to complete.
///
/// - note: If the file cannot be opened, the cache will still function in memory, but will obviously not persist
///         data once it's evicted from memory.
class LXPersistedCache {
    private let lock: DispatchQueue = DispatchQueue(label: "persistedCacheQueue")
    private let file: FileHandle?
    private var cache: [UInt: NSData]
    private var reserved: [UInt: TimeInterval] = [:]
    private let timeoutInterval: TimeInterval
    private var currentMaxID: UInt

    /// Initialize a persistent cache instance.
    ///
    /// - parameter timeoutInterval: The amount of time data will remain reserved before assuming the upload failed,
    ///                              and allowing the data to be tried again.
    /// - parameter fileName:        The cache file's name. This file will be created in the directory indicated
    ///                              by `LK_DEFAULT_LOG_DIRECTORY`.
    init(timeoutInterval: TimeInterval, fileName: String) {
        self.timeoutInterval = timeoutInterval
        if let fileURL = LK_DEFAULT_LOG_DIRECTORY?.appendingPathComponent(fileName, isDirectory: false) {
            do { //TODO: This is a mess.
                try FileManager.default.ensureFile(at: fileURL as NSURL)
                self.file = try? FileHandle(forUpdating: fileURL)
            } catch { self.file = nil }
        } else {
            self.file = nil
        }
        self.file?.seek(toFileOffset: 0) // Do we need to do this?
        self.cache = [:]
        let encoded = self.file?.readDataToEndOfFile() ?? NSData() as Data
        if let decoded = NSString(data: encoded, encoding: String.Encoding.utf8.rawValue) as String? {
            for lines in decoded.components(separatedBy: "\n") {
                let line = lines.components(separatedBy: " ")
                if line.count == 2, let id = UInt(line[0]), let data = NSData(base64Encoded: line[1], options: []) {
                    self.cache[id] = data
                } //TODO: error handling - corrupted file?
            }
        }
        self.currentMaxID = self.cache.keys.max() ?? 0
        assert(self.file != nil, "HTTP Cache could not open cache file.")
    }

    /// Clean up
    deinit {
        self.lock.sync {
            self.file?.synchronizeFile()
            self.file?.closeFile()
        }
    }

    /// Add data to the cache; the data can be retrieved for upload later.
    func addData(data: NSData) {
        self.lock.async {
            self.currentMaxID += 1
            self.cache[self.currentMaxID] = data

            self.file?.seekToEndOfFile() // Do we need to do this?
            guard let outData = self.dataString(data: data, withID: self.currentMaxID).data(using: String.Encoding.utf8) else {
                assertionFailure("Failure to encode data for temporary storage")
                return
            }
            self.file?.write(outData)
        }
    }

    /// Reserve data for upload. Once data has been reserved, it will not be reserved again until its reservation ends.
    ///
    /// Users should track each ID number associated with the data they reserve. Once an upload succeeds, the user
    /// should call `completeProgressOnIDs(:)` with each of the ID numbers of the data that successfully uploaded, so
    /// that the cache can discard that data. If an upload fails, user should call `cancelProgressOnIDs(:)` with the
    /// relevant IDs, so that the cache can allow that data to be reserved again.
    ///
    /// If the cache does not recieve either signal by the end of the reservation interval, it will automatically make
    /// the data available for reservation again.
    ///
    /// - returns: A dictionary of ID numbers and data.
    func reserveData() -> [UInt: NSData] {
        var toReserve: [UInt: NSData]?
        self.lock.sync {
            let now = CFAbsoluteTimeGetCurrent()
            toReserve = self.cache
            let ignored = self.reserved.filter({ _, expiry in now < expiry }).map({ id, _ in id })
            for id in ignored { toReserve!.removeValue(forKey: id) }
            let expires = now + self.timeoutInterval
            for id in toReserve!.keys { self.reserved[id] = expires }
        }
        return toReserve!
    }

    /// Call this method when data has been successfully uploaded. The cache will discard this data.
    func completeProgressOnIDs(ids: [UInt]) {
        self.lock.async {
            for id in ids {
                self.cache.removeValue(forKey: id)
                self.reserved.removeValue(forKey: id)
            }

            self.file?.truncateFile(atOffset: 0)
            if self.cache.isEmpty {
                self.currentMaxID = 0
            } else {
                let output = self.cache.map({ id, data in self.dataString(data: data, withID: id) }).joined(separator: "")
                if let fileData = output.data(using: String.Encoding.utf8) {
                    self.file?.write(fileData)
                } else {
                    //TODO: what do we really want to do if encoding fails?
                    assertionFailure("Failure to encode data for temporary storage")
                }
            }
        }
    }

    /// Call this method when data has failed to upload. The cache will end the data's reservation and allow a
    /// subsequent attempt to upload the data again.
    func cancelProgressOnIDs(ids: [UInt]) {
        self.lock.async {
            for id in ids {
                self.reserved.removeValue(forKey: id)
            }
        }
    }

    /// Formats the data for persistent storage.
    private func dataString(data: NSData, withID id: UInt) -> String {
        return "\(id) \(data.base64EncodedString(options: []))\n"
    }

}


//MARK: HTTP Endpoint

/// An Endpoint that uploads Log Entries to an HTTP service in plaintext format.
///
/// Upload and retry management are handled automatically by this Endpoint. It attempts to upload Log Entries in order,
/// but makes no guarantees.
public class LXHTTPEndpoint: LXEndpoint {
    /// The minimum Priority Level a Log Entry must meet to be accepted by this Endpoint.
    public var minimumPriorityLevel: LXPriorityLevel
    /// The formatter used by this Endpoint to serialize a Log Entry’s `dateTime` property to a string.
    public var dateFormatter: LXDateFormatter
    /// The formatter used by this Endpoint to serialize each Log Entry to a string.
    public var entryFormatter: LXEntryFormatter
    /// This Endpoint does not require a newline character appended to each serialized Log Entry string.
    public let requiresNewlines: Bool = false

    private let successCodes: Set<Int>
    private let session: URLSession
    private let request: NSURLRequest

    var cacheName: String { return ".http_endpoint_cache.txt" }
    private lazy var cache: LXPersistedCache = LXPersistedCache(timeoutInterval: 50, fileName: self.cacheName)
    private lazy var timer: Timer = { [unowned self] in
        let timer = Timer.scheduledTimer(timeInterval: 60, target: self, selector: #selector(upload(timer:)), userInfo: nil, repeats: true)
        timer.tolerance = 10
        return timer
    }()

    /// Initialize an HTTP Endpoint.
    ///
    /// - parameter              request: The request that will be used when submitting uploads.
    /// - parameter         successCodes: The set of HTTP status codes the server might respond with to indicate a
    ///                                   successful upload. Defaults to `{200, 201, 202, 204}`.
    /// - parameter sessionConfiguration: The configuration to be used when initializating this Endpoint's URL session.
    ///                                   Defaults to `.defaultSessionConfiguration()`.
    /// - parameter minimumPriorityLevel: The minimum Priority Level a Log Entry must meet to be accepted by this
    ///                                   Endpoint. Defaults to `.All`.
    /// - parameter        dateFormatter: The formatter used by this Endpoint to serialize a Log Entry’s `dateTime`
    ///                                   property to a string. Defaults to `.standardFormatter()`.
    /// - parameter       entryFormatter: The formatter used by this Endpoint to serialize each Log Entry to a string.
    ///                                   Defaults to `.standardFormatter()`.
    public init(
        request: NSURLRequest,
        successCodes: Set<Int> = defaultSuccessCodes,
        sessionConfiguration: URLSessionConfiguration = URLSessionConfiguration.default,
        minimumPriorityLevel: LXPriorityLevel = .All,
        dateFormatter: LXDateFormatter = LXDateFormatter.standardFormatter(),
        entryFormatter: LXEntryFormatter = LXEntryFormatter.standardFormatter()
    ) {
        self.minimumPriorityLevel = minimumPriorityLevel
        self.dateFormatter = dateFormatter
        self.entryFormatter = entryFormatter

        self.successCodes = successCodes
        self.session = URLSession(configuration: sessionConfiguration)
        self.request = request

        self.timer.fire()
    }
    
    public init (url: NSURL) {
        let request = NSMutableURLRequest(url: url as URL)
        let successCodes: Set<Int> = defaultSuccessCodes
        let sessionConfiguration: URLSessionConfiguration = URLSessionConfiguration.default
        let minimumPriorityLevel: LXPriorityLevel = .All
        let dateFormatter: LXDateFormatter = LXDateFormatter.standardFormatter()
        let entryFormatter: LXEntryFormatter = LXEntryFormatter.standardFormatter()

        self.minimumPriorityLevel = minimumPriorityLevel
        self.dateFormatter = dateFormatter
        self.entryFormatter = entryFormatter
        
        self.successCodes = successCodes
        self.session = URLSession(configuration: sessionConfiguration)
        self.request = request
        
        self.timer.fire()

     }


    /// Initialize an HTTP Endpoint.
    ///
    /// - parameter                  URL: The URL to upload Log Entries to.
    /// - parameter           HTTPMethod: The HTTP request method to be used when uploading Log Entries.
    /// - parameter         successCodes: The set of HTTP status codes the server might respond with to indicate a
    ///                                   successful upload. Defaults to `{200, 201, 202, 204}`.
    /// - parameter sessionConfiguration: The configuration to be used when initializating this Endpoint's URL session.
    ///                                   Defaults to `.defaultSessionConfiguration()`.
    /// - parameter minimumPriorityLevel: The minimum Priority Level a Log Entry must meet to be accepted by this
    ///                                   Endpoint. Defaults to `.All`.
    /// - parameter        dateFormatter: The formatter used by this Endpoint to serialize a Log Entry’s `dateTime`
    ///                                   property to a string. Defaults to `.standardFormatter()`.
    /// - parameter       entryFormatter: The formatter used by this Endpoint to serialize each Log Entry to a string.
    ///                                   Defaults to `.standardFormatter()`.
    public convenience init(
        URL: NSURL,
        HTTPMethod: String,
        successCodes: Set<Int> = defaultSuccessCodes,
        sessionConfiguration: URLSessionConfiguration = URLSessionConfiguration.default,
        minimumPriorityLevel: LXPriorityLevel = .All,
        dateFormatter: LXDateFormatter = LXDateFormatter.standardFormatter(),
        entryFormatter: LXEntryFormatter = LXEntryFormatter.standardFormatter()
    ) {
        let request = NSMutableURLRequest(url: URL as URL)
        request.httpMethod = HTTPMethod
        request.setValue("text/plain", forHTTPHeaderField: "Content-Type")
        self.init(
            request: request,
            successCodes: successCodes,
            sessionConfiguration: sessionConfiguration,
            minimumPriorityLevel: minimumPriorityLevel,
            dateFormatter: dateFormatter,
            entryFormatter: entryFormatter
        )
    }

    /// Clean up
    deinit {
        self.timer.fire()
        self.timer.invalidate()
        self.session.finishTasksAndInvalidate()
    }

    /// Submits a serialized Log Entry string for uploading.
    public func write(string: String) {
        guard let data = string.data(using: String.Encoding.utf8) else {
            assertionFailure("Failure to create data from entry string")
            return
        }
        self.cache.addData(data: data as NSData)
        self.timer.fire() // or should we just wait for the next timer firing?
    }

    /// Attempts to upload all available pending data.
    @objc private func upload(timer: Timer?) {
        LK_LOGKIT_QUEUE.async {
            let pendingUploads = self.cache.reserveData()
            for (id, data) in pendingUploads {
                let task = self.session.uploadTask(with: self.request as URLRequest, from: data as Data, completionHandler: { _, response, _ in
                    if self.successCodes.contains((response as? HTTPURLResponse)?.statusCode ?? -1) {
                        self.cache.completeProgressOnIDs(ids: [id]) //TODO: more efficient releasing
                    } else {
                        self.cache.cancelProgressOnIDs(ids: [id])
                    }
                })
                task.resume()
            }
        }
    }

    public func getLogs() -> Data {
        return NSData() as Data
    }
    
    public func markingSent() -> Void {
        return
    }
}


//MARK: HTTP JSON Endpoint

/// An Endpoint that uploads Log Entries to an HTTP service in JSON format.
///
/// Upload and retry management are handled automatically by this Endpoint. It attempts to upload Log Entries in order,
/// but makes no guarantees.
public class LXHTTPJSONEndpoint: LXHTTPEndpoint {

    override var cacheName: String { return ".json_endpoint_cache.txt" }

    /// Initialize an HTTP JSON Endpoint. Log Entries will be converted to JSON automatically.
    ///
    /// - parameter              request: The request that will be used when submitting uploads.
    /// - parameter         successCodes: The set of HTTP status codes the server might respond with to indicate a
    ///                                   successful upload. Defaults to `{200, 201, 202, 204}`.
    /// - parameter sessionConfiguration: The configuration to be used when initializating this Endpoint's URL session.
    ///                                   Defaults to `.defaultSessionConfiguration()`.
    /// - parameter minimumPriorityLevel: The minimum Priority Level a Log Entry must meet to be accepted by this
    ///                                   Endpoint. Defaults to `.All`.
    /// - parameter        dateFormatter: The formatter used by this Endpoint to serialize a Log Entry’s `dateTime`
    ///                                   property to a string. Defaults to `.standardFormatter()`.
    public init(
        request: NSURLRequest,
        successCodes: Set<Int> = defaultSuccessCodes,
        sessionConfiguration: URLSessionConfiguration = URLSessionConfiguration.default,
        minimumPriorityLevel: LXPriorityLevel = .All,
        dateFormatter: LXDateFormatter = LXDateFormatter.ISO8601DateTimeFormatter()
    ) {
        super.init(
            request: request,
            successCodes: successCodes,
            sessionConfiguration: sessionConfiguration,
            minimumPriorityLevel: minimumPriorityLevel,
            dateFormatter: dateFormatter,
            entryFormatter: LXEntryFormatter.jsonFormatter()
        )
    }

    /// Initialize an HTTP JSON Endpoint. Log Entries will be converted to JSON automatically.
    ///
    /// - parameter                  URL: The URL to upload Log Entries to.
    /// - parameter           HTTPMethod: The HTTP request method to be used when uploading Log Entries.
    /// - parameter         successCodes: The set of HTTP status codes the server might respond with to indicate a
    ///                                   successful upload. Defaults to `{200, 201, 202, 204}`.
    /// - parameter sessionConfiguration: The configuration to be used when initializating this Endpoint's URL session.
    ///                                   Defaults to `.defaultSessionConfiguration()`.
    /// - parameter minimumPriorityLevel: The minimum Priority Level a Log Entry must meet to be accepted by this
    ///                                   Endpoint. Defaults to `.All`.
    /// - parameter        dateFormatter: The formatter used by this Endpoint to serialize a Log Entry’s `dateTime`
    ///                                   property to a string. Defaults to `.standardFormatter()`.
    public convenience init(
        URL: NSURL,
        HTTPMethod: String,
        successCodes: Set<Int> = defaultSuccessCodes,
        sessionConfiguration: URLSessionConfiguration = URLSessionConfiguration.default,
        minimumPriorityLevel: LXPriorityLevel = .All,
        dateFormatter: LXDateFormatter = LXDateFormatter.ISO8601DateTimeFormatter()
    ) {
        let request = NSMutableURLRequest(url: URL as URL)
        request.httpMethod = HTTPMethod
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        self.init(
            request: request,
            successCodes: successCodes,
            sessionConfiguration: sessionConfiguration,
            minimumPriorityLevel: minimumPriorityLevel,
            dateFormatter: dateFormatter
        )
    }

}
