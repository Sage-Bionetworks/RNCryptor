//
//  RNCryptor.swift
//
//  Copyright © 2015 Rob Napier. All rights reserved.
//
//  This code is licensed under the MIT License:
//
//  Permission is hereby granted, free of charge, to any person obtaining a
//  copy of this software and associated documentation files (the "Software"),
//  to deal in the Software without restriction, including without limitation
//  the rights to use, copy, modify, merge, publish, distribute, sublicense,
//  and/or sell copies of the Software, and to permit persons to whom the
//  Software is furnished to do so, subject to the following conditions:
//
//  The above copyright notice and this permission notice shall be included in
//  all copies or substantial portions of the Software.
//
//  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
//  IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
//  FITNESS FOR A PARTICULAR PURPOSE AND NON-INFRINGEMENT. IN NO EVENT SHALL THE
//  AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
//  LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
//  FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
//  DEALINGS IN THE SOFTWARE.
//

import Foundation
import CommonCrypto

/// The `CryptorType` protocol defines generic API to a mutable, 
/// incremental, password-based encryptor or decryptor. Its generic
/// usage is as follows:
///
///     let cryptor = Encryptor(password: "mypassword")
///     // or Decryptor()
///
///     var result NSMutableData
///     for data in datas {
///         result.appendData(try cryptor.update(data))
///     }
///     result.appendData(try cryptor.final())
///
///  After calling `finalData()`, the cryptor is no longer valid.
public protocol CryptorType {

    /// Creates and returns a cryptor.
    ///
    /// - parameter password: Non-empty password string. This will be interpretted as UTF-8.
    init(password: String)

    /// Updates cryptor with data and returns processed data.
    ///
    /// - parameter data: Data to process. May be empty.
    /// - throws: `RNCryptorError`
    /// - returns: Processed data. May be empty.
    func updateWithData(data: NSData) throws -> NSData

    /// Returns trailing data and invalidates the cryptor.
    ///
    /// - throws: `RNCryptorError`
    /// - returns: Trailing data
    func finalData() throws -> NSData
}

public extension CryptorType {
    /// Simplified, generic interface to `CryptorType`. Takes a data,
    /// returns a processed data. Generally you should use
    /// `Decryptor.decrypt`,
    /// - throws: `RNCryptorError`
    public func oneshot(data: NSData) throws -> NSData {
        let result = NSMutableData(data: try updateWithData(data))
        result.appendData(try finalData())
        return result
    }
}

/// Errors thrown by `CryptorType`
@objc public enum RNCryptorError: Int, ErrorType {
    /// Ciphertext was corrupt or password was incorrect.
    /// It is not possible to distinguish between these cases in the v3 data format.
    case HMACMismatch = 1

    /// Unrecognized data format. Usually this means the data is corrupt.
    case UnknownHeader

    /// `final()` was called before sufficient data was passed to `updateWithData()`
    case MessageTooShort

    /// Memory allocation failure. This should never happen.
    case MemoryFailure

    /// A password-based decryptor was used on a key-based ciphertext, or vice-versa.
    case InvalidCredentialType
}

/// A encryptor for the latest data format. If compatibility with other RNCryptor
/// implementations is required, you may wish to use the specific encryptor version rather
/// than accepting "latest."
@objc(RNEncryptor)
public final class Encryptor: NSObject, CryptorType {
    private let encryptor: EncryptorV3

    /// Creates and returns a cryptor.
    ///
    /// - parameter password: Non-empty password string. This will be interpretted as UTF-8.
    public init(password: String) {
        encryptor = EncryptorV3(password: password)
    }

    /// Updates cryptor with data and returns processed data.
    ///
    /// - parameter data: Data to process. May be empty.
    /// - throws: `RNCryptorError`
    /// - returns: Processed data. May be empty.
    public func updateWithData(data: NSData) -> NSData {
        return encryptor.updateWithData(data)
    }

    /// Returns trailing data and invalidates the cryptor.
    ///
    /// - throws: `RNCryptorError`
    /// - returns: Trailing data
    public func finalData() -> NSData {
        return encryptor.finalData()
    }

    /// Simplified, generic interface to `CryptorType`. Takes a data,
    /// returns a processed data. Generally you should use
    /// `Decryptor.decrypt`,
    /// - throws: `RNCryptorError`
    public func encryptData(data: NSData) -> NSData {
        return encryptor.encryptData(data)
    }
}

@objc(RNCryptor)
public class Cryptor: NSObject {
    public static func encryptData(data: NSData, password: String) -> NSData {
        return Encryptor(password: password).encryptData(data)
    }

    public static func decryptData(data: NSData, password: String) throws -> NSData {
        return try Decryptor(password: password).decryptData(data)
    }
}

