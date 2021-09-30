//
//  SCIONSetupView.swift
//  SCIONTest
//  Copyright Jonas Gessner
//  Created by Jonas Gessner on 20.05.21.
//

import SwiftUI

struct ScionASView: View {
    @Binding var brIP: String
    let topo: TopologyTemplate
    let checked: Bool
    
    var body: some View {
        HStack {
            Text(topo.name)
            Spacer()
            TextField("Border Router", text: $brIP)
            if checked {
                Image(systemName: "checkmark")
            }
            else {
                Image(systemName: "checkmark").hidden()
            }
        }
    }
}

struct SCIONSetupView: View {
    @State var selectedIndex = defaultAS.rawValue
    
    @State var model = defaultScionSetupModel
    
    var onCommit: (String, TopologyTemplate) -> Void
    
    private func commit() {
        onCommit(model[selectedIndex].1, model[selectedIndex].0)
    }
    
    var body: some View {
        let components = model[selectedIndex].1.components(separatedBy: ".")
        
        let allowSetup: Bool
        
        if components.count != 4 {
            allowSetup = false
        }
        else {
            allowSetup = components.allSatisfy({ $0.count <= 3 && UInt($0).map({ $0 < Int(UInt8.max) }) ?? false })
        }
        
        let commitButton = Button("Done") {
            commit()
        }
        .disabled(!allowSetup)
        
        let form = Form {
            #if os(macOS)
            Text("Select AS and Border Router").font(.headline)
            #endif
            
            ForEach(0..<model.count) { index in
                ScionASView(brIP: $model[index].1, topo: model[index].0, checked: index == selectedIndex)
                    .onTapGesture {
                        selectedIndex = index
                    }
            }
            
            #if os(macOS)
            commitButton
            #endif
        }
        .onAppear {
            if autoConnectSCION {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) {
                    commit()
                }
            }
        }
        
        #if os(macOS)
        return form.padding()
        #else
        return NavigationView {
            form
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        commitButton
                    }
                }
                .navigationTitle("Set Up SCION")
        }
        #endif
    }
}
