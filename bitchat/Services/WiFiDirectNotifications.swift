import Foundation

enum WiFiDirectNotificationUserInfoKey {
    static let envelope = "envelope"
}

extension Notification.Name {
    static let wifiDirectPrivateEnvelopeReceived = Notification.Name("WiFiDirectPrivateEnvelopeReceived")
}
