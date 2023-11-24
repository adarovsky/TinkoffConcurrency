import XCTest
import Combine
@testable import TinkoffConcurrency
import TinkoffConcurrencyTesting

final class TryExhaustMapTests: XCTestCase {

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

    func test_tryExhaustMap_values() async {
        // given
        let input = [1, 2, 3, 4, 5].publisher.setFailureType(to: TestError.self)
        var bag = Set<AnyCancellable>()

        // when
        let result = UncheckedSendable<[String]>([])

        Publishers.TryExhaustMap(taskFactory: taskFactory, upstream: input) { value in
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

    func test_tryExhaustMap_extension_values() async {
        // given
        let input = [1, 2, 3, 4, 5].publisher.setFailureType(to: TestError.self)
        var bag = Set<AnyCancellable>()

        // when
        let result = UncheckedSendable<[String]>([])

        input.tryExhaustMap(taskFactory: taskFactory) { value in
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

    func test_tryExhaustMap_subscriptions() async {
        // given
        let input = PublisherMock<Int, TestError>()
        let subscriber1 = SubscriberMock<String, Error>()
        let subscriber2 = SubscriberMock<String, Error>()
        let publisher = input.tryExhaustMap(taskFactory: taskFactory) { "\($0)" }

        // when
        publisher.subscribe(subscriber1)
        publisher.subscribe(subscriber2)

        await taskFactory.runUntilIdle()

        // then
        XCTAssertEqual(input.subscriptions.count, 2)
    }
}

private struct TestError: Error {}
