//
//  ContentView.swift
//  SCIONTest
//  Copyright Jonas Gessner
//  Created by Jonas Gessner on 15.03.21.
//

import SwiftUI

struct LazyView<Content: View>: View {
    let build: () -> Content
    init(_ build: @autoclosure @escaping () -> Content) {
        self.build = build
    }
    var body: Content {
        build()
    }
}

struct ContentView: View {
    @State private var needsConfig = !skipSCIONSetup
    @State private var callShown = skipSCIONSetup && straightToCall // If Scion setup if not skipped it will jump to the call when setup is complete
    
    @ObservedObject private var stack = SCIONStack.shared
    
    private func setupView() -> some View {
        SCIONSetupView { brIP, topoTemplate in
            do {
                #if HAS_SCION
                let params = TopologyParameters(borderRouter: brIP)
                let topo = topoTemplate.generateTopology(for: params)
                try SCIONStack.shared.initScionStack(topology: topo)
                #endif
                needsConfig = false
                if straightToCall {
                    // Jump straight to call
                    callShown = true
                }
            }
            catch {
                print("Error setting up SCION with border router \(brIP): \(error)")
            }
        }
    }
    
    var body: some View {
        Group {
            if testCase != .none && !testCase.isVideoCallTest {
                if stack.initialized {
                    Text("Testing...")
                        .onAppear {
                            startTests()
                        }
                }
                else {
                    setupView()
                }
            }
            else {
                let g = Group {
                    if onlyCall {
                        if stack.initialized {
                            PresentableVideoCallView()
                        }
                        else {
                            setupView()
                        }
                    }
                    else {
                        NavigationView {
                            List {
                                #if HAS_SCION
                                let chatContent = ChatContentView()
                                #if os(macOS)
                                NavigationLink("Text Chat", destination: NavigationView { chatContent })
                                #else
                                NavigationLink("Text Chat", destination: chatContent)
                                #endif
                                #endif
                                
                                NavigationLink("WebRTC Video Call", destination: PresentableVideoCallView(), isActive: $callShown)
                            }
                            .navigationTitle("SCION Demo")
                        }
                    }
                }
                
                #if HAS_SCION
                if onlyCall {
                    g
                }
                else {
                    g.sheet(isPresented: $needsConfig) {
                        setupView()
                    }
                }
                #else
                g
                #endif
            }
        }
    }
}
//
//struct ContentView_Previews: PreviewProvider {
//    static var previews: some View {
//        ContentView()
//    }
//}
