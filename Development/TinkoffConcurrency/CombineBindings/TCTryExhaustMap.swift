import Combine
import Foundation

extension Publisher {
    public func tryExhaustMap<Result>(
        taskFactory: ITCTaskFactory = TCTaskFactory(),
        _ transform: @escaping (Output) async throws -> Result
    ) -> Publishers.TryExhaustMap<Self, Result> {
        return Publishers.TryExhaustMap(taskFactory: taskFactory, upstream: self, transform: transform)
    }
}

extension Publishers {
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
                    transform: @escaping (Upstream.Output) async throws -> Output)
        {
            self.taskFactory = taskFactory
            self.upstream = upstream
            self.transform = transform
        }
    }
}

extension Publishers.TryExhaustMap {

    public func receive<Downstream: Subscriber>(subscriber: Downstream)
        where Output == Downstream.Input, Downstream.Failure == Error
    {
        upstream.subscribe(Inner(taskFactory: taskFactory, downstream: subscriber, map: transform))
    }

    @available(macOS 10.15, iOS 13.0, tvOS 13.0, watchOS 6.0, *)
    public func exhaustMap<Result, Context: Scheduler>(
        taskFactory: ITCTaskFactory = TCTaskFactory(),
        scheduler: Context,
        _ transform: @escaping (Output) async -> Result
    ) -> Publishers.TryExhaustMap<Upstream, Result> {
        return .init(taskFactory: taskFactory, upstream: upstream) { try await transform(self.transform($0)) }
    }

    @available(macOS 10.15, iOS 13.0, tvOS 13.0, watchOS 6.0, *)
    public func tryExhaustMap<Result, Context: Scheduler>(
        taskFactory: ITCTaskFactory = TCTaskFactory(),
        scheduler: Context,
        _ transform: @escaping (Output) async throws -> Result
    ) -> Publishers.TryExhaustMap<Upstream, Result> {
        return .init(taskFactory: taskFactory, upstream: upstream) { try await transform(self.transform($0)) }
    }
}

extension Publishers.TryExhaustMap {

    fileprivate final class Inner<Downstream: Subscriber>
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
        fileprivate enum State {

            // MARK: - Cases

            /// Waiting for subscription
            case waitingForSubscription

            /// Waiting for value request from Swift Concurrency, having subscription.
            case subscribed(with: Subscription)

            /// Waiting for input from Combine, having request from Swift Concurrency.
            case haveDemand(from: Subscription, demand: Subscribers.Demand)

            /// Mapping operation is in progress
            case mapping(from: Subscription, pendingDemand: Subscribers.Demand, mapTask: Task<Void, Never>)

            /// Completion received during mapping
            case finishing(from: Subscription, mapTask: Task<Void, Never>, pendingCompletion: Subscribers.Completion<Failure>)

            /// Cancelled from Combine
            case completed
        }

        /// Subscriber event.
        fileprivate enum Event {

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
        fileprivate enum Action {

            // MARK: - Cases

            case none

            case sendSubscription

            case requestValue(Subscription)

            case sendValue(Output)

            case sendError(Error)

            case sendCompletion(Subscribers.Completion<Upstream.Failure>)

            case sendLastValue(Output, Subscribers.Completion<Upstream.Failure>)

            case sendAndRequest(Output, Subscription)

            case cancel(Subscription)

            case cancelSendingError(Subscription, Error)
        }

        private let lock = NSLock()

        private var state: State = .waitingForSubscription

        private var lastTask: Task<Void, Never>?

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
            lock.lock()

            let action = process(event: event)

            switch action {
            case .none:
                lock.unlock()

            case .sendSubscription:
                lock.unlock()
                downstream.receive(subscription: self)

            case let .sendValue(value):
                schedule { [weak self, downstream] in
                    let demand = downstream.receive(value)
                    if demand != .none {
                        self?.handle(event: .requestDemand(demand))
                    }
                }

                lock.unlock()

            case let .sendCompletion(completion):
                switch completion {
                case .finished:
                    schedule { [downstream] in
                        downstream.receive(completion: .finished)
                    }

                case let .failure(error):
                    schedule { [downstream] in
                        downstream.receive(completion: .failure(error))
                    }
                }

                lock.unlock()

            case let .cancel(subscription):
                lock.unlock()

                subscription.cancel()

            case let .sendError(error):
                schedule { [downstream] in
                    downstream.receive(completion: .failure(error))
                }

                lock.unlock()

            case let .requestValue(subscription):
                lock.unlock()

                subscription.request(.max(1))

            case let .sendLastValue(value, completion):
                schedule { [downstream] in
                    _ = downstream.receive(value)

                    switch completion {
                    case .finished:
                        downstream.receive(completion: .finished)

                    case let .failure(error):
                        downstream.receive(completion: .failure(error))
                    }
                }

                lock.unlock()

            case let .sendAndRequest(value, subscription):
                schedule { [weak self, downstream] in
                    let demand = downstream.receive(value)
                    if demand != .none {
                        self?.handle(event: .requestDemand(demand))
                    }
                }

                lock.unlock()

                subscription.request(.max(1))

            case let .cancelSendingError(subscription, error):
                schedule { [downstream] in
                    downstream.receive(completion: .failure(error))
                }

                lock.unlock()

                subscription.cancel()
            }
        }

        private func schedule(operation: @escaping () -> Void) {
            let previous = lastTask

            lastTask = taskFactory.detached {
                await previous?.value

                operation()
            }
        }

