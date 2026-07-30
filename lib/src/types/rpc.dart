import '../proto/livekit_models.pb.dart' as lk_models;

class PerformRpcParams {
  /// The unique participant identity of the destination.
  String destinationIdentity;

  /// The method name to call.
  String method;

  /// The payload of the request.
  String payload;

  /// Timeout for receiving a response after the initial connection (in milliseconds).
  /// If a value less than 8000 ms is provided, it will be automatically clamped to 8000 ms
  /// to ensure sufficient time for round-trip latency buffering.
  /// Default: 15000 ms.
  Duration responseTimeoutMs;

  /// Timeout for receiving an ACK from the server after sending the RPC request.
  /// On low-end devices where the Dart event loop may be starved, increase this
  /// to prevent premature connectionTimeout (1501) errors.
  /// Default: 7 seconds (original SDK behavior).
  Duration? ackTimeout;

  PerformRpcParams({
    required this.destinationIdentity,
    required this.method,
    required this.payload,
    this.responseTimeoutMs = const Duration(milliseconds: 15000),
    this.ackTimeout,
  });
}

class RpcInvocationData {
  /// The unique request ID. Will match at both sides of the call, useful for debugging or logging.
  String requestId;

  /// The unique participant identity of the caller.
  String callerIdentity;

  /// The payload of the request. User-definable format, typically JSON.
  String payload;

  /// The maximum time the caller will wait for a response.
  int responseTimeoutMs;

  RpcInvocationData({
    required this.requestId,
    required this.callerIdentity,
    required this.payload,
    required this.responseTimeoutMs,
  });
}

typedef RpcRequestHandler = Future<String> Function(RpcInvocationData data);

class RpcError implements Exception {
  final String message;
  final int code;
  final String? data;

  RpcError({
    required this.message,
    required this.code,
    this.data,
  });

  factory RpcError.fromProto(lk_models.RpcError error) {
    return RpcError(
      message: error.message,
      code: error.code,
      data: error.data,
    );
  }

  lk_models.RpcError toProto() {
    return lk_models.RpcError()
      ..message = message
      ..code = code
      ..data = data ?? '';
  }

  static final applicationError = 1500;
  static final connectionTimeout = 1501;
  static final responseTimeout = 1502;
  static final recipientDisconnected = 1503;
  static final responsePayloadTooLarge = 1504;
  static final sendFailed = 1505;

  static final unsupportedMethod = 1400;
  static final recipientNotFound = 1401;
  static final requestPayloadTooLarge = 1402;
  static final unsupportedServer = 1403;
  static final unsupportedVersion = 1404;

  static Map<int, String> errorMessages = {
    applicationError: 'Application error in method handler',
    connectionTimeout: 'Connection timeout',
    responseTimeout: 'Response timeout',
    recipientDisconnected: 'Recipient disconnected',
    responsePayloadTooLarge: 'Response payload too large',
    sendFailed: 'Failed to send',
    unsupportedMethod: 'Method not supported at destination',
    recipientNotFound: 'Recipient not found',
    requestPayloadTooLarge: 'Request payload too large',
    unsupportedServer: 'RPC not supported by server',
    unsupportedVersion: 'Unsupported RPC version',
  };

  /// Creates an error object from the code, with an auto-populated message.

  static RpcError builtIn(int errorCode, {String? data}) {
    return RpcError(
      message: errorMessages[errorCode] ?? 'Unknown error',
      code: errorCode,
      data: data,
    );
  }

  /// Longest [message] rendered by [toString]. The message is composed by the
  /// remote side, so it is bounded before it reaches a log or crash reporter.
  static const maxDescribedMessageLength = 200;

  /// Carries the code and message so an error that escapes to a crash reporter
  /// or log is identifiable — the default `Instance of 'RpcError'` discards
  /// everything that says which call failed and why.
  ///
  /// [data] is an opaque payload chosen by the remote side and may carry user
  /// content, so only its length is reported. Anything that needs the payload
  /// itself should read [data] directly and decide what is safe to record.
  @override
  String toString() {
    final buffer = StringBuffer('RpcError(code: $code, message: ');
    if (message.length > maxDescribedMessageLength) {
      buffer.write('${message.substring(0, maxDescribedMessageLength)}...');
    } else {
      buffer.write(message);
    }
    // fromProto stores an absent payload as '', so length is the test, not null.
    if (data != null && data!.isNotEmpty) {
      buffer.write(', data: ${data!.length} chars');
    }
    buffer.write(')');

    return buffer.toString();
  }
}

/// Maximum payload size for RPC requests and responses. If a payload exceeds this size,
/// the RPC call will fail with a REQUEST_PAYLOAD_TOO_LARGE(1402) or RESPONSE_PAYLOAD_TOO_LARGE(1504) error.
final kRpcMaxPayloadBytes = 15360; // 15 KB

final int kRpcVesion = 1;
