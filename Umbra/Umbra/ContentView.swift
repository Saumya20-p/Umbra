import SwiftUI
import Combine
import NetworkExtension
import UIKit

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var protection = ProtectionController()
    private let blocklist = try? BundledBlocklist.load()

    var body: some View {
        NavigationStack {
            Form {
                Section("Local tunnel experiment") {
                    LabeledContent("Tunnel", value: protection.statusText)
                        .accessibilityIdentifier("tunnelStatus")
                    LabeledContent("Automatic reconnection", value: protection.automaticReconnect.map { $0 ? "On" : "Off" } ?? "Unverified")
                    Text(protection.filteringDescription)
                    if ProtectionController.requiresDevice {
                        Text("A signed physical iPhone is required. The Simulator cannot activate this experiment.")
                            .accessibilityIdentifier("deviceRequired")
                    }
                    if protection.hasConfiguration {
                        Button("Enable experiment") {
                            Task { await protection.enable() }
                        }
                        .disabled(!protection.canEnable)
                    } else {
                        Button("Install experimental configuration") {
                            Task { await protection.install() }
                        }
                        .disabled(ProtectionController.requiresDevice || protection.isBusy || protection.isRefreshing || protection.isProbing)
                    }
                    Button("Disable experiment", role: .destructive) {
                        Task { await protection.disable() }
                    }
                    .disabled(!protection.canDisable)
                    if protection.isBusy {
                        ProgressView("Updating configuration…")
                    }
                    if let error = protection.actionError {
                        Text(error)
                            .foregroundStyle(.red)
                    }
                }
                Section("Diagnostics") {
                    LabeledContent("Blocked today", value: protection.blockedToday.map { $0.formatted() } ?? "Unavailable")
                        .accessibilityIdentifier("blockedToday")
                    Text("Counts requests denied locally, including resolver-discovery requests, not unique ads. Refresh to read the current daily total.")
                        .font(.footnote)
                    LabeledContent("Engine report", value: protection.engineStatusText)
                    if let details = protection.recoveryDetails {
                        Text(details)
                            .font(.footnote)
                            .textSelection(.enabled)
                    }
                    if let failure = protection.failureDescription {
                        Text(failure)
                    }
                    if let diagnosticError = protection.diagnosticError {
                        Text(diagnosticError)
                            .font(.footnote)
                    }
                    if let counterError = protection.counterError {
                        Text(counterError)
                            .font(.footnote)
                    }
                    Button("Refresh diagnostics") {
                        Task { await protection.refresh() }
                    }
                    .disabled(protection.isBusy || protection.isRefreshing)
                }
                Section("Bundled candidate") {
                    if let blocklist {
                        LabeledContent("List", value: blocklist.name)
                        LabeledContent("Revision", value: String(blocklist.revision.prefix(12)))
                        Link("Pinned list source", destination: blocklist.source)
                        NavigationLink("List license (\(blocklist.license))") {
                            ScrollView {
                                Text((try? BundledBlocklist.licenseText()) ?? "License unavailable")
                                    .font(.caption)
                                    .textSelection(.enabled)
                                    .padding()
                            }
                            .navigationTitle("Blocklist license")
                        }
                    } else { Text("Bundled list information unavailable") }
                    Text("Evaluation only. Public distribution is unresolved. Restart the experiment after installing an updated build. List updates arrive with app builds.")
                        .font(.footnote)
                }
                Section("DNS path check") {
                    Text("Checks Google/Unity advertising hosts and example.com A/AAAA through the system resolver and, while running, direct IPv4/IPv6 UDP and selected TCP paths. Real probe denials count toward Blocked today. Results stay in memory.")
                        .font(.footnote)
                    Button("Run DNS path check") {
                        Task { await protection.runDNSProbe() }
                    }
                    .accessibilityIdentifier("runDNSProbe")
                    .disabled(ProtectionController.requiresDevice || protection.isBusy || protection.isRefreshing || protection.isProbing)
                    Button("Run extended transport check") {
                        Task { await protection.runDNSProbe(extended: true) }
                    }
                    .accessibilityIdentifier("runExtendedProbe")
                    .disabled(ProtectionController.requiresDevice || protection.status != .connected || protection.isBusy || protection.isRefreshing || protection.isProbing)
                    Text("Extended check requests fixed org DNSKEY answers with EDNS/DNSSEC and TCP comparison. It measures replies, not IPv6-only/NAT64 compatibility.")
                        .font(.footnote)
                    if protection.isProbing { ProgressView("Checking DNS paths…") }
                    if !protection.probeReport.isEmpty {
                        Text(protection.probeReport)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                            .accessibilityIdentifier("dnsProbeReport")
                        ShareLink("Share diagnostic result", item: protection.probeReport)
                    }
                }
                #if DEBUG
                Section("DEBUG failure validation") {
                    Text("These controls intentionally interrupt filtering. Existing stored totals are preserved. Faults are held in memory for this provider session only; none are enabled automatically.")
                        .font(.footnote)
                    Button("Enable with unavailable encrypted upstream") {
                        Task { await protection.enableUnavailableUpstream() }
                    }
                    .disabled(!protection.canEnable)
                    Button("Fail next counter write") {
                        Task { await protection.armCounterWriteFailure() }
                    }
                    .disabled(ProtectionController.requiresDevice || protection.status != .connected || protection.isBusy || protection.isRefreshing || protection.isProbing)
                    if let mode = protection.snapshot?.validationMode { Text(mode) }
                    if let message = protection.validationMessage { Text(message) }
                }
                #endif
                Section("Feasibility only") {
                    Text("Packet-tunnel DNS interception is an unsupported Apple use case. Apple support, distribution eligibility, filtering coverage, performance and battery use remain unproven.")
                    Text("Permitted DNS lookups go to Quad9 over an encrypted connection. Quad9 can see those queries. Umbra retains daily totals without domain or browsing histories.")
                    Text("If the encrypted upstream fails, Umbra stops filtering and restores ordinary system DNS, which may be unencrypted.")
                    Text("To recover manually, disconnect Umbra in Settings → VPN. Another VPN may replace this experiment or conflict with it.")
                }
                .font(.footnote)
            }
            .navigationTitle("Umbra")
            .task { await protection.refresh() }
            .onChange(of: scenePhase) {
                if scenePhase == .active {
                    Task { await protection.refresh() }
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .NEVPNStatusDidChange)) { _ in
                protection.connectionDidChange()
            }
            .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged)
                .merge(with: NotificationCenter.default.publisher(for: UIApplication.significantTimeChangeNotification))) { _ in
                Task { await protection.refreshDailyTotal() }
            }
        }
    }
}

#Preview {
    ContentView()
}
