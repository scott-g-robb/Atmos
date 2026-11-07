import Foundation

/// A provider deadline must not wait for an SDK operation that ignores
/// cancellation; the next provider still needs an opportunity to recover.
enum WeatherAttempt {
  static func run<Value>(timeout: TimeInterval,
    operation: @escaping () async throws -> Value) async throws -> Value {
    let pending = Pending<Value>()
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        pending.start(continuation,timeout:timeout,operation:operation)
      }
    } onCancel: {
      pending.finish(.failure(CancellationError()))
    }
  }

  private final class Pending<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<Value,Error>?
    private var continuation: CheckedContinuation<Value,Error>?
    private var work: Task<Void,Never>?
    private var deadline: Task<Void,Never>?

    func start(_ continuation: CheckedContinuation<Value,Error>,timeout: TimeInterval,
      operation: @escaping () async throws -> Value) {
      lock.lock()
      if let result { lock.unlock();continuation.resume(with:result);return }
      self.continuation = continuation
      lock.unlock()
      let work = Task { [self] in
        do { finish(.success(try await operation())) }
        catch { finish(.failure(error)) }
      }
      let deadline = Task { [self] in
        do { try await Task.sleep(nanoseconds:UInt64(max(0,timeout)*1_000_000_000)) }
        catch { return }
        finish(.failure(URLError(.timedOut)))
      }
      lock.lock()
      let finished = result != nil
      if !finished { self.work = work;self.deadline = deadline }
      lock.unlock()
      if finished { work.cancel();deadline.cancel() }
    }
    func finish(_ result: Result<Value,Error>) {
      lock.lock()
      guard self.result == nil else { lock.unlock();return }
      self.result = result
      let continuation = self.continuation, work = self.work, deadline = self.deadline
      self.continuation = nil;self.work = nil;self.deadline = nil
      lock.unlock()
      work?.cancel();deadline?.cancel()
      continuation?.resume(with:result)
    }
  }
}
