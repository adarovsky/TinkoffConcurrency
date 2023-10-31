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
        let scheduler = DispatchQueue.test

        // when
        let result = UncheckedSendable<[String]>([])

        Publishers.ExhaustMap(taskFactory: taskFactory, upstream: input, scheduler: scheduler) { value in
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

        await scheduler.run()

        // then
        XCTAssertEqual(result.value, ["1", "2", "3", "4", "5"])
    }

    func test_exhaustMap_extension_values() async {
        // given
        let input = [1, 2, 3, 4, 5].publisher
        var bag = Set<AnyCancellable>()
        let scheduler = DispatchQueue.test

        // when
        let result = UncheckedSendable<[String]>([])

        input.exhaustMap(taskFactory: taskFactory, scheduler: scheduler) { value in
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

        await scheduler.run()

        // then
        XCTAssertEqual(result.value, ["1", "2", "3", "4", "5"])
    }

    func test_exhaustMap_subscriptions() async {
        // given
        let input = PublisherMock<Int, Never>()
        let subscriber1 = SubscriberMock<String, Never>()
        let subscriber2 = SubscriberMock<String, Never>()
        let scheduler = DispatchQueue.test
        let publisher = input.exhaustMap(taskFactory: taskFactory, scheduler: scheduler) { "\($0)" }

        // when
        publisher.subscribe(subscriber1)
        publisher.subscribe(subscriber2)

        await taskFactory.runUntilIdle()

        await scheduler.run()

        // then
        XCTAssertEqual(input.subscriptions.count, 2)
    }
}

private struct TestError: Error {}
