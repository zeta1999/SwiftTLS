//
//  BlockCipher.swift
//  SwiftTLS
//
//  Created by Nico Schmidt on 12/02/16.
//  Copyright © 2016 Nico Schmidt. All rights reserved.
//

import CommonCrypto

extension UInt32 {
    func bigEndianByteArray() -> [UInt8] {
        return [
            UInt8((self & 0xff000000)   >> 24),
            UInt8((self & 0xff0000)     >> 16),
            UInt8((self & 0xff00)       >> 8),
            UInt8((self & 0xff)),
        ]
    }
}

extension UInt64 {
    func bigEndianByteArray() -> [UInt8] {
        return [
            UInt8((self & 0xff00000000000000)   >> 56),
            UInt8((self & 0xff000000000000)     >> 48),
            UInt8((self & 0xff0000000000)       >> 40),
            UInt8((self & 0xff00000000)         >> 32),
            UInt8((self & 0xff000000)           >> 24),
            UInt8((self & 0xff0000)             >> 16),
            UInt8((self & 0xff00)               >> 8),
            UInt8((self & 0xff)),
        ]
    }
}

class BlockCipher
{
    private var cryptor : CCCryptorRef
    private var encrypt : Bool
    private var _IV : [UInt8]!
    private let mode: BlockCipherMode
    private let cipher : CipherAlgorithm
    var authTag : [UInt8]?
    
    var IV : [UInt8] {
        get {
            return _IV
        }
        set {
            _IV = newValue
            CCCryptorReset(self.cryptor, &_IV)
        }
    }
    
    private init?(encrypt: Bool, cryptor: CCCryptorRef, mode: BlockCipherMode, cipher: CipherAlgorithm)
    {
        self.cryptor = cryptor
        self.encrypt = encrypt
        self.mode = mode
        
        switch cipher
        {
        case .AES128:
            self.cipher = .AES128
        
        case .AES256:
            self.cipher = .AES256
            
        default:
            return nil
        }
    }
    
    private class func CCCipherAlgorithmForCipherAlgorithm(cipherAlgorithm : CipherAlgorithm) -> CCAlgorithm?
    {
        switch (cipherAlgorithm)
        {
        case .AES128, .AES256:
            return CCAlgorithm(kCCAlgorithmAES)
            
        case .NULL:
            return nil
        }
    }
    
    class func encryptionBlockCipher(cipherAlgorithm : CipherAlgorithm, mode: BlockCipherMode, key : [UInt8], IV : [UInt8]) -> BlockCipher?
    {
        guard let algorithm = CCCipherAlgorithmForCipherAlgorithm(cipherAlgorithm) else { return nil }
        
        var encryptor : CCCryptorRef = nil
        
        var key = key
        var IV = IV
        
        let status = Int(CCCryptorCreate(CCOperation(kCCEncrypt), algorithm, UInt32(kCCOptionECBMode), &key, key.count, &IV, &encryptor))
        if status != kCCSuccess {
            return nil
        }

        let cipher = BlockCipher(encrypt: true, cryptor: encryptor, mode: mode, cipher: cipherAlgorithm)
        cipher!._IV = IV
        print(cipher!.IV)
        
        return cipher
    }
    
    class func decryptionBlockCipher(cipherAlgorithm : CipherAlgorithm, mode: BlockCipherMode, key : [UInt8], IV : [UInt8]) -> BlockCipher?
    {
        guard let algorithm = CCCipherAlgorithmForCipherAlgorithm(cipherAlgorithm) else { return nil }
        
        var decryptor : CCCryptorRef = nil
        
        var key = key
        var IV = IV
        let operation = (mode == .GCM) ? CCOperation(kCCEncrypt) : CCOperation(kCCDecrypt)
        let status = Int(CCCryptorCreate(operation, algorithm, UInt32(kCCOptionECBMode), &key, key.count, &IV, &decryptor))
        if status != kCCSuccess {
            return nil
        }
        
        let cipher = BlockCipher(encrypt: false, cryptor: decryptor, mode: mode, cipher: cipherAlgorithm)
        cipher!._IV = IV
        
        return cipher
    }

    func update(data data : [UInt8], key : [UInt8], IV : [UInt8]?) -> [UInt8]?
    {
        return update(data: data, authData: nil, key: key, IV: IV)
    }
    
    func update(data data : [UInt8], authData: [UInt8]?, key : [UInt8], IV : [UInt8]?) -> [UInt8]?
    {
        switch self.mode
        {
        case .CBC:
            return updateCBC(data: data, key: key, IV: IV)

        case .GCM:
            return updateGCM(data: data, authData: authData, key: key, IV: IV)

        }
    }
    
    private func cryptorUpdate(inputBlock inputBlock: MemoryBlock, inout outputBlock: MemoryBlock) -> Bool {
        var outputDataWritten: Int = 0
        let blockSize = self.cipher.blockSize
        precondition(blockSize == inputBlock.block.count)
        
        var inputBlock = inputBlock
        let status = Int(CCCryptorUpdate(self.cryptor, &inputBlock.block, blockSize, &outputBlock.block, blockSize, &outputDataWritten))

        return status == kCCSuccess
    }
    
    private func cryptorOutputLengthForInputLength(inputLength: Int) -> Int {
        return inputLength
//        return CCCryptorGetOutputLength(self.cryptor, inputLength, false)
    }
    
