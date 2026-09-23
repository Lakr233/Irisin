//
//  UIColor+Status.swift
//  Irisin
//
//  Colours that mean a state. Each keeps its own hue and never borrows the
//  accent.
//

import UIKit

extension UIColor {
    /// A package the queue adds, as a diff marks an added line. Removals
    /// use `.swipeDelete`.
    static let diffAddition = UIColor.systemGreen

    /// Files already on the device that a queued package writes over: the
    /// one count on its page worth a second look.
    static let diffReplacement = UIColor.systemOrange

    /// A package requirement has a matching candidate.
    static let requirementMatched = UIColor.systemGreen

    /// A package requirement needs attention before installation.
    static let requirementIssue = UIColor.systemRed

    /// The installation finished successfully and its log can be closed.
    static let operationSucceeded = UIColor.systemGreen

    /// Installation failed; the transcript remains available for review.
    static let operationFailed = UIColor.systemRed

    /// A problem the operation survived: a package left unpacked, a home
    /// screen that was not told.
    static let operationWarning = UIColor.systemOrange

    /// The track a progress ring runs on.
    static let progressTrack = UIColor.textSubtitle.withAlphaComponent(0.2)

    /// The disc behind a package's version badge.
    static let versionBadgeBacking = UIColor.white

    /// A version newer than the installed one: the badge, and the update
    /// indicator on the Updates and Installed pages.
    static let updateAvailable = UIColor.systemBlue

    /// The installed version is the latest; on the Installed page, nothing
    /// is out of date.
    static let upToDate = UIColor.systemGreen

    /// The repository offers only a version older than the installed one.
    static let versionOlder = UIColor.systemGray2

    /// A version that cannot be compared with the installed one.
    static let versionInvalid = UIColor.systemRed

    /// The new version in an update row's "old → new" line.
    static let versionHighlight = UIColor.orange

    /// A repository's dot: ready, failed to load, waiting to refresh.
    static let repositoryReady = UIColor.systemGreen
    static let repositoryFailed = UIColor.systemRed
    static let repositoryPending = UIColor.cyan

    /// A repository's dot when it has packages but its last refresh had
    /// trouble, or was over a day ago: usable, not current.
    static let repositoryDegraded = UIColor.systemOrange

    /// A repository whose store account the user is signed in to.
    static let signedIn = UIColor.systemGreen

    /// Log viewer lines by level: a verbose line is dimmed; a warning, an
    /// error and a critical line are red, the last two on a red wash.
    static let logVerbose = UIColor.systemGray
    static let logVerboseDetail = UIColor.systemGray2
    static let logProblem = UIColor.systemRed
    static let logProblemDetail = UIColor.systemRed.withAlphaComponent(0.7)
    static let logErrorBackground = UIColor.systemRed.withAlphaComponent(0.05)
    static let logCriticalBackground = UIColor.systemRed.withAlphaComponent(0.12)
}
