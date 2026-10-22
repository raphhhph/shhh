import Foundation

extension Profile {
    /// They picked an MYP programme in onboarding: subjects have no HL/SL, every subject is marked
    /// on criteria A–D out of 8, and the final grade is 1–7 from the total out of 32.
    static var isMYP: Bool { programme.uppercased().contains("MYP") }

    /// 1–5 from "IB MYP, year 4 (MYP4)"; 2 for "years 1–3"; nil outside the MYP.
    static var mypYear: Int? {
        guard isMYP else { return nil }
        if let match = programme.range(of: #"MYP\s?([1-5])\b"#, options: .regularExpression),
           let year = Int(programme[match].suffix(1)) { return year }
        if programme.contains("1–3") || programme.contains("1-3") { return 2 }
        return nil
    }
}

/// The MYP framework as Joe uses it: subject groups with their criteria A–D, the 1–7 grade
/// boundaries, the Personal Project, global contexts and ATL skills. The full descriptors are in
/// Resources/Syllabus/MYP.md, which the tutor reads.
enum MYP {
    struct Group {
        let name: String
        let symbol: String
        let subjects: [String]
        let criteria: [String] // A, B, C, D
        let keywords: [String]
    }

    static let groups: [Group] = [
        Group(name: "Language & literature", symbol: "book", subjects: ["English Language & Literature", "Chinese Language & Literature", "Indonesian Language & Literature"],
              criteria: ["Analysing", "Organizing", "Producing text", "Using language"], keywords: ["language & literature", "language and literature", "lang & lit", "lang and lit", "l&l", "english a", "chinese a"]),
        Group(name: "Language acquisition", symbol: "character.bubble", subjects: ["English acquisition", "Chinese acquisition", "Spanish acquisition", "French acquisition", "Indonesian acquisition"],
              criteria: ["Listening", "Reading", "Speaking", "Writing"], keywords: ["acquisition", "chinese b", "english b", "spanish", "french", "mandarin", "phase"]),
        Group(name: "Individuals & societies", symbol: "person.3", subjects: ["Individuals & Societies", "History", "Geography", "Economics", "Business"],
              criteria: ["Knowing and understanding", "Investigating", "Communicating", "Thinking critically"], keywords: ["individuals", "societies", "humanities", "history", "geography", "econ", "business", "i&s"]),
        Group(name: "Sciences", symbol: "atom", subjects: ["Integrated Sciences", "Biology", "Chemistry", "Physics"],
              criteria: ["Knowing and understanding", "Inquiring and designing", "Processing and evaluating", "Reflecting on the impacts of science"], keywords: ["science", "biology", "chemistry", "physics"]),
        Group(name: "Mathematics", symbol: "function", subjects: ["Mathematics (standard)", "Mathematics (extended)"],
              criteria: ["Knowing and understanding", "Investigating patterns", "Communicating", "Applying mathematics in real-life contexts"], keywords: ["math"]),
        Group(name: "Arts", symbol: "paintpalette", subjects: ["Visual Arts", "Music", "Drama", "Media Arts"],
              criteria: ["Investigating", "Developing", "Creating/performing", "Evaluating"], keywords: ["art", "music", "drama", "theatre", "media", "dance", "film"]),
        Group(name: "Physical & health education", symbol: "figure.run", subjects: ["Physical & Health Education"],
              criteria: ["Knowing and understanding", "Planning for performance", "Applying and performing", "Reflecting and improving performance"], keywords: ["phe", "physical", "health", "pe"]),
        Group(name: "Design", symbol: "hammer", subjects: ["Product Design", "Digital Design"],
              criteria: ["Inquiring and analysing", "Developing ideas", "Creating the solution", "Evaluating"], keywords: ["design"]),
    ]

    static let personalProject = ["Planning", "Applying skills", "Reflecting"]
    static let globalContexts = ["Identities and relationships", "Orientation in space and time", "Personal and cultural expression",
                                 "Scientific and technical innovation", "Globalization and sustainability", "Fairness and development"]
    static let atlSkills = ["Communication", "Social", "Self-management", "Research", "Thinking"]

    /// The group a subject belongs to, as the student or ManageBac wrote it.
    static func group(for subject: String) -> Group? {
        let words = " " + subject.lowercased() + " "
        // Language and literature before acquisition, so "Chinese Language & Literature" isn't acquisition.
        return groups.first { group in
            group.subjects.contains { $0.caseInsensitiveCompare(subject) == .orderedSame }
                || group.keywords.contains { keyword in
                    keyword.count <= 3 ? words.range(of: #"\b"# + NSRegularExpression.escapedPattern(for: keyword) + #"\b"#, options: .regularExpression) != nil
                                       : words.contains(keyword)
                }
        }
    }

    /// "A Knowing and understanding" … for a subject, or nil when its group is unknown.
    static func criteria(for subject: String) -> [(letter: String, name: String)]? {
        group(for: subject).map { group in zip(["A", "B", "C", "D"], group.criteria).map { ($0, $1) } }
    }

    /// The IB's MYP grade boundaries: total of the four criteria (0–32) → final grade 1–7.
    static func grade(total: Int) -> Int {
        switch total {
        case ..<6: 1
        case 6...9: 2
        case 10...14: 3
        case 15...18: 4
        case 19...23: 5
        case 24...27: 6
        default: 7
        }
    }

    /// For the tutor's instructions: how to test and mark this subject the MYP way.
    static func prompt(subject: String) -> String {
        let year = Profile.mypYear
        let list = criteria(for: subject).map { $0.map { "criterion \($0.letter) \($0.name)" }.joined(separator: ", ") }
        return """
            # MYP
            They're in the MYP (\(Profile.programme)), not the Diploma: no HL/SL, no DP papers, no TOK/EE/CAS. \
            \(list.map { "This subject is marked on \($0) (each 0–8)." } ?? "Work out the subject group and use its four criteria (each 0–8).") \
            Name the criterion each question targets in its topic ("Criterion A: Knowing and understanding · Cells"), and mark on that \
            criterion's level out of 8 (score="6" total="8"): pick the best-fit band (1–2 limited, 3–4 adequate, 5–6 substantial, \
            7–8 excellent) from the descriptor, then the mark within it, and say why in the descriptor's words. Most questions target \
            criterion A (knowledge), but set at least one on B, C or D (investigating, communicating, applying or evaluating) in a quiz.
            - Frame application questions in a real-world situation and name its global context (\(globalContexts.joined(separator: "; "))). \
            When feedback points at a skill gap, name the ATL skill (\(atlSkills.joined(separator: ", "))) to work on.
            - Level: \(year.map { $0 <= 3 ? "MYP \($0): simple, familiar contexts and short answers." : "MYP \($0): eAssessment style, unfamiliar contexts, longer reasoning." } ?? "fit the year they're in.")
            - Exam mode means one eAssessment-style task\(year == 5 ? " (on-screen exam style: a stimulus, then tasks across criteria A–D)" : ""), marked criterion by criterion.
            - The summary gives each criterion practised as a level out of 8, and the MYP grade (1–7) the four would make together \
            when all four were marked (boundaries 1–5→1, 6–9→2, 10–14→3, 15–18→4, 19–23→5, 24–27→6, 28–32→7).
            \(year == 5 || year == nil ? "- Personal Project (MYP 5): when they ask about it, coach and mark on A Planning, B Applying skills, C Reflecting (each 0–8); a product plus a report. Help them plan and reflect; never write the report for them.\n" : "")
            """
    }
}
