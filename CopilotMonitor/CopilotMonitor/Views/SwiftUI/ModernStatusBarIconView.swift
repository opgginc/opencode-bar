import SwiftUI

struct ModernStatusBarIconView: View {
    @Environment(\.colorScheme) var colorScheme
    @ObservedObject var viewModel: StatusBarViewModel
    
    private var textColor: Color {
        colorScheme == .dark ? .white : .black
    }
    
    var body: some View {
        HStack(spacing: 2) {
            if viewModel.isMultiProviderMode {
                multiProviderContent
            } else {
                singleProviderContent
            }
        }
    }
    
    @ViewBuilder
    private var singleProviderContent: some View {
        Image(systemName: "gauge.medium")
            .font(.system(size: 14))
            .foregroundColor(textColor)
        
        CircularProgressView(
            progress: viewModel.percentage / 100,
            isLoading: viewModel.isLoading,
            hasError: viewModel.hasError
        )
        .frame(width: 8, height: 8)
        
        Text(viewModel.usageText)
            .font(.system(size: 11, weight: .medium, design: .monospaced))
            .foregroundColor(textColor)
    }
    
    @ViewBuilder
    private var multiProviderContent: some View {
        Text("$")
            .font(.system(size: 14, weight: .bold))
            .foregroundColor(textColor)
        
        Text(viewModel.costText)
            .font(.system(size: 11, weight: .semibold, design: .monospaced))
            .foregroundColor(textColor)
        
        ForEach(Array(viewModel.alerts.enumerated()), id: \.offset) { _, alert in
            SwiftUIProviderAlertView(alert: alert)
        }
    }
}

struct CircularProgressView: View {
    let progress: Double
    let isLoading: Bool
    let hasError: Bool
    
    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.primary.opacity(0.2), lineWidth: 2)
            
            Circle()
                .trim(from: 0, to: isLoading ? 0.25 : (hasError ? 0.25 : progress))
                .stroke(Color.primary, lineWidth: 2)
                .rotationEffect(.degrees(-90))
        }
    }
}

struct SwiftUIProviderAlertView: View {
    let alert: ProviderAlert
    
    var body: some View {
        HStack(spacing: 2) {
            Image(systemName: iconName(for: alert.identifier))
                .font(.system(size: 12))
                .foregroundColor(.red)
            
            Text(String(format: "%.0f%%", alert.remainingPercent))
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundColor(.primary)
        }
    }
    
    private func iconName(for identifier: ProviderIdentifier) -> String {
        switch identifier {
        case .claude: return "brain"
        case .codex: return "terminal"
        case .geminiCLI: return "sparkles"
        case .copilot: return "airplane"
        case .openRouter: return "dollarsign.circle"
        case .openCode, .openCodeZen: return "chevron.left.forwardslash.chevron.right"
        case .antigravity: return "arrow.up.circle"
        case .kimi: return "k.circle"
        }
    }
}

class StatusBarViewModel: ObservableObject {
    @Published var isMultiProviderMode: Bool = false
    @Published var isLoading: Bool = false
    @Published var hasError: Bool = false
    
    @Published var percentage: Double = 0
    @Published var usedCount: Int = 0
    @Published var addOnCost: Double = 0
    
    @Published var totalCost: Double = 0
    @Published var alerts: [ProviderAlert] = []
    
    var usageText: String {
        if isLoading { return "..." }
        if hasError { return "Err" }
        return "\(usedCount)"
    }
    
    var costText: String {
        if isLoading { return "..." }
        if hasError { return "Err" }
        if totalCost >= 10 {
            return String(format: "%.1f", totalCost)
        } else if totalCost > 0 {
            return String(format: "%.2f", totalCost)
        }
        return "0"
    }
}

#Preview {
    let viewModel = StatusBarViewModel()
    viewModel.usedCount = 42
    viewModel.percentage = 65
    return ModernStatusBarIconView(viewModel: viewModel)
        .padding()
}
