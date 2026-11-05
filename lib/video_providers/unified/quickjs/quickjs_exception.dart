/// Failure raised by the isolated JavaScript source runtime.
class JsRuntimeException implements Exception {
  const JsRuntimeException(this.message);
  final String message;
  @override
  String toString() => 'JsRuntimeException: $message';
}
