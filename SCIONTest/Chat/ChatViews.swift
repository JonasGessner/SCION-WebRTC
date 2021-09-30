//
//  Chat.swift
//  SCIONTest
//  Copyright Jonas Gessner
//  Created by Jonas Gessner on 15.03.21.
//

import Foundation
import SwiftUI
import Combine

extension View {
    func hideKeyboard() {
        #if canImport(UIKit)
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        #endif
    }
}

struct MessageView: View {
    let message: ChatMessage
    
    var body: some View {
        #if os(macOS)
        let fill = Color(message.sent ? NSColor.green : NSColor.shadowColor.withAlphaComponent(0.3))
        #else
        let fill = Color(message.sent ? UIColor.green : UIColor.separator)
        #endif
        
        VStack {
            let hashedPath = message.path?.canonicalFingerprintShortWithTCInfo ?? "-"

            Text("Path: \(String(hashedPath))")
                .lineLimit(nil)
                .font(.caption2)
                .foregroundColor(.gray)

            Text(message.content)
        }
        .padding()
        .background(RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(fill.opacity(0.2)))
    }
}

struct PathSelectionView: View {
    @ObservedObject private(set) var connection: SCIONUDPConnection
    var done: () -> Void
    let initialProcessor: PathProcessor
    let showProcessorOptions: Bool
    @State var selectedProcessor: PathProcessor
    
    private var policyOptions: [PathProcessor] {
        var policies: [PathProcessor] = ([HopPathSorter(), LatencyPathSorter(), LatencyProbingPathProcessor(), MirrorPathSorter(), NoHellPathProcessor()] as [PathProcessor]).map({ $0 }).map({ SequentialPathProcessor(processors: [HellPreprocessor(), $0]) })
        if !policies.contains(where: { $0.id == initialProcessor.id }) {
            policies.insert(initialProcessor, at: 0)
        }
        return policies
    }
    
    private func description(for path: SCIONPath, processor: PathProcessor, root: Bool = true) -> String {
        var descriptions: [String] = []
        
        if root {
            descriptions.append("\(path.canonicalFingerprintShortWithTCInfo)")
        }
        
        if let sequential = processor as? SequentialPathProcessor {
            for sub in sequential.byCollectingPenalties().processors {
                descriptions.append(description(for: path, processor: sub, root: false))
            }
        }
        else if let latency = processor as? LatencyProbingPathProcessor {
            let rawScore = latency.score(for: path)
            let desc = /*Hops \(path.hops)*/"Measured RTT: \(rawScore == .greatestFiniteMagnitude ? "-" : "\(rawScore)")"
            descriptions.append(desc)
        }
        else if let punisher = processor as? PathPenalizer {
            let formatter = NumberFormatter()
            formatter.minimumFractionDigits = 0
            formatter.maximumFractionDigits = 2
            formatter.decimalSeparator = "."
            let str = formatter.string(from: NSNumber(value: punisher.punishmentWeight(for: path))) ?? ""
            
            descriptions.append("Penalty \(str)")
        }
        else if processor is HellPreprocessor {
            
        }
        else {
            descriptions.append("\(processor.id)")
        }
        
        let description = descriptions.filter({ !$0.isEmpty }).joined(separator: ", ")
        
        return description
    }
    
