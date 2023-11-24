import XCTest
import Combine
@testable import TinkoffConcurrency
import TinkoffConcurrencyTesting

final class ExhaustMapTests: XCTestCase {

    // MARK: - Dependencies

    var taskFactory: TCTestTaskFactory!

    // MARK: - XCTestCase

    override func setUp() {
        super.setUp()

        taskFactory = TCTestTaskFactory()
    }

    override func tearDown() {
        super.tearDown()

        taskFactory = nil
    }

    // MARK: - Tests

    func test_exhaustMap_values() async {
        // given
        let input = [1, 2, 3, 4, 5].publisher
        var bag = Set<AnyCancellable>()

        // when
        let result = UncheckedSendable<[String]>([])

        Publishers.ExhaustMap(taskFactory: taskFactory, upstream: input) { value in
            "\(value)"
        }.sink { completion in
            switch completion {
            case .finished:
                break
            case let .failure(error):
                XCTFail("Unexpected error received: \(error)")
            }
        } receiveValue: { value in
            result.mutate { $0.append(value) }
        }.store(in: &bag)

        await taskFactory.runUntilIdle()

        // then
        XCTAssertEqual(result.value, ["1", "2", "3", "4", "5"])
    }

    func test_exhaustMap_extension_values() async {
        // given
        let input = [1, 2, 3, 4, 5].publisher
        var bag = Set<AnyCancellable>()

        // when
        let result = UncheckedSendable<[String]>([])

        input.exhaustMap(taskFactory: taskFactory) { value in
            "\(value)"
        }.sink { completion in
            switch completion {
            case .finished:
                break
            case .failure:
                XCTFail("Unexpected error received")
            }
        } receiveValue: { value in
            result.mutate { $0.append(value) }
        }.store(in: &bag)

        await taskFactory.runUntilIdle()

        // then
        XCTAssertEqual(result.value, ["1", "2", "3", "4", "5"])
    }

    func test_exhaustMap_subscriptions() async {
        // given
        let input = PublisherMock<Int, Never>()
        let subscriber1 = SubscriberMock<String, Never>()
        let subscriber2 = SubscriberMock<String, Never>()
        let publisher = input.exhaustMap(taskFactory: taskFactory) { "\($0)" }

        // when
        publisher.subscribe(subscriber1)
        publisher.subscribe(subscriber2)

        await taskFactory.runUntilIdle()

        // then
        XCTAssertEqual(input.subscriptions.count, 2)
    }

    func test_map_subscriptions() async {
        // given
        let input = PublisherMock<Int, Never>()
        let subscriber = SubscriberMock<String, Never>()
        let publisher = input.map { "\($0)" }

        // when
        publisher.subscribe(subscriber)

        await taskFactory.runUntilIdle()

        // then
        XCTAssertEqual(input.subscriptions.count, 1)

        let subscription = input.subscriptions[0]

        XCTAssertEqual(subscription.history, [.requested(.max(1))])

        // when
        let inputSubscriber = input.subscribers[0]

        let demand = inputSubscriber.receive(1)

        XCTAssertEqual(demand, .max(1))

        XCTAssertEqual(subscription.history, [.requested(.max(1))])
    }
}

private struct TestError: Error {}