protocol PasswordDecryptorType: CryptorType {
    static var preambleSize: Int { get }
    static func canDecrypt(preamble: NSData) -> Bool
    init(password: String)
}

private extension CollectionType {
    func splitPassFail(pred: Generator.Element -> Bool) -> ([Generator.Element], [Generator.Element]) {
        var pass: [Generator.Element] = []
        var fail: [Generator.Element] = []
        for e in self {
            if pred(e) {
                pass.append(e)
            } else {
                fail.append(e)
            }
        }
        return (pass, fail)
    }
}

@objc(RNDecryptor)
public final class Decryptor : NSObject, CryptorType {
    private var decryptors: [PasswordDecryptorType.Type] = [DecryptorV3.self]

    private var buffer = NSMutableData()
    private var decryptor: CryptorType?
    private let password: String

    public init(password: String) {
        assert(password != "")
        self.password = password
    }

    public func decryptData(data: NSData) throws -> NSData {
        return try oneshot(data)
    }

    public func updateWithData(data: NSData) throws -> NSData {
        if let d = decryptor {
            return try d.updateWithData(data)
        }

        buffer.appendData(data)

        let toCheck:[PasswordDecryptorType.Type]
        (toCheck, decryptors) = decryptors.splitPassFail{ self.buffer.length >= $0.preambleSize }

        for decryptorType in toCheck {
            if decryptorType.canDecrypt(buffer.bytesView[0..<decryptorType.preambleSize]) {
                let d = decryptorType.init(password: password)
                decryptor = d
                let result = try d.updateWithData(buffer)
                buffer.length = 0
                return result
            }
        }

        guard !decryptors.isEmpty else { throw RNCryptorError.UnknownHeader }
        return NSData()
    }

    public func finalData() throws -> NSData {
        guard let d = decryptor else {
            throw RNCryptorError.UnknownHeader
        }
        return try d.finalData()
    }
}

private let CCErrorDomain = "com.apple.CommonCrypto"

internal enum CryptorOperation: CCOperation {
    case Encrypt = 0 // CCOperation(kCCEncrypt)
    case Decrypt = 1 // CCOperation(kCCDecrypt)
}

internal final class Engine {
    private let cryptor: CCCryptorRef
    private var buffer = NSMutableData()

    init(operation: CryptorOperation, key: NSData, iv: NSData) {
        var cryptorOut = CCCryptorRef()
        let result = CCCryptorCreate(
            operation.rawValue,
            CCAlgorithm(kCCAlgorithmAES128), CCOptions(kCCOptionPKCS7Padding),
            key.bytes, key.length,
            iv.bytes,
            &cryptorOut
        )
        cryptor = cryptorOut

        // It is a programming error to create us with illegal values
        // This is an internal class, so we can constrain what is sent to us.
        // If this is ever made public, it should throw instead of asserting.
        assert(result == CCCryptorStatus(kCCSuccess))
    }

    deinit {
        if cryptor != CCCryptorRef() {
            CCCryptorRelease(cryptor)
        }
    }

    func sizeBufferForDataOfLength(length: Int) -> Int {
        let size = CCCryptorGetOutputLength(cryptor, length, true)
        buffer.length = size
        return size
    }

    func updateWithData(data: NSData) throws -> NSData {
        let outputLength = sizeBufferForDataOfLength(data.length)
        var dataOutMoved: Int = 0

        var result: CCCryptorStatus = CCCryptorStatus(kCCUnimplemented)

        result = CCCryptorUpdate(
            cryptor,
            data.bytes, data.length,
            buffer.mutableBytes, outputLength,
            &dataOutMoved)

        // The only error returned by CCCryptorUpdate is kCCBufferTooSmall, which would be a programming error
        assert(result == CCCryptorStatus(kCCSuccess))

        buffer.length = dataOutMoved
        return buffer
    }

    func finalData() throws -> NSData {
        let outputLength = sizeBufferForDataOfLength(0)
        var dataOutMoved: Int = 0

        let result = CCCryptorFinal(
            cryptor,
            buffer.mutableBytes, outputLength,
            &dataOutMoved
        )

        guard result == CCCryptorStatus(kCCSuccess) else {
            throw NSError(domain: CCErrorDomain, code: Int(result), userInfo: nil)
        }
        
        buffer.length = dataOutMoved
        return buffer
    }
}

public struct FormatV3 {
    static public let version = UInt8(3)
    static public let keySize = kCCKeySizeAES256

    static let ivSize   = kCCBlockSizeAES128
    static let hmacSize = Int(CC_SHA256_DIGEST_LENGTH)
    static let saltSize = 8

    static let keyHeaderSize = 1 + 1 + kCCBlockSizeAES128
    static let passwordHeaderSize = 1 + 1 + 8 + 8 + kCCBlockSizeAES128