        // swiftlint:disable:next cyclomatic_complexity
        private func process(event: Event) -> Action {
            switch state {
            case .waitingForSubscription:
                switch event {
                case let .receiveSubscription(subscription):
                    state = .subscribed(with: subscription)

                    return .sendSubscription

                case .cancel:
                    state = .completed
                    return .none

                default:
                    return .none
                }

            case let .subscribed(with: subscription):
                switch event {
                case .cancel:
                    state = .completed

                    return .cancel(subscription)

                case let .receiveCompletion(completion):
                    state = .completed

                    return .sendCompletion(completion)

                case let .requestDemand(demand):
                    state = .haveDemand(from: subscription, demand: demand)

                    return .requestValue(subscription)

                default:
                    return .none
                }

            case let .haveDemand(from: subscription, demand: demand):
                switch event {
                case .cancel:
                    state = .completed
                    return .cancel(subscription)

                case let .receiveCompletion(completion):
                    state = .completed

                    return .sendCompletion(completion)

                case let .requestDemand(newDemand):
                    state = .haveDemand(from: subscription, demand: demand + newDemand)

                    return .none

                case let .receiveInput(input):
                    state = .mapping(from: subscription, pendingDemand: demand, mapTask: createMapTask(value: input))

                    return .none
                default:
                    return .none
                }

            case let .mapping(from: subscription, pendingDemand: pendingDemand, mapTask: mapTask):
                switch event {
                case .cancel:
                    mapTask.cancel()
                    state = .completed

                    return .cancel(subscription)

                case let .receiveCompletion(completion):
                    state = .finishing(from: subscription, mapTask: mapTask, pendingCompletion: completion)

                    return .none

                case let .requestDemand(newDemand):
                    state = .mapping(from: subscription, pendingDemand: pendingDemand + newDemand, mapTask: mapTask)

                    return .none

                case let .receiveResult(result):
                    let newDemand = pendingDemand - 1
                    if newDemand != .none {
                        state = .haveDemand(from: subscription, demand: newDemand)
                        return .sendAndRequest(result, subscription)
                    } else {
                        return .sendValue(result)
                    }

                case let .receiveError(error):
                    state = .completed

                    return .cancelSendingError(subscription, error)

                default:
                    return .none
                }

            case let .finishing(from: subscription, mapTask: mapTask, pendingCompletion: completion):
                switch event {
                case .cancel:
                    mapTask.cancel()
                    state = .completed

                    return .cancel(subscription)

                case let .receiveResult(result):
                    state = .completed

                    return .sendLastValue(result, completion)

                case let .receiveError(error):
                    state = .completed

                    return .cancelSendingError(subscription, error)

                default:
                    return .none
                }
            case .completed:
                return .none
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

extension Publishers.TryExhaustMap.Inner.Action: CustomStringConvertible {

    // MARK: - Type Methods

    var description: String {
        switch self {
        case .none:
            return ".none"

        case .sendSubscription:
            return ".sendSubscription"

        case let .requestValue(subscription):
            return ".requestValue(\(subscription))"

        case let .sendValue(output):
            return ".sendValue(\(output))"

        case let .sendError(error):
            return ".sendError(\(error))"

        case let .sendCompletion(subscribers_Completion_Upstream_Failure_):
            return ".sendCompletion(\(subscribers_Completion_Upstream_Failure_))"

        case let .sendLastValue(value0, value1):
            return ".sendLastValue(\(value0), \(value1))"

        case let .sendAndRequest(value0, value1):
            return ".sendAndRequest(\(value0), \(value1))"

        case let .cancel(subscription):
            return ".cancel(\(subscription))"

        case let .cancelSendingError(value0, value1):
            return ".cancelSendingError(\(value0), \(value1))"

        @unknown default:
            return "<unknown>"
        }
    }
}


extension Publishers.TryExhaustMap.Inner.Event: CustomStringConvertible {

    // MARK: - Type Methods

    var description: String {
        switch self {
        case let .receiveSubscription(subscription):
            return ".receiveSubscription(\(subscription))"

        case let .requestDemand(subscribers_Demand):
            return ".requestDemand(\(subscribers_Demand))"

        case let .receiveInput(input):
            return ".receiveInput(\(input))"

        case let .receiveResult(output):
            return ".receiveResult(\(output))"

        case let .receiveError(error):
            return ".receiveError(\(error))"

        case .cancel:
            return ".cancel"

        case let .receiveCompletion(subscribers_Completion_Failure_):
            return ".receiveCompletion(\(subscribers_Completion_Failure_))"

        @unknown default:
            return "<unknown>"
        }
    }
}

extension Publishers.TryExhaustMap.Inner.State: CustomStringConvertible {

    // MARK: - Type Methods

    var description: String {
        switch self {
        case .waitingForSubscription:
            return ".waitingForSubscription"

        case let .subscribed(with):
            return ".subscribed(with: \(with))"

        case let .haveDemand(from, demand):
            return ".haveDemand(from: \(from), demand: \(demand))"

        case let .mapping(from, pendingDemand, mapTask):
            return ".mapping(from: \(from), pendingDemand: \(pendingDemand), mapTask: \(mapTask))"

        case let .finishing(from, mapTask, pendingCompletion):
            return ".finishing(from: \(from), mapTask: \(mapTask), pendingCompletion: \(pendingCompletion))"

        case .completed:
            return ".completed"

        @unknown default:
            return "<unknown>"
        }
    }
}
