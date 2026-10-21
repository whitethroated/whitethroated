import Crypto
import Foundation

enum SHA256Hex {
    static func encode(
        _ bytes: [UInt8]
    ) -> String {
        let digest =
            Array(
                SHA256.hash(
                    data: Data(bytes)
                )
            )

        var output =
            String()
        output.reserveCapacity(
            digest.count * 2
        )

        for byte in digest {
            output += String(
                format: "%02x",
                Int(byte)
            )
        }

        return output
    }
}
