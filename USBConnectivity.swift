//
//  USBConnectivity.swift
//
//
//  Created by trulyspinach on 7/2/21.
//

import Foundation

protocol TypedFramePacket {
    static func getTypeID() -> UInt32
}

protocol TypedBinaryFramePacket: TypedFramePacket {
    static func decode(data: Data) -> Self
    func encode() -> Data
}

protocol PeerConnectivityDelegate {
    func peer(shouldAcceptDataOfType type: UInt32) -> Bool
    func peer(didReceiveData data: Data, ofType type: UInt32)
    func peer(didChangeConnection connected: Bool)
}

class USBConnectivity: NSObject {
    
    private var hostChannel: PTChannel?
    
    private var peerChannel: PTChannel?
    private var currentPeerID: Int = -1
    private var connecting = false
    
    private let jsonEncoder = JSONEncoder()
    
    var delegate: PeerConnectivityDelegate?
    
    var port: Int?
    let isHost: Bool
    
    init(host: Bool) {
        isHost = host
        
        super.init()
    }
    
    var reconnectTimer : Timer?
    
    func isConnected() -> Bool {
        return hostChannel != nil && hostChannel!.isConnected
    }
    
    func start(port: Int) {
        self.port = port
        if isHost {
            startConnecting()
        } else {
            startListening()
            
        }
    }
    
    private func startConnecting() {
        let nc = NotificationCenter.default
        
        nc.addObserver(forName: NSNotification.Name.PTUSBdeviceDidAttach,
                       object: PTUSBHub.shared(), queue: nil){ (info) in
            print("[USBConnectivity, Host:\(self.isHost)] Attached Device ID: \(info.userInfo!["DeviceID"]!)")

            if self.peerChannel != nil && self.peerChannel!.isConnected{
                print("[USBConnectivity, Host:\(self.isHost)] Device \(info.userInfo!["DeviceID"]!) ignored, connection already opened.")
                return
            }
            self.currentPeerID = info.userInfo!["DeviceID"]! as! Int
//            print(info.userInfo!)
            DispatchQueue.main.async {
                self.openConnectChannel()
            }
            
        }

        nc.addObserver(forName: NSNotification.Name.PTUSBdeviceDidDetach,
                       object: PTUSBHub.shared(), queue: nil) { [self] (info) in
            print("[USBConnectivity, Host:\(self.isHost)] Detached Device ID: \(info.userInfo!["DeviceID"]!)")

            if info.userInfo!["DeviceID"]! as! Int != self.currentPeerID {return}

            currentPeerID = -1
            peerChannel?.close()
            peerChannel = nil
            
//            delegate?.peer(didChangeConnection: false)
        }
    }
    
    private func startListening() {
        hostChannel = PTChannel(protocol: nil, delegate: self)
        hostChannel?.delegate = self
        hostChannel?.listen(on: in_port_t(port!), IPv4Address: INADDR_LOOPBACK){
            error in
            if let e = error {
                print("[USBConnectivity, Host:\(self.isHost)] failed to start: \(e)")
            }
        }
    }
    
    func openConnectChannel(){
        let channel = PTChannel(protocol: nil, delegate: nil)
        channel.userInfo = currentPeerID
        
        connecting = true
        channel.connect(to: Int32(port!), over: PTUSBHub.shared(),
                        deviceID: NSNumber(value: self.currentPeerID)) {[self] (error) in
            if error != nil {
                if connecting && channel.userInfo as! Int == currentPeerID {
                    reconnectTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: false) {_ in
                        openConnectChannel()
                    }
                }
            } else {
                peerChannel = channel
                peerChannel?.delegate = self
                connecting = false
                delegate?.peer(didChangeConnection: true)
            }
        }
    }
    
    func send(data: Data, frameType: UInt32) {
        peerChannel?.sendFrame(type: frameType, tag: PTFrameNoTag, payload: data) {
            error in
            if let e = error {
                print("[USBConnectivity, Host:\(self.isHost)] error sending frame \(e)")
            }
        }
    }
    
    func send<T : Codable>(codableInJSON: T, frameType: UInt32) {
        var jd: Data?
        do {
            try jd = jsonEncoder.encode(codableInJSON)
        } catch {
            print("Failed to encode")
        }
        
        send(data: jd!, frameType: frameType)
    }
    
    func send<T: TypedFramePacket & Codable>(codableInJSONWithType: T){
        send(codableInJSON: codableInJSONWithType, frameType: T.getTypeID())
    }
    
    func send<T: TypedBinaryFramePacket>(binaryWithType: T){
        send(data: binaryWithType.encode(), frameType: T.getTypeID())
    }
    
}


extension USBConnectivity: PTChannelDelegate {
    func channel(_ channel: PTChannel, didRecieveFrame type: UInt32, tag: UInt32, payload: Data?) {
        delegate?.peer(didReceiveData: payload!, ofType: type)
    }
    
    func channel(_ channel: PTChannel, shouldAcceptFrame type: UInt32, tag: UInt32, payloadSize: UInt32) -> Bool {
        return delegate?.peer(shouldAcceptDataOfType: type) ?? false
    }
    
    
    func channel(_ channel: PTChannel, didAcceptConnection otherChannel: PTChannel, from address: PTAddress) {
        peerChannel = otherChannel
//        print("We have a host! \(address)")
        delegate?.peer(didChangeConnection: true)
    }
    
    func channelDidEnd(_ channel: PTChannel, error: Error?) {
//        print("We are down!")
        delegate?.peer(didChangeConnection: false)
        if isHost {
            reconnectTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: false) { [self]_ in
                if peerChannel != nil && peerChannel?.userInfo as! Int == currentPeerID {
                    openConnectChannel()
                }
            }
            return
        }
        
        peerChannel = nil
        currentPeerID = -1
    }
}
