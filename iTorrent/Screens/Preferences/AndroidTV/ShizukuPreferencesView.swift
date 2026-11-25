//
//  ShizukuPreferencesView.swift
//  iTorrent
//
//  Starts Shizuku on an Android TV on the same Wi-Fi, over network ADB.
//  Shizuku stops on every reboot of the TV and can only be started from an
//  ADB shell, so this replaces running adb from a computer.
//

import MvvmFoundation
import SwiftUI

class ShizukuPreferencesViewModel: BaseViewModel, ObservableObject, @unchecked Sendable {
    enum State: Equatable {
        case idle
        case working(String)
        case running
        case notRunning
        case failed(String)
    }

    @Published var address: String
    @Published var state: State = .idle
    @Published var output: String = ""

    var isWorking: Bool {
        if case .working = state { return true }
        return false
    }

    required init() {
        address = UserDefaults.standard.string(forKey: Self.addressKey) ?? ""
        super.init()
    }

    func start() {
        run(startShizuku: true)
    }

    func check() {
        run(startShizuku: false)
    }

    private static let addressKey = "shizukuTvAddress"
    private static let startScript = "sh /data/local/tmp/start-shizuku.sh"
    // Same as the script, in case /data/local/tmp was wiped.
    private static let startInline = #"d=$(dirname $(pm path moe.shizuku.privileged.api | sed "s/package://")); for l in $d/lib/*/libshizuku.so; do $l; break; done"#
    private static let checkCommand = "ps -A | grep -c shizuku_server"
}

private extension ShizukuPreferencesViewModel {
    func run(startShizuku: Bool) {
        guard !isWorking else { return }
        let trimmed = address.trimmingCharacters(in: .whitespaces)
        guard let (host, port) = Self.parse(trimmed) else {
            state = .failed(String(localized: "shizuku.error.address", defaultValue: "Enter the TV's IP address, for example 192.168.1.105"))
            return
        }
        address = trimmed
        UserDefaults.standard.set(trimmed, forKey: Self.addressKey)
        output = ""
        state = .working(String(localized: "shizuku.status.connecting", defaultValue: "Connecting…"))

        Task {
            let client = AdbClient(host: host, port: port)
            client.onStatus = { [weak self] status in
                DispatchQueue.main.async {
                    guard let self, self.isWorking else { return }
                    switch status {
                    case .connecting:
                        self.state = .working(String(localized: "shizuku.status.connecting", defaultValue: "Connecting…"))
                    case .waitingForApproval:
                        self.state = .working(String(localized: "shizuku.status.approve", defaultValue: "Accept the prompt on the TV (tick \"Always allow\")…"))
                    case .connected:
                        self.state = .working(startShizuku
                            ? String(localized: "shizuku.status.starting", defaultValue: "Starting Shizuku…")
                            : String(localized: "shizuku.status.checking", defaultValue: "Checking…"))
                    }
                }
            }
            defer { client.close() }

            do {
                try await client.connect()

                if startShizuku {
                    var log = try await client.shell(Self.startScript)
                    if !log.contains("shizuku_starter exit with 0"), Self.isMissingScript(log) {
                        log += try await client.shell(Self.startInline)
                    }
                    output = log.trimmingCharacters(in: .whitespacesAndNewlines)
                    try await Task.sleep(nanoseconds: 2_000_000_000)
                }

                let count = try await client.shell(Self.checkCommand)
                let running = (Int(count.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0) > 0
                state = running ? .running : .notRunning
            } catch {
                state = .failed(error.localizedDescription)
            }
        }
    }

    static func isMissingScript(_ output: String) -> Bool {
        let lowercased = output.lowercased()
        return lowercased.contains("no such file") || lowercased.contains("can't open") || lowercased.contains("not found")
    }

    static func parse(_ address: String) -> (String, UInt16)? {
        guard !address.isEmpty else { return nil }
        let parts = address.split(separator: ":")
        switch parts.count {
        case 1:
            return (address, 5555)
        case 2:
            guard let port = UInt16(parts[1]) else { return nil }
            return (String(parts[0]), port)
        default:
            return nil
        }
    }
}

struct ShizukuPreferencesView<VM: ShizukuPreferencesViewModel>: MvvmSwiftUIViewProtocol {
    @ObservedObject var viewModel: VM
    var title: String = String(localized: "shizuku.title", defaultValue: "Android TV (Shizuku)")

    init(viewModel: VM) {
        self.viewModel = viewModel
    }

    var body: some View {
        List {
            Section {
                TextField(String(localized: "shizuku.address.placeholder", defaultValue: "TV IP address, e.g. 192.168.1.105"), text: $viewModel.address)
                    .keyboardType(.numbersAndPunctuation)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.go)
                    .onSubmit { viewModel.start() }
            } header: {
                Text(verbatim: String(localized: "shizuku.address.header", defaultValue: "TV"))
            } footer: {
                Text(verbatim: String(localized: "shizuku.address.footer", defaultValue: "Network ADB must be on (port 5555). Shizuku stops every time the TV restarts; start it again here."))
            }

            Section {
                Button {
                    viewModel.start()
                } label: {
                    Text(verbatim: String(localized: "shizuku.start", defaultValue: "Start Shizuku"))
                }
                Button {
                    viewModel.check()
                } label: {
                    Text(verbatim: String(localized: "shizuku.check", defaultValue: "Check Status"))
                }
            }
            .disabled(viewModel.isWorking)

            if viewModel.state != .idle {
                Section {
                    statusRow
                }
            }

            if !viewModel.output.isEmpty {
                Section {
                    Text(verbatim: viewModel.output)
                        .font(.system(.footnote, design: .monospaced))
                        .textSelection(.enabled)
                } header: {
                    Text(verbatim: String(localized: "shizuku.output", defaultValue: "Output"))
                }
            }
        }
    }

    @ViewBuilder
    private var statusRow: some View {
        switch viewModel.state {
        case .idle:
            EmptyView()
        case let .working(text):
            HStack(spacing: 12) {
                ProgressView()
                Text(verbatim: text)
            }
        case .running:
            Label {
                Text(verbatim: String(localized: "shizuku.status.running", defaultValue: "Shizuku is running"))
            } icon: {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            }
        case .notRunning:
            Label {
                Text(verbatim: String(localized: "shizuku.status.notRunning", defaultValue: "Shizuku is not running"))
            } icon: {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.orange)
            }
        case let .failed(text):
            Label {
                Text(verbatim: text)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
            }
        }
    }
}
