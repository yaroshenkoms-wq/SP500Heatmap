import SwiftUI

struct PeriodSwitchView: View {
    @Binding var selectedPeriod: String
    let periods = ["SC", "1d", "3d", "7d", "30d", "180d", "1y"]
    
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                ForEach(periods, id: \.self) { period in
                    Button(action: {
                        selectedPeriod = period
                    }) {
                        Text(period)
                            .font(.caption)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(selectedPeriod == period ? Color.blue : Color.gray.opacity(0.3))
                            .foregroundColor(selectedPeriod == period ? .white : .primary)
                            .cornerRadius(8)
                    }
                }
            }
            .padding(.horizontal)
        }
        .frame(height: 44)
    }
}
