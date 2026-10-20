import Foundation

/// Who the user is, set up on first launch (Settings → General after that): what Joe's
/// instructions say about them, in place of anything written for one person. Kept in UserDefaults.
enum Profile {
    private static let defaults = UserDefaults.standard

    static var name: String {
        get { defaults.string(forKey: "userName") ?? "" }
        set { defaults.set(newValue, forKey: "userName") }
    }
    static var school: String {
        get { defaults.string(forKey: "profileSchool") ?? "" }
        set { defaults.set(newValue, forKey: "profileSchool") }
    }
    /// "IB Diploma Programme, year 1 (DP1)", "IB MYP 5", "A-levels"…
    static var programme: String {
        get { defaults.string(forKey: "profileProgramme") ?? "" }
        set { defaults.set(newValue, forKey: "profileProgramme") }
    }
    /// "Math AI HL, Economics HL, ESS SL…"
    static var subjects: String {
        get { defaults.string(forKey: "profileSubjects") ?? "" }
        set { defaults.set(newValue, forKey: "profileSubjects") }
    }
    /// A business, club or project of theirs that matters to their days ("WellPrepped"), or "".
    static var project: String {
        get { defaults.string(forKey: "profileProject") ?? "" }
        set { defaults.set(newValue, forKey: "profileProject") }
    }
    /// Done with the first-run setup.
    static var isSetUp: Bool {
        get { defaults.bool(forKey: "profileSetUp") }
        set { defaults.set(newValue, forKey: "profileSetUp") }
    }

    /// For Joe's instructions: who they are, in a sentence or two.
    static var description: String {
        var parts: [String] = []
        let who = [programme, school.isEmpty ? "" : "at \(school)"].filter { !$0.isEmpty }.joined(separator: " ")
        parts.append(who.isEmpty ? "They're a student." : "They're a student: \(who).")
        if !subjects.isEmpty { parts.append("Their subjects: \(subjects).") }
        if !project.isEmpty { parts.append("Outside class they run \(project).") }
        return parts.joined(separator: " ")
    }
}