    func updateCBC(data inputData: [UInt8], key: [UInt8], IV: [UInt8]?) -> [UInt8]?
    {
        let outputLength = cryptorOutputLengthForInputLength(inputData.count)
        
        var outputData = [UInt8](count: outputLength, repeatedValue: 0)
        
        if let IV = IV {
            self.IV = IV
        }
        
        let blockSize = self.cipher.blockSize
        let numSteps = outputLength / blockSize

        let isEncrypting = encrypt
        let isDecrypting = !encrypt
        
        var iv = MemoryBlock(self.IV)
        
        for i in 0..<numSteps {
            
            let range = (blockSize * i)..<(blockSize * (i + 1))
            
            var inputBlock  = MemoryBlock(inputData[range])
            var outputBlock = MemoryBlock(outputData[range])
            
            if isEncrypting {
                inputBlock ^= iv
            }

            if !cryptorUpdate(inputBlock: inputBlock, outputBlock: &outputBlock) {
                return nil
            }
            
            if isDecrypting {
                outputBlock ^= iv
                iv = inputBlock
            }
            else if isEncrypting {
                iv = outputBlock
            }

            outputData[range].replaceRange(range, with: outputBlock.block)
        }
        
        self.IV = iv.block
        
        return outputData
    }

    func updateGCM(data inputData: [UInt8], authData: [UInt8]?, key: [UInt8], IV initializationVector: [UInt8]?) -> [UInt8]?
    {
        let outputLength = cryptorOutputLengthForInputLength(inputData.count)
        
        var outputData = [UInt8](count: outputLength, repeatedValue: 0)
        
        let blockSize = self.cipher.blockSize
        var numSteps = outputLength / blockSize
        if outputLength % blockSize != 0 {
            numSteps += 1
        }
        
        let isEncrypting = encrypt
        let isDecrypting = !encrypt
        
        var hBlock = MemoryBlock(blockSize: blockSize)
        cryptorUpdate(inputBlock: hBlock, outputBlock: &hBlock)
        let H = GF2_128_Element(hBlock.block)!
        
        var IV : [UInt8]
        if let initializationVector = initializationVector {
            IV = initializationVector
        }
        else {
            IV = self.IV
        }

        if IV.count != 12 {
            let lenA = UInt64(0)
            let lenIV = UInt64(IV.count) << 3
            let len = lenA.bigEndianByteArray() + lenIV.bigEndianByteArray()
            let ivMAC = ghashUpdate(GF2_128_Element(), h: H, x: IV)
            IV = ghashUpdate(ivMAC, h: H, x: len).asBigEndianByteArray()
        }
        self.IV = IV

        var mac = GF2_128_Element(0)
        
        if let authData = authData where authData.count > 0 {
            mac = ghashUpdate(mac, h: H, x: authData)
        }
        
        if IV.count == 12 {
            IV.appendContentsOf([0,0,0,1] as [UInt8])
        }
        
        var counter = MemoryBlock(IV, blockSize: blockSize)
        let c1 = UInt32(IV[12]) << UInt32(24)
        let c2 = UInt32(IV[13]) << UInt32(16)
        let c3 = UInt32(IV[14]) << UInt32(8)
        let c4 = UInt32(IV[15])
        
        var counter32 : UInt32 = c1 + c2 + c3 + c4
        
        let Y0 = counter
        
        let authDataCount = authData != nil ? authData!.count : 0
        
        for i in 0..<numSteps {

            counter32 += 1
            counter.block[12..<16] = counter32.bigEndianByteArray()[0..<4]

            let start = (blockSize * i)
            var end   = (blockSize * (i + 1))
            
            if end >= inputData.endIndex {
                end = inputData.endIndex
            }
            
            let range = start..<end
            
            var encrypted = MemoryBlock(blockSize: blockSize)
            if !cryptorUpdate(inputBlock: counter, outputBlock: &encrypted) {
                return nil
            }
            
            let inputBlock  = MemoryBlock(inputData[range], blockSize: end - start)
            encrypted = MemoryBlock(encrypted.block, blockSize: end - start)
            encrypted ^= inputBlock
            
            if isEncrypting {
                mac = ghashUpdate(mac, h: H, x: encrypted.block)
            }
            else if isDecrypting {
                mac = ghashUpdate(mac, h: H, x: inputBlock.block)
            }
            
            outputData[range].replaceRange(range, with: encrypted.block)
        }
        
        if inputData.count + authDataCount > 0 {
            let len = UInt64(authDataCount << 3).bigEndianByteArray() + UInt64(inputData.count << 3).bigEndianByteArray()
            mac = ghashUpdate(mac, h: H, x: len)
        }

        var authTag = MemoryBlock(blockSize: 16)
        cryptorUpdate(inputBlock: Y0, outputBlock: &authTag)
        authTag ^= MemoryBlock(mac.hi.bigEndianByteArray() + mac.lo.bigEndianByteArray())
        self.authTag = authTag.block
        
        return outputData
    }
}

struct MemoryBlock
{
    var block : [UInt8]

    init(_ array : [UInt8], blockSize : Int = 16)
    {
        var array = array
        if array.count < blockSize {
            array.appendContentsOf([UInt8](count: blockSize - array.count, repeatedValue: 0))
        }
        else if blockSize < array.count {
            array.removeLast(array.count - blockSize)
        }
        
        self.block = array
    }
    
    init(_ slice: ArraySlice<UInt8>, blockSize: Int = 16)
    {
        self = MemoryBlock([UInt8](slice), blockSize: blockSize)
    }
    
    init(blockSize: Int = 16)
    {
        self = MemoryBlock([UInt8](count: blockSize, repeatedValue: 0), blockSize: blockSize)
    }
}

func ^= (inout lhs : MemoryBlock, other : MemoryBlock)
{
    precondition(lhs.block.count == other.block.count)
    
    for i in 0..<lhs.block.count {
        lhs.block[lhs.block.startIndex + i] ^= other.block[other.block.startIndex + i]
    }
}