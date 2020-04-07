/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

import Foundation

/// This implements the developer facing API for recording timing distribution metrics.
///
/// Instances of this class type are automatically generated by the parsers at build time,
/// allowing developers to record values that were previously registered in the metrics.yaml file.
///
/// The timing distribution API only exposes the `TimingDistributionMetricType.start()`,
/// `TimingDistributionMetricType.stopAndAccumulate(_:)` and `TimingDistributionMetricType.cancel(_:)`  methods.
public class TimingDistributionMetricType {
    let handle: UInt64
    let disabled: Bool
    let sendInPings: [String]

    /// The public constructor used by automatically generated metrics.
    public init(category: String,
                name: String,
                sendInPings: [String],
                lifetime: Lifetime,
                disabled: Bool,
                timeUnit: TimeUnit = .minute) {
        self.disabled = disabled
        self.sendInPings = sendInPings
        self.handle = withArrayOfCStrings(sendInPings) { pingArray in
            glean_new_timing_distribution_metric(
                category,
                name,
                pingArray,
                Int32(sendInPings.count),
                lifetime.rawValue,
                disabled.toByte(),
                timeUnit.rawValue
            )
        }
    }

    /// Destroy this metric.
    deinit {
        if self.handle != 0 {
            glean_destroy_timing_distribution_metric(self.handle)
        }
    }

    /// Start tracking time for the provided metric and `GleanTimerId`.
    /// This records an error if it’s already tracking time (i.e. start was already
    /// called with no corresponding `stopAndAccumulate(_:)`): in that case the original
    /// start time will be preserved.
    ///
    /// - returns The `GleanTimerId` object to associate with this timing.
    public func start() -> GleanTimerId? {
        guard !self.disabled else { return nil }

        // The Rust code for `stopAndAccumulate` runs async and we need to use the same clock for start and stop.
        // Therefore we take the time on the Swift side.
        let startTime = timestampNanos()

        // No dispatcher, we need the return value
        return glean_timing_distribution_set_start(self.handle, startTime)
    }

    /// Stop tracking time for the provided metric and associated timer id. Add a
    /// count to the corresponding bucket in the timing distribution.
    /// This will record an error if no `start()` was called.
    ///
    /// - parameters:
    ///     * timerId: The `GleanTimerId` to associate with this timing.
    ///                This allows for concurrent timing of events associated with different ids
    ///                to the same timespan metric.
    public func stopAndAccumulate(_ timerId: GleanTimerId?) {
        // `start` might return nil.
        // Accepting that means users of this API don't need to do a nil check.
        guard !self.disabled else { return }
        guard let timerId = timerId else { return }

        // The Rust code runs async and might be delayed. We need the time as precisely as possible.
        // We also need the same clock for start and stop (`start` takes the time on the Swift side).
        let stopTime = timestampNanos()

        Dispatchers.shared.launchAPI {
            glean_timing_distribution_set_stop_and_accumulate(
                self.handle,
                timerId,
                stopTime
            )
        }
    }

    /// Abort a previous `start()` call. No error is recorded if no `start()` was called.
    ///
    /// - parameters:
    ///     * timerId: The `GleanTimerId` to associate with this timing.
    ///                This allows for concurrent timing of events associated with different ids
    ///                to the same timing distribution metric.
    public func cancel(_ timerId: GleanTimerId?) {
        guard !self.disabled else { return }
        guard let timerId = timerId else { return }

        Dispatchers.shared.launchAPI {
            glean_timing_distribution_cancel(self.handle, timerId)
        }
    }

    /// Convenience method to simplify measuring a function or block of code
    ///
    /// - parameters:
    ///     * funcToMeasure: Accepts a function or closure to measure that can return a value
    public func measure<U>(funcToMeasure: () -> U) -> U {
        let timerId = start()
        // Putting `stopAndAccumulate` in a `defer` block guarantees it will execute at the end
        // of the scope, after the return value is pushed onto the stack.
        // Reference: https://docs.swift.org/swift-book/LanguageGuide/ErrorHandling.html under
        // the "Specifying Cleanup Actions" section.
        defer {
            stopAndAccumulate(timerId)
        }
        return funcToMeasure()
    }

    /// Convenience method to simplify measuring a function or block of code
    ///
    /// If the measured function throws, the measurement is canceled and the exception rethrown.
    ///
    /// - parameters:
    ///     * funcToMeasure: Accepts a function or closure to measure that can return a value
    public func measure<U>(funcToMeasure: () throws -> U) throws -> U {
        let timerId = start()

        do {
            let returnValue = try funcToMeasure()
            stopAndAccumulate(timerId)
            return returnValue
        } catch {
            cancel(timerId)
            throw error
        }
    }

    /// Tests whether a value is stored for the metric for testing purposes only. This function will
    /// attempt to await the last task (if any) writing to the the metric's storage engine before
    /// returning a value.
    ///
    /// - parameters:
    ///     * pingName: represents the name of the ping to retrieve the metric for.
    ///                 Defaults to the first value in `sendInPings`.
    /// - returns: true if metric value exists, otherwise false.
    public func testHasValue(_ pingName: String? = nil) -> Bool {
        Dispatchers.shared.assertInTestingMode()

        let pingName = pingName ?? self.sendInPings[0]
        return glean_timing_distribution_test_has_value(self.handle, pingName).toBool()
    }

    /// Returns the stored value for testing purposes only. This function will attempt to await the
    /// last task (if any) writing to the the metric's storage engine before returning a value.
    ///
    /// Throws a "Missing value" exception if no value is stored
    ///
    /// -parameters:
    ///    * pingName: represents the name of the ping to retrieve the metric for.
    ///                Defaults to the first value in `sendInPings`.
    ///
    /// - returns: value of the stored metric
    public func testGetValue(_ pingName: String? = nil) throws -> DistributionData {
        Dispatchers.shared.assertInTestingMode()

        let pingName = pingName ?? self.sendInPings[0]

        if !testHasValue(pingName) {
            throw "Missing value"
        }

        let json = String(
            freeingRustString: glean_timing_distribution_test_get_value_as_json_string(
                self.handle,
                pingName
            )
        )

        return DistributionData(fromJson: json)!
    }

    /// Returns the number of errors recorded for the given metric.
    ///
    /// - parameters:
    ///     * errorType: The type of error recorded.
    ///     * pingName: represents the name of the ping to retrieve the metric for.
    ///                 Defaults to the first value in `sendInPings`.
    ///
    /// - returns: The number of errors recorded for the metric for the given error type.
    public func testGetNumRecordedErrors(_ errorType: ErrorType, pingName: String? = nil) -> Int32 {
        Dispatchers.shared.assertInTestingMode()

        let pingName = pingName ?? self.sendInPings[0]

        return glean_timing_distribution_test_get_num_recorded_errors(
            self.handle,
            errorType.rawValue,
            pingName
        )
    }
}
