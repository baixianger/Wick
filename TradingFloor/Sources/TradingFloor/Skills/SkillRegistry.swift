import Foundation

/// Loads `Skill` markdowns from one or more directories and serves them up
/// by name. Two layers: bundled (shipped with the module) and user
/// (read from a directory the host picks — typically `~/Library/Application
/// Support/Wick/Skills`). Same-name user skills *override* bundled ones, so
/// power users can tweak the canonical playbooks without forking.
public actor SkillRegistry {
    private var skills: [String: Skill] = [:]
    private let userDirectory: URL?

    public init(userDirectory: URL? = nil) {
        self.userDirectory = userDirectory
    }

    /// Reload everything from disk. Idempotent — call after the user adds
    /// or edits a skill in the user directory.
    public func reload() async {
        var loaded: [String: Skill] = [:]
        for skill in Self.loadBundled() {
            loaded[skill.name] = skill
        }
        if let url = userDirectory {
            for skill in Self.loadDirectory(url, source: .user(directoryName: url.lastPathComponent)) {
                loaded[skill.name] = skill   // user wins on name conflicts
            }
        }
        self.skills = loaded
    }

    public func all() -> [Skill] {
        Array(skills.values).sorted { $0.name < $1.name }
    }

    public func skill(named name: String) -> Skill? { skills[name] }

    /// Filter skills whose `triggers` overlap any of `keywords`. Cheap
    /// recall used by the free agent to decide which skill bodies to inline
    /// into a system prompt for a given user turn — keeps token cost down.
    public func relevant(to keywords: [String]) -> [Skill] {
        let needles = Set(keywords.map { $0.lowercased() })
        return all().filter { skill in
            !skill.triggers.isEmpty
            && skill.triggers.contains(where: { needles.contains($0.lowercased()) })
        }
    }

    // MARK: - Loaders

    private static func loadBundled() -> [Skill] {
        // `Bundle.module` is auto-synthesized by SPM when a target declares
        // resources. Skill markdowns live in `Resources/Skills/` and ship
        // verbatim (see Package.swift).
        guard let dir = Bundle.module.url(forResource: "Skills", withExtension: nil)
            ?? Bundle.module.resourceURL?.appendingPathComponent("Skills")
        else { return [] }
        return loadDirectory(dir, source: .bundled)
    }

    private static func loadDirectory(_ dir: URL, source: Skill.Source) -> [Skill] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        ) else { return [] }
        return entries
            .filter { $0.pathExtension.lowercased() == "md" }
            .compactMap { url in
                guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
                return Skill.from(markdown: text, source: source)
            }
    }
}
