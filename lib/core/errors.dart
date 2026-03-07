/// Medora - Error Handling
library;

/// Base class for application-specific exceptions.
sealed class AppException implements Exception {
  const AppException(this.message, [this.stackTrace]);

  final String message;
  final StackTrace? stackTrace;

  @override
  String toString() => '$runtimeType: $message';
}

/// Exception thrown when a server/API call fails.
class ServerException extends AppException {
  const ServerException(super.message, [super.stackTrace]);
}

/// Exception thrown when data is not found.
class NotFoundException extends AppException {
  const NotFoundException(super.message, [super.stackTrace]);
}

/// Exception thrown when a cache operation fails.
class CacheException extends AppException {
  const CacheException(super.message, [super.stackTrace]);
}

/// Exception thrown for authentication errors.
class AuthException extends AppException {
  const AuthException(super.message, [super.stackTrace]);
}

/// Exception thrown for validation errors.
class ValidationException extends AppException {
  const ValidationException(super.message, [super.stackTrace]);
}

