import Combine
import Foundation

extension Publisher {
    public func exhaustMap<Result>(
        taskFactory: ITCTaskFactory = TCTaskFactory(),
        _ transform: @escaping (Output) async -> Result
    ) -> Publishers.ExhaustMap<Self, Result> {
        return Publishers.ExhaustMap(taskFactory: taskFactory, upstream: self, transform: transform)
    }

    public func tryExhaustMap<Result>(
        taskFactory: ITCTaskFactory = TCTaskFactory(),
        _ transform: @escaping (Output) async throws -> Result
    ) -> Publishers.TryExhaustMap<Self, Result> {
        return Publishers.TryExhaustMap(taskFactory: taskFactory, upstream: self, transform: transform)
    }
}

extension Publishers {
    /// A publisher that transforms all elements from the upstream publisher with
    /// a provided closure.
    public struct ExhaustMap<Upstream: Publisher, Output>: Publisher {

        public typealias Failure = Upstream.Failure

        let taskFactory: ITCTaskFactory

        /// The publisher from which this publisher receives elements.
        public let upstream: Upstream

        /// The closure that transforms elements from the upstream publisher.
        public let transform: (Upstream.Output) async -> Output

        public init(taskFactory: ITCTaskFactory,
                    upstream: Upstream,
                    transform: @escaping (Upstream.Output) async -> Output) {
            self.taskFactory = taskFactory
            self.upstream = upstream
            self.transform = transform
        }

        public func receive<Downstream: Subscriber>(subscriber: Downstream)
            where Output == Downstream.Input, Downstream.Failure == Upstream.Failure
        {
//            upstream.subscribe(Inner(downstream: subscriber, map: transform))
        }
    }

    /// A publisher that transforms all elements from the upstream publisher
    /// with a provided error-throwing closure.
    public struct TryExhaustMap<Upstream: Publisher, Output>: Publisher {

        public typealias Failure = Error

        let taskFactory: ITCTaskFactory

        /// The publisher from which this publisher receives elements.
        let upstream: Upstream

        /// The error-throwing closure that transforms elements from
        /// the upstream publisher.
        let transform: (Upstream.Output) async throws -> Output

        public init(taskFactory: ITCTaskFactory,
                    upstream: Upstream,
                    transform: @escaping (Upstream.Output) async throws -> Output) {
            self.taskFactory = taskFactory
            self.upstream = upstream
            self.transform = transform
        }
    }
}

extension Publishers.ExhaustMap {

    public func exhaustMap<Result>(
        _ transform: @escaping (Output) async -> Result
    ) -> Publishers.ExhaustMap<Upstream, Result> {
        return .init(taskFactory: taskFactory, upstream: upstream) { await transform(self.transform($0)) }
    }

    public func tryExhaustMap<Result>(
        taskFactory: ITCTaskFactory = TCTaskFactory(),
        _ transform: @escaping (Output) async throws -> Result
    ) -> Publishers.TryExhaustMap<Upstream, Result> {
        return .init(taskFactory: taskFactory, upstream: upstream) { try await transform(self.transform($0)) }
    }
}

extension Publishers.TryExhaustMap {

    public func receive<Downstream: Subscriber>(subscriber: Downstream)
        where Output == Downstream.Input, Downstream.Failure == Error
    {
        upstream.subscribe(Inner(taskFactory: taskFactory, downstream: subscriber, map: transform))
    }

    @available(macOS 10.15, iOS 13.0, tvOS 13.0, watchOS 6.0, *)
    public func exhaustMap<Result>(
        taskFactory: ITCTaskFactory = TCTaskFactory(),
        _ transform: @escaping (Output) async -> Result
    ) -> Publishers.TryExhaustMap<Upstream, Result> {
        return .init(taskFactory: taskFactory, upstream: upstream) { try await transform(self.transform($0)) }
    }

