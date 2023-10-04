import Foundation

public class RtspSender {
    
    private var audioPacketizer: AacPacket?
    private var videoPacketizer: BasePacket?
    private var tcpSocket: BaseRtpSocket?
    private var tcpReport: BaseSenderReport?
    private let thread = DispatchQueue(label: "RtspSender")
    private var running = false
    var cacheSize = 10 * 1024 * 1024 / RtpConstants.MTU
    private let queue: SynchronizedQueue<RtpFrame>
    private let callback: ConnectCheckerRtsp

    var audioFramesSent = 0
    var videoFramesSent = 0
    var droppedAudioFrames = 0
    var droppedVideoFrames = 0
    private let bitrateManager: BitrateManager
    var isEnableLogs = true
    
    public init(callback: ConnectCheckerRtsp) {
        self.callback = callback
        queue = SynchronizedQueue<RtpFrame>(label: "RtspSenderQueue", size: cacheSize)
        bitrateManager = BitrateManager(connectCheckerRtsp: callback)
    }

    public func setSocketInfo(mProtocol: Protocol, socket: Socket, videoClientPorts: Array<Int>, audioClientPorts: Array<Int>, videoServerPorts: Array<Int>, audioServerPorts: Array<Int>) {
        switch (mProtocol) {
        case .TCP:
            tcpSocket = RtpSocketTcp(socket: socket)
            tcpReport = SenderReportTcp(socket: socket)
            break
        case .UDP:
            let videoReportPorts = Array<Int>(arrayLiteral: videoClientPorts[1], videoServerPorts[1])
            let audioReportPorts = Array<Int>(arrayLiteral: audioClientPorts[1], audioServerPorts[1])
            let videoSocketPorts = Array<Int>(arrayLiteral: videoClientPorts[0], videoServerPorts[0])
            let audioSocketPorts = Array<Int>(arrayLiteral: audioClientPorts[0], audioServerPorts[0])
            tcpSocket = RtpSocketUdp(callback: callback, host: socket.host, videoPorts: videoSocketPorts, audioPorts: audioSocketPorts)
            tcpReport = SenderReportUdp(callback: callback, host: socket.host, videoPorts: videoReportPorts, audioPorts: audioReportPorts)
            break
        }
    }

    public func setVideoInfo(sps: Array<UInt8>, pps: Array<UInt8>, vps: Array<UInt8>?) {
        if (vps == nil) {
            videoPacketizer = H264Packet(sps: sps, pps: pps)
        } else {
            videoPacketizer = H265Packet(sps: sps, pps: pps)
        }

    }
    
    public func setAudioInfo(sampleRate: Int) {
        audioPacketizer = AacPacket(sampleRate: 44100)
    }
    
    public func sendVideo(buffer: Array<UInt8>, ts: UInt64) {
        if (running) {
            videoPacketizer?.createAndSendPacket(
                buffer: buffer, ts: ts,
                callback: { (rtpFrame) in
                    if (!queue.enqueue(rtpFrame)) {
                        print("Video frame discarded")
                        droppedVideoFrames += 1
                    }
                }
            )
        }
    }
    
    public func sendAudio(buffer: Array<UInt8>, ts: UInt64) {
        if (running) {
            audioPacketizer?.createAndSendPacket(
                buffer: buffer, ts: ts,
                callback: { (rtpFrame) in
                    if (!queue.enqueue(rtpFrame)) {
                        print("Audio frame discarded")
                        droppedAudioFrames += 1
                    }
                }
            )
        }
    }

    public func start() {
        let ssrcVideo = UInt64(Int.random(in: 0..<Int.max))
        let ssrcAudio = UInt64(Int.random(in: 0..<Int.max))
        videoPacketizer?.setSSRC(ssrc: ssrcVideo)
        audioPacketizer?.setSSRC(ssrc: ssrcAudio)
        tcpReport?.setSSRC(ssrcVideo: ssrcVideo, ssrcAudio: ssrcAudio)
        queue.clear()
        running = true
        thread.async {
            let isTcp = self.tcpSocket is RtpSocketTcp
            while (self.running) {
                let frame = self.queue.dequeue()
                if let frame = frame {
                    do {
                        try self.tcpSocket?.sendFrame(rtpFrame: frame, isEnableLogs: self.isEnableLogs)
                        if (frame.channelIdentifier == RtpConstants.trackVideo) {
                            self.videoFramesSent += 1
                        } else {
                            self.audioFramesSent += 1
                        }
                        let packetSize = if (isTcp) {
                            4 + (frame.length ?? 0)
                        } else {
                            (frame.length ?? 0)
                        }
                        self.bitrateManager.calculateBitrate(size: Int64(packetSize * 8))
                        let updated = try self.tcpReport?.update(rtpFrame: frame, isEnableLogs: self.isEnableLogs)
                        if (updated ?? false) {
                            //bytes to bits (4 is tcp header length)
                            let reportSize = if (isTcp) {
                                self.tcpReport?.PACKET_LENGTH ?? (0 + 4)
                            } else {
                                self.tcpReport?.PACKET_LENGTH ?? 0
                            }
                            self.bitrateManager.calculateBitrate(size: Int64(reportSize) * 8)
                        }
                    } catch let error {
                        self.callback.onConnectionFailedRtsp(reason: error.localizedDescription)
                        return
                    }
                }
            }
        }
    }

    public func stop() {
        running = false
        tcpReport?.close()
        queue.clear()
        videoFramesSent = 0
        audioFramesSent = 0
        droppedVideoFrames = 0
        droppedAudioFrames = 0
    }
    
    public func hasCongestion() -> Bool {
        let size = queue.itemsCount()
        let remaining = queue.remaining()
        let capacity = size + remaining
        return Double(size) >= Double(capacity) * 0.2 //more than 20% queue used. You could have congestion
    }
    
    public func resizeCache(newSize: Int) {
        queue.resizeSize(size: newSize)
    }
}
