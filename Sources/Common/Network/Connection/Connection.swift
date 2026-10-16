//
//  Copyright (c) 2020-2021 MobileCoin. All rights reserved.
//

import Foundation

class Connection<GrpcService: ConnectionProtocol, HttpService: ConnectionProtocol> {
    // fire: a read-write lock rather than `SerialDispatchLock`. Every call reads the current
    // wrapper, and an error rotates it, so a read without the lock raced the swap that released
    // the old service: the reader retained an object already being deallocated, which crashed in
    // `FogViewGrpcConnection`'s deinit or later inside its `SerialCallbackLock`.
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
        let inner = Inner(
            connectionOptionWrapper: connectionOptionWrapper,
            transportProtocolOption: transportProtocolOption)
        self.inner = .init(inner)
    }

    func rotateConnection() {
        let factory = connectionOptionWrapperFactory
        inner.writeSync { $0.connectionOptionWrapper = factory($0.transportProtocolOption) }
    }

    func setTransportProtocolOption(_ transportProtocolOption: TransportProtocol.Option) {
        let factory = connectionOptionWrapperFactory
        inner.writeSync {
            $0.transportProtocolOption = transportProtocolOption
            $0.connectionOptionWrapper = factory(transportProtocolOption)
        }
    }

    func setAuthorization(credentials: BasicCredentials) {
        inner.writeSync { $0.setAuthorization(credentials: credentials) }
    }

    var connectionOptionWrapper: ConnectionOptionWrapper<GrpcService, HttpService> {
        inner.readSync { $0.connectionOptionWrapper }
    }

    func rotateURLOnError<T>(
        _ completion: @escaping (Result<T, ConnectionError>) -> Void
    ) -> (Result<T, ConnectionError>) -> Void {
        { [weak self] result in
            switch result {
            case .success:
                completion(result)
            case .failure:
                logger.debug("rotating config on error")
                completion(result)
                self?.rotateConnection()
            }
        }
    }

}

extension Connection {
    private struct Inner {
        var connectionOptionWrapper: ConnectionOptionWrapper<GrpcService, HttpService> {
            didSet {
                if let credentials = authorizationCredentials {
                    switch connectionOptionWrapper {
                    case .grpc(grpcService: let grpcService):
                        grpcService.setAuthorization(credentials: credentials)
                    case .http(httpService: let httpService):
                        httpService.setAuthorization(credentials: credentials)
                    }
                }
            }
        }

        var transportProtocolOption: TransportProtocol.Option

        private var authorizationCredentials: BasicCredentials?

        init(
            connectionOptionWrapper: ConnectionOptionWrapper<GrpcService, HttpService>,
            transportProtocolOption: TransportProtocol.Option
        ) {
            self.connectionOptionWrapper = connectionOptionWrapper
            self.transportProtocolOption = transportProtocolOption
        }

        mutating func setAuthorization(credentials: BasicCredentials) {
            self.authorizationCredentials = credentials
            switch connectionOptionWrapper {
            case .grpc(grpcService: let grpcService):
                grpcService.setAuthorization(credentials: credentials)
            case .http(httpService: let httpService):
                httpService.setAuthorization(credentials: credentials)
            }
        }
    }
}