    @available(macOS 10.15, iOS 13.0, tvOS 13.0, watchOS 6.0, *)
    public func tryExhaustMap<Result>(
        taskFactory: ITCTaskFactory = TCTaskFactory(),
        _ transform: @escaping (Output) async throws -> Result
    ) -> Publishers.TryExhaustMap<Upstream, Result> {
        return .init(taskFactory: taskFactory, upstream: upstream) { try await transform(self.transform($0)) }
    }
}

//extension Publishers.ExhaustMap {
//
//    private struct Inner<Downstream: Subscriber>
//        : Subscriber,
//          CustomStringConvertible,
//          CustomReflectable,
//          CustomPlaygroundDisplayConvertible
//        where Downstream.Input == Output, Downstream.Failure == Upstream.Failure
//    {
//        typealias Input = Upstream.Output
//
//        typealias Failure = Upstream.Failure
//
//        private let downstream: Downstream
//
//        private let map: (Input) async -> Output
//
//        let combineIdentifier = CombineIdentifier()
//
//        fileprivate init(downstream: Downstream, map: @escaping (Input) async -> Output) {
//            self.downstream = downstream
//            self.map = map
//        }
//
//        func receive(subscription: Subscription) {
//            downstream.receive(subscription: subscription)
//        }
//
//        func receive(_ input: Input) -> Subscribers.Demand {
//            return downstream.receive(map(input))
//        }
//
//        func receive(completion: Subscribers.Completion<Failure>) {
//            downstream.receive(completion: completion)
//        }
//
//        var description: String { return "ExhaustMap" }
//
//        var customMirror: Mirror {
//            return Mirror(self, children: EmptyCollection())
//        }
//
//        var playgroundDescription: Any { return description }
//    }
//}

extension Publishers.TryExhaustMap {