    static public func keyForPassword(password: String, salt: NSData) -> NSData {
        let derivedKey = NSMutableData(length: keySize)!
        let derivedKeyPtr = UnsafeMutablePointer<UInt8>(derivedKey.mutableBytes)

        let passwordData = password.dataUsingEncoding(NSUTF8StringEncoding)!
        let passwordPtr = UnsafePointer<Int8>(passwordData.bytes)

        let saltPtr = UnsafePointer<UInt8>(salt.bytes)

        // All the crazy casting because CommonCryptor hates Swift
        let algorithm     = CCPBKDFAlgorithm(kCCPBKDF2)
        let prf           = CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1)
        let pbkdf2Rounds  = UInt32(10000)

        let result = CCKeyDerivationPBKDF(
            algorithm,
            passwordPtr,   passwordData.length,
            saltPtr,       salt.length,
            prf,           pbkdf2Rounds,
            derivedKeyPtr, derivedKey.length)

        guard result == CCCryptorStatus(kCCSuccess) else {
            fatalError("SECURITY FAILURE: Could not derive secure password (\(result)): \(derivedKey).")
        }
        return derivedKey
    }
}

internal typealias V3 = FormatV3

@objc(RNEncryptorV3)
public final class EncryptorV3 : NSObject, CryptorType {
    private var engine: Engine
    private var hmac: HMACV3

    private var pendingHeader: NSData?

    private init(encryptionKey: NSData, hmacKey: NSData, iv: NSData, header: NSData) {
        precondition(encryptionKey.length == V3.keySize)
        precondition(hmacKey.length == V3.keySize)
        precondition(iv.length == V3.ivSize)
        hmac = HMACV3(key: hmacKey)
        engine = Engine(operation: .Encrypt, key: encryptionKey, iv: iv)
        pendingHeader = header
    }

    // Expose random numbers for testing
    internal convenience init(encryptionKey: NSData, hmacKey: NSData, iv: NSData) {
        let preamble = [V3.version, UInt8(0)]
        let header = NSMutableData(bytes: preamble, length: preamble.count)
        header.appendData(iv)
        self.init(encryptionKey: encryptionKey, hmacKey: hmacKey, iv: iv, header: header)
    }

    public convenience init(encryptionKey: NSData, hmacKey: NSData) {
        self.init(encryptionKey: encryptionKey, hmacKey: hmacKey, iv: randomDataOfLength(V3.ivSize))
    }

    // Expose random numbers for testing
    internal convenience init(password: String, encryptionSalt: NSData, hmacSalt: NSData, iv: NSData) {
        let encryptionKey = V3.keyForPassword(password, salt: encryptionSalt)
        let hmacKey = V3.keyForPassword(password, salt: hmacSalt)

        // TODO: This chained-+ is very slow to compile in Swift 2b5 (http://www.openradar.me/21842206)
        // let header = [V3.version, UInt8(1)] + encryptionSalt + hmacSalt + iv
        let preamble = [V3.version, UInt8(1)]
        let header = NSMutableData(bytes: preamble, length: preamble.count)
        header.appendData(encryptionSalt)
        header.appendData(hmacSalt)
        header.appendData(iv)

        self.init(encryptionKey: encryptionKey, hmacKey: hmacKey, iv: iv, header: header)
    }

    public convenience init(password: String) {
        self.init(
            password: password,
            encryptionSalt: randomDataOfLength(V3.saltSize),
            hmacSalt: randomDataOfLength(V3.saltSize),
            iv: randomDataOfLength(V3.ivSize))
    }

    public func encryptData(data: NSData) -> NSData {
        return try! oneshot(data)
    }

    private func handle(data: NSData) -> NSData {
        var result: NSData
        if let ph = pendingHeader {
            let accum = NSMutableData(data: ph)
            pendingHeader = nil
            accum.appendData(data)
            result = accum
        } else {
            result = data
        }
        hmac.updateWithData(result)
        return result
    }

    public func updateWithData(data: NSData) -> NSData {
        // It should not be possible for this to fail during encryption
        return try! handle(engine.updateWithData(data))
    }

    public func finalData() -> NSData {
        let result = NSMutableData(data: try! handle(engine.finalData()))
        result.appendData(hmac.finalData())
        return result
    }
}

@objc(RNDecryptorV3)
public final class DecryptorV3: NSObject, PasswordDecryptorType {
    static let preambleSize = 1
    static func canDecrypt(preamble: NSData) -> Bool {
        assert(preamble.length >= 1)
        return preamble.bytesView[0] == 3
    }

    var requiredHeaderSize: Int {
        switch credential {
        case .Password(_): return V3.passwordHeaderSize
        case .Keys(_, _): return V3.keyHeaderSize
        }
    }

    private var buffer = NSMutableData()
    private var decryptorEngine: DecryptorEngineV3?
    private let credential: Credential

    public init(password: String) {
        credential = .Password(password)
    }