    var body: some View {
        let f = Form {
            if showProcessorOptions {
                Section(header: Text("Processors")) {
                    ForEach(policyOptions, id: \.id) { processor in
                        let b = Button {
                            connection.pathProcessor = processor
                            selectedProcessor = processor
                        } label: {
                            HStack {
                                Text(processor.id)
                                if selectedProcessor.id == processor.id {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                        
                        #if os(macOS)
                        VStack {
                            b
                                .buttonStyle(PlainButtonStyle())
                            Divider()
                        }
                        #else
                        b
                        #endif
                    }
                }
            }
            Section {
                Button("Force path processor reevaluation") {
                    connection.forcePolicyUpdate(context: 0)
                }
            }
            Section(header: Text("Paths")) {
                ForEach(Array(connection.paths.enumerated()), id: \.0) { index, path in
                    let b = Button {
                        if connection.fixedPath == path {
                            connection.fixedPath = nil
                        }
                        else {
                            connection.fixedPath = path
                        }
                    } label: {
                        HStack {
                            let description = description(for: path, processor: connection.fullPathProcessor)
                            Text(description)
                            
                            let img = Image(systemName: "checkmark")
                            if connection.fixedPath == path {
                                img.foregroundColor(.red)
                            }
                            else if connection.effectivePath == path {
                                img
                            }
                            else {
                                img.hidden()
                            }
                        }
                    }
                    
                    #if os(macOS)
                    VStack {
                        b
                            .buttonStyle(PlainButtonStyle())
                        Divider()
                    }
                    #else
                    b
                    #endif
                }
            }
        }
        
        #if os(macOS)
        let l = ScrollView {
            f
                .frame(minWidth: 400)
                .padding()
        }
        #else
        let l = f
        #endif
        
        let b = Button("Done") {
            done()
        }
        
        #if os(macOS)
        VStack {
            ZStack {
                Text("Select Path")
                HStack {
                    Spacer()
                    b.padding(8)
                }
            }
            l
        }
        #else
        NavigationView {
            l
                .navigationTitle("Select Path")
                .toolbar(content: {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        b
                    }
                    
                })
        }
        #endif
    }
}

extension PathSelectionView {
    init(connection: SCIONUDPConnection, done: @escaping () -> Void) {
        self.init(connection: connection, done: done, initialProcessor: connection.pathProcessor, showProcessorOptions: true, selectedProcessor: connection.pathProcessor)
    }
}

struct ConnectionView: View {
    @ObservedObject private(set) var chat: ChatConnection
    @ObservedObject private(set) var connection: SCIONUDPConnection
    
    @State private var draft = ""
    @State private var showPathSelection = false
    @State private var timer: Timer?
    @State private var runningBWTest = false
    @State private var lossTestPacketsSentOnCurrentPath = 0
    
    init(chat: ChatConnection) {
        self.chat = chat
        connection = chat.connection
    }
    
    private func send() {
        guard !draft.isEmpty else { return }
        do {
            try chat.send(draft)
        }
        catch {
            print("Send error! \(error.localizedDescription)")
        }
    }
    
    @ViewBuilder
    var testInfo: some View {
        Text("Loss test stats: sent \(chat.lossTestSent) ACKs gotten \(chat.lossTestAcksReceived) packets lost \(chat.lossTestSent - chat.lossTestAcksReceived) loss: \(100 * Double(chat.lossTestSent - chat.lossTestAcksReceived)/Double(chat.lossTestSent))%. ACKs sent \(chat.lossTestAcksSent)")
        
        let formatter = ByteCountFormatter()
        
        let sentFormatted = formatter.string(fromByteCount: Int64(chat.bandwidthSent))
        let receivedFormatted = formatter.string(fromByteCount: Int64(chat.bandwidthReceived))
        
        Text("Bandwidth test stats: sent \(chat.bandwidthTestsSent) packets, \(sentFormatted)\nreceived \(chat.bandwidthTestsReceived) packets \(receivedFormatted)")
    }
    
    var body: some View {
        let v = VStack {
            Spacer().frame(height: 5)
            Text("Connection to \(chat.connection.remoteAddress.description)")
            Text("Current Path: \(connection.effectivePath?.canonicalFingerprintShortWithTCInfo ?? "-")").font(.caption2)
            Divider()
            
            testInfo
//
            if timer == nil && !runningBWTest {
                Button("Start Loss Test") {
                    timer = Timer.scheduledTimer(withTimeInterval: 0.005, repeats: true, block: { _ in
                        chat.sendLossTest()
//                        lossTestPacketsSentOnCurrentPath += 1
//                        lossTestPacketsSentOnCurrentPath %= 1000
//                        if lossTestPacketsSentOnCurrentPath == 0,
//                           let current = chat.connection.currentPath,
//                           let index = chat.connection.paths.firstIndex(of: current) {
//                            let nextIndex = (index + 1) % chat.connection.paths.count
//                            let newPath = chat.connection.paths[nextIndex]
//                            print("Switched from path \(current.canonicalFingerprintShort) to \(newPath.canonicalFingerprintShort)")
//                            _ = chat.connection.fixPath(newPath)
//                        }
                    })
                }
                
                Button("Start Bandwidth Test") {
                    var index: UInt64 = 0
                    
                    let desiredThroughput = (1024 * 1024) / 8 // 1 Mbit/s
                    let payloadSize = 100
                    
                    let numberOfPacketsPerSecond = desiredThroughput / (payloadSize / 8)
                    
                    let interval = 1.0 / TimeInterval(numberOfPacketsPerSecond)
                    
                    runningBWTest = true
                    
                    DispatchQueue.global(qos: .userInteractive).async {
                        while runningBWTest {
                            let a = CFAbsoluteTimeGetCurrent()
                            chat.sendBandwithPacket(index: index, payloadSize: payloadSize)
                            index += 1
                            let took = CFAbsoluteTimeGetCurrent() - a
                            usleep(UInt32(max(0, (interval - took) * 1_000_000)))
                        }
                    }
//                    timer = Timer.scheduledTimer(withTimeInterval: 0, repeats: true, block: { _ in
//
//                    })
                }
                
                Button("Reset Test Stats") {
                    chat.resetTestStats()
                }
            }
            else {
                Button("Stop Loss/Bandwidth Test") {
                    runningBWTest = false
                    timer?.invalidate()
                    timer = nil
                }
            }
            Divider()
            
            ScrollView {
                LazyVStack {
                    ForEach(chat.chat, id: \.id) { message in
                        HStack {
                            if message.sent {
                                Spacer()
                                MessageView(message: message)
                            }
                            else {
                                MessageView(message: message)
                                Spacer()
                            }
                        }
                        Spacer().frame(height: 5)
                    }
                }
                .padding(.horizontal, 15)
            }
            
            Divider()
            
            HStack {
                TextField("Send Message", text: $draft, onEditingChanged: {_ in}, onCommit: {})
                    .padding([.horizontal, .bottom], 10)
                
                Button("Send", action: send)
                    .padding([.trailing, .bottom], 10)
                    .disabled(draft.isEmpty)
            }
        }
        .sheet(isPresented: $showPathSelection) {
            PathSelectionView(connection: chat.connection) {
                showPathSelection = false
            }
        }

        #if os(macOS)
        return v
        // Bugged!!! back button disappears on iOS. Use .navigationBarItems on iOS instead
                .toolbar(content: {
                    #if os(macOS)
                    let p = ToolbarItemPlacement.primaryAction
                    #else
                    let p = ToolbarItemPlacement.navigationBarTrailing
                    #endif
        
                    ToolbarItem(placement: p) {
                        Button("Select Path") {
                            showPathSelection = true
                        }
                    }
                })
        #else
        return v.navigationBarTitleDisplayMode(.inline)
            .navigationBarItems(trailing: Button("Select Path") {
                showPathSelection = true
            })
        #endif
    }
}

struct ConnectionCell: View {
    @ObservedObject var connection: ChatConnection
    
    var body: some View {
//        let paths = pathExchange.getPaths(to: connection.connection.remoteAddress) ?? []
//        let currentPath = try! connection.connection.getPath()
            
        NavigationLink(destination: ConnectionView(chat: connection)) {
            HStack {
                Text("Connection to \(connection.connection.remoteAddress.description)")
                Spacer()
                Text("\(connection.chat.count) Messages")
                    .font(.caption)
                    .foregroundColor(.gray)
            }
        }
        .buttonStyle(PlainButtonStyle())
    }
}

struct ServerView: View {
    @ObservedObject var serverModel: ChatServerModel
    
    var body: some View {
        let addr = serverModel.server.localAddress!
        
        let v = VStack {
            Spacer().frame(height: 5)
            HStack {
                Text("Server at \(addr.description)")
                
                Spacer().frame(width: 5)
                Button {
                    #if os(macOS)
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.writeObjects([addr.description as NSString])
                    #else
                    UIPasteboard.general.string = addr.description
                    #endif
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(PlainButtonStyle())
            }
            
            let l = List {
                Section(header: Text("Clients")) {
                    ForEach(serverModel.clientConnections, id: \.connection) { connection in
                        ConnectionCell(connection: connection)
                    }
                }
            }
            
            #if os(macOS)
            l
            #else
            l.listStyle(InsetGroupedListStyle())
            #endif
        }
        
        #if os(macOS)
        v
        #else
        v.navigationBarTitleDisplayMode(.inline)
        #endif
    }
}

struct ServerCell: View {
    @ObservedObject var serverModel: ChatServerModel
    
    var body: some View {
        #if os(macOS)
        let dest = NavigationView { ServerView(serverModel: serverModel) }
        #else
        let dest = ServerView(serverModel: serverModel)
        #endif
        
        NavigationLink(destination: dest) {
            HStack {
                let addr = serverModel.server.localAddress!
                
                Text("Server at \(addr.description)")
                
                Spacer().frame(width: 5)
                Button {
                    #if os(macOS)
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.writeObjects([addr.description as NSString])
                    #else
                    UIPasteboard.general.string = addr.description
                    #endif
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                
                Spacer()
                Text("\(serverModel.clientConnections.count) Clients")
                    .font(.caption)
                    .foregroundColor(.gray)
            }
        }
        .buttonStyle(PlainButtonStyle())
    }
}

struct ChatContentView: View {
    @StateObject var model = ChatModel()
    @State var serverAddress = autofillMessengerClientField ? defaultChatServer : ""

    @State var serverPort = "1234"
    
    var body: some View {
        let l = List {
            Section(header: Text("Add Connection")) {
                HStack {
                    Text("Client")
                        .padding(3)
                    TextField("Server Address", text: $serverAddress)
                        .padding(3)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                    Button("Add") {
                        do {
                            let client = try SCIONUDPConnection(clientConnectionTo: serverAddress, pathProcessor: NoHellPathProcessor(), wantsToBeUsedForLatencyProbing: true)
                            serverAddress = ""
                            hideKeyboard()
                            model.add(client: client)
                        }
                        catch {
                            print("Error adding client: \(error.localizedDescription)")
                        }
                    }
                    .buttonStyle(PlainButtonStyle())
                    .disabled(serverAddress.isEmpty)
                }
                HStack {
                    Text("Server")
                        .padding(3)
                    #if os(iOS) || os(tvOS)
                    TextField("Port", text: $serverPort)
                        .keyboardType(.numberPad)
                        .padding(3)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                    #else
                    TextField("Port", text: $serverPort)
                        .padding(3)
                    #endif
                    Button("Add") {
                        do {
                            let server = try SCIONUDPListener(listeningOn: UInt16(serverPort)!, pathProcessor: NoHellPathProcessor(), wantsToBeUsedForLatencyProbing: true)
                            hideKeyboard()
                            model.add(server: server)
                        }
                        catch {
                            print("Error adding client: \(error.localizedDescription)")
                        }
                    }
                    .buttonStyle(PlainButtonStyle())
                    .disabled(serverPort.isEmpty)
                }
            }
            
            
            Section(header: Text("Servers")) {
                ForEach(model.servers, id: \.server) { serverModel in
                    ServerCell(serverModel: serverModel)
                }
            }
            
            Section(header: Text("Clients")) {
                ForEach(model.clients, id: \.connection) { connection in
                    ConnectionCell(connection: connection)
                }
            }
            
        }
        .navigationTitle("SCION p2p Chat")
        
        #if os(macOS)
        l
        #else
        l.listStyle(InsetGroupedListStyle())
        #endif
    }
}
