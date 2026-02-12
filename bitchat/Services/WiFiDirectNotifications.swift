import Foundation

enum WiFiDirectNotificationUserInfoKey {
    static let envelope = "envelope"
    static let ackEnvelope = "ackEnvelope"
}

extension Notification.Name {
    static let wifiDirectPrivateEnvelopeReceived = Notification.Name("WiFiDirectPrivateEnvelopeReceived")
    static let wifiDirectAckEnvelopeReceived = Notification.Name("WiFiDirectAckEnvelopeReceived")
}