    private final class Inner<Downstream: Subscriber>
        : Subscriber,
          Subscription,
          CustomStringConvertible,
          CustomReflectable,
          CustomPlaygroundDisplayConvertible
        where Downstream.Input == Output, Downstream.Failure == Error
    {
        typealias Input = Upstream.Output

        typealias Failure = Upstream.Failure

        private let downstream: Downstream

        private let taskFactory: ITCTaskFactory

        private let map: (Input) async throws -> Output

        /// Subscriber state.
        private enum State {

            // MARK: - Cases

            /// Waiting for subscription
            case waitingForSubscription

            /// Waiting for value request from Swift Concurrency, having subscription.
            case subscribed(with: Subscription)

            /// Waiting for input from Combine, having request from Swift Concurrency.
            case haveDemand(from: Subscription, demand: Subscribers.Demand)

            /// Mapping operation is in progress
            case mapping(from: Subscription, pendingDemand: Subscribers.Demand, mapTask: Task<Void, Never>)

            /// Cancelled from Combine
            case completed
        }

        /// Subscriber event.
        private enum Event {

            // MARK: - Cases

            /// Request for a value from Swift Concurrency, given a completion closure to call with a value or error
            case receiveSubscription(Subscription)
            case requestDemand(Subscribers.Demand)
            case receiveInput(Input)
            case receiveResult(Output)
            case receiveError(Error)
            case cancel
            case receiveCompletion(Subscribers.Completion<Failure>)
        }

        /// Action description. Instead of doing stuff directly, we return descriptions which will be called when state lock is released.
        /// That makes logic more readable.
        private enum Action {

            // MARK: - Cases

            case sendSubscription

            case sendValue(Output)

            case sendError(Error)

            case sendCompletion(Subscribers.Completion<Upstream.Failure>)

            case cancel(Subscription)

            case requestValue(Subscription)
        }

        private let lock = NSLock()

        private var state: State = .waitingForSubscription

        let combineIdentifier = CombineIdentifier()

        fileprivate init(taskFactory: ITCTaskFactory,
                         downstream: Downstream,
                         map: @escaping (Input) async throws -> Output) {
            self.downstream = downstream
            self.taskFactory = taskFactory
            self.map = map
        }

        func receive(subscription: Subscription) {
            handle(event: .receiveSubscription(subscription))
        }

        func receive(_ input: Input) -> Subscribers.Demand {
            handle(event: .receiveInput(input))

            return .none
        }

        func receive(completion: Subscribers.Completion<Failure>) {
            handle(event: .receiveCompletion(completion))
        }

        func request(_ demand: Subscribers.Demand) {
            handle(event: .requestDemand(demand))
        }

        func cancel() {
            handle(event: .cancel)
        }

        var description: String { return "TryExhaustMap" }

        var customMirror: Mirror {
            return Mirror(self, children: EmptyCollection())
        }

        var playgroundDescription: Any { return description }


        // MARK: - Private Methods

        private func handle(event: Event) {
            let oldState = state

            let actions = process(event: event)

            Swift.print("\(event): \(oldState) -> \(state): \(actions)")

            for action in actions {
                switch action {
                case .sendSubscription:
                    downstream.receive(subscription: self)

                case let .sendValue(value):
                    let demand = downstream.receive(value)
                    if demand != .none {
                        handle(event: .requestDemand(demand))
                    }

                case let .sendCompletion(completion):
                    switch completion {
                    case .finished:
                        downstream.receive(completion: .finished)

                    case let .failure(error):
                        downstream.receive(completion: .failure(error))
                    }

                case let .cancel(subscription):
                    subscription.cancel()

                case let .sendError(error):
                    downstream.receive(completion: .failure(error))

                case let .requestValue(subscription):
                    subscription.request(.max(1))
                }
            }
        }

        // swiftlint:disable:next cyclomatic_complexity
        private func process(event: Event) -> [Action] {
            defer { lock.unlock() }

            lock.lock()

            switch state {
            case .waitingForSubscription:
                switch event {
                case let .receiveSubscription(subscription):
                    state = .subscribed(with: subscription)

                    return [.sendSubscription]

                case .cancel:
                    state = .completed
                    return []

                default:
                    return []
                }

            case let .subscribed(with: subscription):
                switch event {
                case .cancel:
                    state = .completed

                    return [.cancel(subscription)]

                case let .receiveCompletion(completion):
                    state = .completed

                    return [.sendCompletion(completion)]

                case let .requestDemand(demand):
                    state = .haveDemand(from: subscription, demand: demand)

                    return [.requestValue(subscription)]

                default:
                    return []
                }

            case let .haveDemand(from: subscription, demand: demand):
                switch event {
                case .cancel:
                    state = .completed
                    return [.cancel(subscription)]

                case let .receiveCompletion(completion):
                    state = .completed

                    return [.sendCompletion(completion)]

                case let .requestDemand(newDemand):
                    state = .haveDemand(from: subscription, demand: demand + newDemand)

                    return []

                case let .receiveInput(input):
                    state = .mapping(from: subscription, pendingDemand: demand, mapTask: createMapTask(value: input))

                    return []
                default:
                    return []
                }

            case let .mapping(from: subscription, pendingDemand: pendingDemand, mapTask: mapTask):
                switch event {
                case .cancel:
                    mapTask.cancel()
                    state = .completed

                    return [.cancel(subscription)]

                case let .receiveCompletion(completion):
                    mapTask.cancel()
                    state = .completed

                    return [.sendCompletion(completion)]

                case let .requestDemand(newDemand):
                    state = .mapping(from: subscription, pendingDemand: pendingDemand + newDemand, mapTask: mapTask)

                    return []

                case let .receiveResult(result):
                    let newDemand = pendingDemand - 1
                    if newDemand != .none {
                        state = .haveDemand(from: subscription, demand: newDemand)
                        return [.sendValue(result), .requestValue(subscription)]
                    } else {
                        return [.sendValue(result)]
                    }

                case let .receiveError(error):
                    state = .completed

                    return [.cancel(subscription), .sendError(error)]

                default:
                    return []
                }
            case .completed:
                return []
            }
        }

        private func createMapTask(value: Input) -> Task<Void, Never> {
            taskFactory.detached { [weak self, map] in
                do {
                    let result = try await map(value)

                    self?.handle(event: .receiveResult(result))
                } catch {
                    self?.handle(event: .receiveError(error))
                }
            }
        }
    }
}
