import Foundation
import IrisinProtocol

/// Where every package of a transaction stands, read off the helper's
/// events in the order they arrive.
///
/// The transaction's stages say which steps a package goes through before
/// anything runs; `.package` opens a step, `.packageProgress` measures it
/// when it can be measured, and the `.progress` that follows closes it. A
/// value type with no clock and no UI in it: the operation page draws a row
/// from each `State`, and a test feeds it events and reads the result.
nonisolated struct OperationPackages: Equatable {
    enum Status: Equatable {
        /// Its next step has not begun.
        case waiting
        /// A step is under way; `script` is the maintainer script it runs now.
        case running(InstallerEvent.PackageStep, script: String?)
        case done
        /// The transaction stopped here, in this step.
        case failed(step: InstallerEvent.PackageStep)
        /// Some steps ran before the transaction stopped elsewhere: the
        /// package is unpacked and was never set up.
        case incomplete
        /// The transaction stopped before reaching it.
        case notStarted
    }

    struct State: Equatable {
        /// The steps the stages plan for this package, in order.
        fileprivate(set) var steps: [InstallerEvent.PackageStep] = []
        fileprivate(set) var completed = 0
        /// How far the running step is, when it counts; nil while it cannot.
        fileprivate(set) var stepFraction: Double?
        fileprivate(set) var status = Status.waiting
        /// Why it failed, in the helper's own case.
        fileprivate(set) var problem: InstallerEvent.Problem?
        /// The helper could not put the old record back: half-installed
        /// until it is installed again.
        fileprivate(set) var needsRepair = false
        /// A package-owned script failed under the explicit continue policy.
        /// The step completed, but the package may not work as intended.
        fileprivate(set) var ignoredScriptFailure = false

        /// The whole package, 0 to 1. Placing files is most of an install
        /// and is the part that can be measured.
        var fraction: Double {
            if status == .done {
                return 1
            }
            let weights = steps.map(Self.weight)
            let total = weights.reduce(0, +)
            guard total > 0 else { return 0 }
            var done = weights.prefix(completed).reduce(0, +)
            // a failed row keeps the mark of where it stopped
            switch status {
            case .running, .failed:
                if completed < weights.count {
                    done += weights[completed] * (stepFraction ?? 0)
                }
            default:
                break
            }
            return done / total
        }

        /// Whether the ring has a number to show or only that work goes on.
        var isIndeterminate: Bool {
            if case .running = status {
                return stepFraction == nil
            }
            return false
        }

        var hasProblem: Bool {
            if ignoredScriptFailure {
                return true
            }
            switch status {
            case .failed, .incomplete:
                return true
            default:
                return needsRepair
            }
        }

        /// The package's own maintainer script that stopped it, if one did.
        var failedScript: String? {
            switch problem {
            case let .scriptFailed(_, _, script, _), let .scriptFailureIgnored(_, script, _):
                script
            default:
                nil
            }
        }

        /// The step its turn comes for next, nil once it has none left.
        var nextStep: InstallerEvent.PackageStep? {
            completed < steps.count ? steps[completed] : nil
        }

        /// Whether its files reached the disk.
        var isUnpacked: Bool {
            steps.prefix(completed).contains(.unpacking)
        }

        private static func weight(_ step: InstallerEvent.PackageStep) -> Double {
            switch step {
            case .verifying: 0.1
            case .unpacking: 0.6
            case .configuring: 0.3
            case .removing, .triggering: 1
            }
        }
    }

    private(set) var states: [String: State] = [:]
    /// The package the helper is working on: a script's output is its.
    private(set) var current: String?
    /// The package whose step the next `.progress` closes. Only `.package`
    /// names it: a script another package runs meanwhile, a victim's
    /// `prerm deconfigure` or a replaced package's `postrm disappear`,
    /// takes the output and not the step.
    private var stepOwner: String?
    private var stepsCompleted = 0

    init(stages: [InstallerStage]) {
        for stage in stages {
            let step: InstallerEvent.PackageStep = switch stage {
            case .remove: .removing
            case .unpack: .unpacking
            case .configure: .configuring
            }
            for identity in stage.identities {
                // an archive is checked before it is unpacked
                states[identity, default: State()].steps.append(contentsOf: step == .unpacking ? [.verifying, step] : [step])
            }
        }
    }

    /// Checking an archive ends without a word: the next package's turn, or
    /// the next phase, says it passed.
    private mutating func closeVerification() {
        guard let identity = stepOwner, case .running(.verifying, _) = states[identity]?.status else { return }
        states[identity]?.completed += 1
        states[identity]?.status = .waiting
        current = nil
        stepOwner = nil
    }

    mutating func record(_ event: InstallerEvent) {
        switch event {
        case .phase:
            closeVerification()
        case let .package(step, identity, _):
            closeVerification()
            // triggers run for packages the transaction never named, and
            // for ones it finished: the output is theirs, the row stays
            current = states[identity] == nil ? nil : identity
            guard step != .triggering, var state = states[identity] else { return }
            stepOwner = identity
            // the step it names is the one it is on, whatever was heard before
            state.completed = state.steps.firstIndex(of: step) ?? state.completed
            state.status = .running(step, script: nil)
            state.stepFraction = nil
            states[identity] = state
        case let .packageProgress(identity, completed, total):
            guard total > 0, case let .running(step, _) = states[identity]?.status else { return }
            states[identity]?.status = .running(step, script: nil)
            states[identity]?.stepFraction = Double(completed) / Double(total)
        case let .script(identity, member, _):
            current = states[identity] == nil ? nil : identity
            if case let .running(step, _) = states[identity]?.status {
                states[identity]?.status = .running(step, script: member)
            }
        case let .progress(completed, _):
            defer { stepsCompleted = completed }
            guard completed > stepsCompleted, let identity = stepOwner, var state = states[identity] else { return }
            state.completed += 1
            state.stepFraction = nil
            state.status = state.completed >= state.steps.count ? .done : .waiting
            states[identity] = state
            current = nil
            stepOwner = nil
        case let .warning(problem):
            switch problem {
            case let .packageNeedsRepair(identity):
                states[identity]?.needsRepair = true
            case let .scriptFailureIgnored(identity, _, _):
                states[identity]?.ignoredScriptFailure = true
                states[identity]?.problem = problem
            default:
                break
            }
        case let .failure(problem):
            switch problem {
            case let .packageFailed(identity, step, _), let .scriptFailed(identity, step, _, _):
                states[identity]?.status = .failed(step: step)
                states[identity]?.problem = problem
            default:
                break
            }
        default:
            break
        }
    }

    /// The operation is over. After a failure every row says what is true of
    /// its package now: the helper keeps what it finished and rolls nothing
    /// back, so a package is done, failed, left unpacked or never reached.
    mutating func finish(succeeded: Bool) {
        current = nil
        stepOwner = nil
        for (identity, var state) in states {
            switch state.status {
            case .done, .failed, .incomplete, .notStarted:
                continue
            case .waiting, .running:
                if succeeded {
                    state.status = .done
                } else if case let .running(step, _) = state.status {
                    // the helper went away without a word about it
                    state.status = .failed(step: step)
                } else {
                    state.status = state.isUnpacked ? .incomplete : .notStarted
                }
            }
            states[identity] = state
        }
    }
}
