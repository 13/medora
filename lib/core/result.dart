/// Medora - Result Type
///
/// A simple Result type for clean error handling without exceptions.
library;

sealed class Result<T> {
  const Result();

  /// Creates a successful result.
  const factory Result.success(T data) = Success<T>;

  /// Creates a failure result.
  const factory Result.failure(String message, [StackTrace? stackTrace]) =
      Failure<T>;

  /// Pattern match on the result.
  R when<R>({
    required R Function(T data) success,
    required R Function(String message) failure,
  }) {
    return switch (this) {
      Success<T>(:final data) => success(data),
      Failure<T>(:final message) => failure(message),
    };
  }

  /// Returns true if the result is a success.
  bool get isSuccess => this is Success<T>;

  /// Returns true if the result is a failure.
  bool get isFailure => this is Failure<T>;

  /// Returns the data if success, null otherwise.
  T? get dataOrNull => switch (this) {
    Success<T>(:final data) => data,
    Failure<T>() => null,
  };
}

final class Success<T> extends Result<T> {
  const Success(this.data);
  final T data;
}

final class Failure<T> extends Result<T> {
  const Failure(this.message, [this.stackTrace]);
  final String message;
  final StackTrace? stackTrace;
}

