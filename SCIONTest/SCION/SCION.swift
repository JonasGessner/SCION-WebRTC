//
//  SCION.swift
//  SCIONTest
//  Copyright Jonas Gessner
//  Created by Jonas Gessner on 27.02.21.
//

import Foundation

// Normally SCION would be a separate framework, but with its weird gomobile dependencies the gomobile dependencies have to be linked directly to the application. If the gomobile lib is linked to a framework/static lib dependency there are always tons of error produced when then linking that framework/static lib to an application.
enum SCIONError: LocalizedError {
    case general
    case noPathsFound
    
    var errorDescription: String? {
        switch self {
        case .general:
            return "General error"
        case .noPathsFound:
            return "Could not find any paths to destination"
        }
    }
}

// General note: When using macOS system firewall the underlay port may not be released when the process terminates. It seems like an OS bug. https://github.com/ethereum/go-ethereum/issues/18443
