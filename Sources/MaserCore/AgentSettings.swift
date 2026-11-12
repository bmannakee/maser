// The review agent's settings, and which PRs it may read.
//
// `AgentSettings` holds the `[agent]` table of `config.toml`: where `claude` is, which owners and hosts the agent may
// read code from, the model, effort and spending cap, and where the user's clones live. The agent is off for a PR
// unless an allow rule matches it, since whether code may go to the model provider is its owner's decision.

import Foundation

/// The `[agent]` settings in `config.toml`.
public struct AgentSettings: Equatable, Sendable {
    /// How hard the agent thinks before answering; passed to `claude --effort`.
    public enum Effort: String, CaseIterable, Sendable {
        case low, medium, high, xhigh, max
    }

    /// One entry of `[agent] allow`: an owner on github.com, a whole host, or one owner on a host.
    public struct AllowRule: Equatable, Sendable, CustomStringConvertible {
        /// The host, lowercased; `github.com` for a bare owner.
        public let host: String
        /// The owner, lowercased, or nil to allow the whole host.
        public let owner: String?

        /// Parses an entry, such as `my-org`, `github.example.com` or `github.example.com/my-org`.
        ///
        /// Owners can't contain dots and hosts must, which tells the two apart. Fails if the entry is none of the three
        /// forms.
        ///
        /// - Parameter entry: The entry as written.
        public init?(_ entry: String) {
            let parts = entry.trimmingCharacters(in: .whitespaces).lowercased().split(
                separator: "/", omittingEmptySubsequences: false
            )
            .map(String.init)
            let isOwner = { (part: String) in
                !part.isEmpty && part.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" } && !part.hasPrefix("-")
            }
            let isHost = { (part: String) in
                part.contains(".") && part.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "." }
                    && !part.hasPrefix(".") && !part.hasSuffix(".")
            }
            switch parts.count {
            case 1 where isHost(parts[0]):
                host = parts[0]
                owner = nil
            case 1 where isOwner(parts[0]):
                host = "github.com"
                owner = parts[0]
            case 2 where isHost(parts[0]) && isOwner(parts[1]):
                host = parts[0]
                owner = parts[1]
            default:
                return nil
            }
        }

        /// Whether the rule allows a PR.
        ///
        /// - Parameter pr: The pull request.
        /// - Returns: True if the PR is on the rule's host and, for an owner rule, belongs to that owner.
        public func allows(_ pr: PullRequest) -> Bool {
            guard pr.host.lowercased() == host else { return false }
            guard let owner else { return true }
            let prOwner = pr.repository.nameWithOwner.split(separator: "/").first.map { $0.lowercased() }
            return prOwner == owner
        }

        /// The rule as it would be written in the config.
        public var description: String {
            switch (host, owner) {
            case ("github.com", let owner?): owner
            case (let host, let owner?): "\(host)/\(owner)"
            case (let host, nil): host
            }
        }
    }

    /// The path to `claude`, if set; `[agent] claude`. `nil` means search the usual places.
    public var claudePath: String?
    /// The owners and hosts whose code the agent may read.
    ///
    /// This is `[agent] allow`. Empty means the agent is off everywhere.
    public var allow: [AllowRule] = []
    /// The model to use, if set.
    ///
    /// This is `[agent] model`; `nil` leaves the choice to the user's own `claude` setting.
    public var model: String?
    /// The effort level, if set.
    ///
    /// This is `[agent] effort`; `nil` leaves the choice to the user's own `claude` setting.
    public var effort: Effort?
    /// The most one turn may spend, in US dollars; `[agent] max_budget_usd`.
    public var maxBudgetUSD = 2.0
    /// Folders to look in for the user's own clones of a PR's repository; `[agent] repositories`.
    public var repositories: [String] = []

    /// Creates the default settings: the agent off everywhere.
    public init() {}

    /// Returns the rule that lets the agent read a PR's code, if any.
    ///
    /// - Parameter pr: The pull request.
    /// - Returns: The first matching rule, or nil if the agent is off for this PR.
    public func allowRule(for pr: PullRequest) -> AllowRule? {
        allow.first { $0.allows(pr) }
    }
}
