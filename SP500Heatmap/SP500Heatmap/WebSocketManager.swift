import Foundation

class WebSocketManager: ObservableObject {
    static let shared = WebSocketManager()
    
    private var webSocketTask: URLSessionWebSocketTask?
    private let websocketURL: String
    
    @Published var priceUpdates: [String: (price: Double, changePercent: Double)] = [:]
    
    private init() {
        self.websocketURL = Config.websocketURL
    }
    
    func connect() {
        guard let url = URL(string: websocketURL) else { return }
        
        let session = URLSession(configuration: .default)
        webSocketTask = session.webSocketTask(with: url)
        webSocketTask?.resume()
        
        receiveMessages()
    }
    
    func disconnect() {
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
    }
    
    private func receiveMessages() {
        webSocketTask?.receive { [weak self] result in
            switch result {
            case .success(let message):
                switch message {
                case .string(let text):
                    self?.processMessage(text)
                default:
                    break
                }
                self?.receiveMessages()
            case .failure(let error):
                print("WebSocket error: \(error)")
                DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                    self?.connect()
                }
            }
        }
    }
    
    private func processMessage(_ text: String) {
        guard let data = text.data(using: .utf8) else { return }
        
        do {
            let updates = try JSONDecoder().decode([PriceUpdate].self, from: data)
            DispatchQueue.main.async {
                for update in updates {
                    self.priceUpdates[update.ticker] = (update.price, update.changePercent)
                }
            }
        } catch {
            print("Decoding error: \(error)")
        }
    }
}

struct PriceUpdate: Codable {
    let ticker: String
    let price: Double
    let changePercent: Double
    
    enum CodingKeys: String, CodingKey {
        case ticker = "t"
        case price = "p"
        case changePercent = "c"
    }
}
