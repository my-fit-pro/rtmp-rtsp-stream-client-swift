//
// Created by Pedro  on 17/7/22.
// Copyright (c) 2022 pedroSG94. All rights reserved.
//

import Foundation

public class RtmpSender {

    private let h264FlvPacket = H264FlvPacket()
    private let aacFlvPacket = AacFlvPacket()
    private let thread = DispatchQueue(label: "RtmpSender")
    private var running = false
    private let queue = SynchronizedQueue<FlvPacket>(label: "RtmpSenderQueue", size: 485035840)
    private let callback: ConnectCheckerRtmp
    private let commandManager: CommandManager
    var socket: Socket? = nil

    public init(callback: ConnectCheckerRtmp, commandManager: CommandManager) {
        self.callback = callback
        self.commandManager = commandManager
    }
    
    public func setVideoInfo(sps: Array<UInt8>, pps: Array<UInt8>, vps: Array<UInt8>?) {
        h264FlvPacket.setVideoInfo(sps: sps, pps: pps)
    }
    
    public func setAudioInfo(sampleRate: Int, isStereo: Bool) {
        aacFlvPacket.sendAudioInfo(sampleRate: sampleRate, isStereo: isStereo)
    }
    
    public func sendVideo(buffer: Array<UInt8>, ts: UInt64) {
        if (running) {
            h264FlvPacket.createFlvVideoPacket(
                buffer: buffer, ts: ts,
                callback: { (flvPacket) in
                    queue.enqueue(flvPacket)
                }
            )
        }
    }
    
    public func sendAudio(buffer: Array<UInt8>, ts: UInt64) {
        if (running) {
            aacFlvPacket.createFlvAudioPacket(
                buffer: buffer, ts: ts,
                callback: { (flvPacket) in
                    queue.enqueue(flvPacket)
                }
            )
        }
    }
    
    public func start() {
        queue.clear()
        running = true
        thread.async {
            while (self.running) {
                let flvPacket = self.queue.dequeue()
                if let flvPacket = flvPacket {
                    do {
                        if (flvPacket.type == FlvType.VIDEO) {
                            let size = try self.commandManager.sendVideoPacket(flvPacket: flvPacket, socket: self.socket!)
                            print("wrote Video packet, size: \(size)")
                        } else {
                            let size = try self.commandManager.sendAudioPacket(flvPacket: flvPacket, socket: self.socket!)
                            print("wrote Audio packet, size: \(size)")
                        }
                    } catch let error {
                        self.callback.onConnectionFailedRtmp(reason: error.localizedDescription)
                        return
                    }
                }
            }
        }
    }

    public func stop() {
        running = false
        aacFlvPacket.reset()
        h264FlvPacket.reset(resetInfo: true)
        queue.clear()
    }
}
