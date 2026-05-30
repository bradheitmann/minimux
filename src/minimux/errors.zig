pub const LifecycleError = error{
    SessionNotFound,
    DaemonNotRunning,
    ControlSocketUnavailable,
    ControlSocketTimeout,
};
