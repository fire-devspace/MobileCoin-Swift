//
//  Copyright (c) 2020-2021 MobileCoin. All rights reserved.
//

import Foundation

class ArbitraryConnection<GrpcService, HttpService> {
    // fire: a read-write lock for the same reason as `Connection`'s: an unlocked read of the
    // wrapper raced the swap that released the old service.
    private let inner: ReadWriteDispatchLock<Inner>

    private let connectionOptionWrapperFactory: (TransportProtocol.Option)
        -> ConnectionOptionWrapper<GrpcService, HttpService>

    init(
        connectionOptionWrapperFactory: @escaping (TransportProtocol.Option)
            -> ConnectionOptionWrapper<GrpcService, HttpService>,
        transportProtocolOption: TransportProtocol.Option,
        targetQueue: DispatchQueue?
    ) {
        self.connectionOptionWrapperFactory = connectionOptionWrapperFactory
        let connectionOptionWrapper = connectionOptionWrapperFactory(transportProtocolOption)
        let inner = Inner(connectionOptionWrapper: connectionOptionWrapper)
        self.inner = .init(inner)
    }

    func setTransportProtocolOption(_ transportProtocolOption: TransportProtocol.Option) {
        let connectionOptionWrapper = connectionOptionWrapperFactory(transportProtocolOption)
        inner.writeSync { $0.connectionOptionWrapper = connectionOptionWrapper }
    }

    var connectionOptionWrapper: ConnectionOptionWrapper<GrpcService, HttpService> {
        inner.readSync { $0.connectionOptionWrapper }
    }
}

extension ArbitraryConnection {
    private struct Inner {
        var connectionOptionWrapper: ConnectionOptionWrapper<GrpcService, HttpService>

        init(connectionOptionWrapper: ConnectionOptionWrapper<GrpcService, HttpService>) {
            self.connectionOptionWrapper = connectionOptionWrapper
        }
    }
}
