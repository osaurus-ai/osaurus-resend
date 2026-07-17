import Testing

/// Root container that forces every suite in this target to run serially.
///
/// The mock host state is process-global (`hostAPI`, `mockConfig`,
/// `mockHTTPResponses`, ...) because the production code reads a single
/// global `hostAPI` pointer. Swift Testing runs distinct top-level suites in
/// parallel, so two suites calling `MockHost.setUp()` concurrently trample
/// each other's mock state (wiped HTTP response queues, leaked config,
/// concurrent array mutation crashes). `.serialized` on this root applies
/// recursively to every nested suite, restoring determinism without
/// touching production code.
@Suite(.serialized) struct AllResendTests {}