    public init(encryptionKey: NSData, hmacKey: NSData) {
        precondition(encryptionKey.length == V3.keySize)
        precondition(hmacKey.length == V3.hmacSize)
        credential = .Keys(encryptionKey: encryptionKey, hmacKey: hmacKey)
    }

    public func decryptData(data: NSData) throws -> NSData {
        return try oneshot(data)
    }

    public func updateWithData(data: NSData) throws -> NSData {
        if let e = decryptorEngine {
            return try e.updateWithData(data)
        }

        buffer.appendData(data)
        guard buffer.length >= requiredHeaderSize else {
            return NSData()
        }

        let e = try createEngineWithCredential(credential, header: buffer.bytesView[0..<requiredHeaderSize])
        decryptorEngine = e
        let body = buffer.bytesView[requiredHeaderSize..<buffer.length]
        buffer.length = 0
        return try e.updateWithData(body)
    }

    private func createEngineWithCredential(credential: Credential, header: NSData) throws -> DecryptorEngineV3 {
        switch credential {
        case let .Password(password):
            return try createEngineWithPassword(password, header: header)
        case let .Keys(encryptionKey, hmacKey):
            return try createEngineWithKeys(encryptionKey: encryptionKey, hmacKey: hmacKey, header: header)
        }
    }

    private func createEngineWithPassword(password: String, header: NSData) throws -> DecryptorEngineV3 {
        assert(password != "")
        precondition(header.length == V3.passwordHeaderSize)

        guard DecryptorV3.canDecrypt(header) else {
            throw RNCryptorError.UnknownHeader
        }

        guard header.bytesView[1] == 1 else {
            throw RNCryptorError.InvalidCredentialType
        }

        let encryptionSalt = header.bytesView[2...9]
        let hmacSalt = header.bytesView[10...17]
        let iv = header.bytesView[18...33]

        let encryptionKey = V3.keyForPassword(password, salt: encryptionSalt)
        let hmacKey = V3.keyForPassword(password, salt: hmacSalt)

        return DecryptorEngineV3(encryptionKey: encryptionKey, hmacKey: hmacKey, iv: iv, header: header)
    }

    private func createEngineWithKeys(encryptionKey encryptionKey: NSData, hmacKey: NSData, header: NSData) throws -> DecryptorEngineV3 {
        precondition(header.length == V3.keyHeaderSize)
        precondition(encryptionKey.length == V3.keySize)
        precondition(hmacKey.length == V3.keySize)

        guard DecryptorV3.canDecrypt(header) else {
            throw RNCryptorError.UnknownHeader
        }

        guard header.bytesView[1] == 0 else {
            throw RNCryptorError.InvalidCredentialType
        }

        let iv = header.bytesView[2..<18]
        return DecryptorEngineV3(encryptionKey: encryptionKey, hmacKey: hmacKey, iv: iv, header: header)
    }

    public func finalData() throws -> NSData {
        guard let result = try decryptorEngine?.finalData() else {
            throw RNCryptorError.MessageTooShort
        }
        return result
    }
}

private enum Credential {
    case Password(String)
    case Keys(encryptionKey: NSData, hmacKey: NSData)
}


private final class DecryptorEngineV3 {
    private let buffer = OverflowingBuffer(capacity: V3.hmacSize)
    private var hmac: HMACV3
    private var engine: Engine

    init(encryptionKey: NSData, hmacKey: NSData, iv: NSData, header: NSData) {
        precondition(encryptionKey.length == V3.keySize)
        precondition(hmacKey.length == V3.hmacSize)
        precondition(iv.length == V3.ivSize)

        hmac = HMACV3(key: hmacKey)
        hmac.updateWithData(header)
        engine = Engine(operation: .Decrypt, key: encryptionKey, iv: iv)
    }

    func updateWithData(data: NSData) throws -> NSData {
        let overflow = buffer.updateWithData(data)
        hmac.updateWithData(overflow)
        return try engine.updateWithData(overflow)
    }

    func finalData() throws -> NSData {
        let result = try engine.finalData()
        let hash = hmac.finalData()
        if !isEqualInConsistentTime(trusted: hash, untrusted: buffer.finalData()) {
            throw RNCryptorError.HMACMismatch
        }
        return result
    }
}

private final class HMACV3 {
    var context: CCHmacContext = CCHmacContext()

    init(key: NSData) {
        CCHmacInit(
            &context,
            CCHmacAlgorithm(kCCHmacAlgSHA256),
            key.bytes,
            key.length
        )
    }

    func updateWithData(data: NSData) {
        CCHmacUpdate(&context, data.bytes, data.length)
    }
    
    func finalData() -> NSData {
        let hmac = NSMutableData(length: V3.hmacSize)!
        CCHmacFinal(&context, hmac.mutableBytes)
        return hmac
    }
}
