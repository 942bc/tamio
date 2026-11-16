//
//  TerminalManager+Context.swift
//  Tamio (macOS)
//
//  The session core lives in TamioModule.TerminalContext; this shell keeps
//  the platform surface (TamioTerminalView) the core drives.
//

import Combine
import Foundation
import TamioModule
import TamioTerminal

/// Bridges the shared terminal session core to the platform renderer.
final class TerminalSurfaceBridge: TerminalSessionSurface {
    let termInterface: TamioTerminalView

    init(localShell: Bool = false) {
        termInterface = TamioTerminalView(localShell: localShell)
    }

    func write(_ string: String) {
        termInterface.write(string)
    }

    func setupBellChain(_ callback: @escaping () -> Void) {
        termInterface.setupBellChain(callback: callback)
    }

    func setupBufferChain(_ callback: @escaping (String) -> Void) {
        termInterface.setupBufferChain(callback: callback)
    }

    func setupTitleChain(_ callback: @escaping (String) -> Void) {
        termInterface.setupTitleChain(callback: callback)
    }

    func setupSizeChain(_ callback: @escaping (CGSize) -> Void) {
        termInterface.setupSizeChain(callback: callback)
    }

    func setupCloseChain(_ callback: @escaping () -> Void) {
        termInterface.setupCloseChain(callback: callback)
    }
}

extension TerminalManager {
    final class Context: TamioModule.TerminalContext {
        private let surfaceBridge: TerminalSurfaceBridge
        var termInterface: TamioTerminalView { surfaceBridge.termInterface }
        /// A name the user gave this local tab; nil keeps the default
        /// “This Mac”/“This Mac 2” title.
        @Published var customTitle: String? = nil

        init(machine: RDMachine) {
            surfaceBridge = TerminalSurfaceBridge()
            super.init(machine: machine, surface: surfaceBridge)
        }

        init(command: SSHCommandReader) {
            surfaceBridge = TerminalSurfaceBridge()
            super.init(command: command, surface: surfaceBridge)
        }

        /// A shell on this Mac.
        init(localShell: Void) {
            surfaceBridge = TerminalSurfaceBridge(localShell: true)
            super.init(localSurface: surfaceBridge)
        }
    }
}
