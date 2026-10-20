import Foundation

/// What a morning alarm makes you do before it stops: read a Bible verse aloud, read a fun fact
/// from one of your IB subjects, or answer a quick question from one. They take turns, a different
/// one each day. Checked on the Mac (no Claude, no network), so it works at 6 am offline.
struct WakeChallenge: Equatable {
    enum Kind: String { case verse, fact, question }
    let kind: Kind
    /// What's shown: the verse or fact to read, or the question.
    let prompt: String
    /// Where it's from: "Psalm 118:24", "Economics", …
    let source: String
    /// For a question: the accepted answers (a number, or words any of which is enough).
    let answers: [String]

    /// "Settings → Alarms → Wake-up challenge": on by default, for alarms between 4:00 and 11:00.
    static var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "wakeChallenge") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "wakeChallenge") }
    }

    static func applies(to alarm: Alarm) -> Bool {
        guard isEnabled, alarm.kind == .alarm else { return false }
        let hour = Calendar.current.component(.hour, from: alarm.fireAt)
        return (4..<11).contains(hour)
    }

    /// Today's challenge: verse, fact and question take turns by day; within each, a new one each time.
    static func today(seed: Int = 0) -> WakeChallenge {
        let day = (Calendar.current.ordinality(of: .day, in: .era, for: Date()) ?? 0) + seed
        switch day % 3 {
        case 0:
            let verse = verses[(day / 3) % verses.count]
            return WakeChallenge(kind: .verse, prompt: verse.text, source: verse.reference, answers: [])
        case 1:
            let pool = facts(for: subjects)
            let fact = pool[(day / 3) % pool.count]
            return WakeChallenge(kind: .fact, prompt: fact.text, source: fact.subject, answers: [])
        default:
            let pool = questions(for: subjects)
            let question = pool[(day / 3 + seed) % pool.count]
            return WakeChallenge(kind: .question, prompt: question.text, source: question.subject, answers: question.answers)
        }
    }

    /// Something easier after two misses: today's question swapped for another one.
    func another() -> WakeChallenge {
        guard kind == .question else { return self }
        let pool = Self.questions(for: Self.subjects)
        let next = pool[((pool.firstIndex { $0.text == prompt } ?? 0) + 1) % pool.count]
        return WakeChallenge(kind: .question, prompt: next.text, source: next.subject, answers: next.answers)
    }

    var instruction: String {
        switch kind {
        case .verse: "Hold right ⌥ and read this verse aloud"
        case .fact: "Hold right ⌥ and read this \(source) fact aloud"
        case .question: "Hold right ⌥ and answer this \(source) question"
        }
    }

    // MARK: Checking

    /// Whether what they said passes: most of the words read, or the right answer.
    func check(_ heard: String) -> Bool {
        switch kind {
        case .verse, .fact: Self.readAloud(heard, matches: prompt)
        case .question: Self.answers(heard, accepts: answers)
        }
    }

    /// Reading counts when at least 60% of the passage's words were heard, in any order (speech
    /// recognition mishears old words like "thee" and "hath"; a mumbled half doesn't pass).
    static func readAloud(_ heard: String, matches passage: String) -> Bool {
        let target = words(passage)
        let said = Set(words(heard))
        guard !target.isEmpty else { return true }
        let found = target.filter { said.contains($0) }.count
        return Double(found) / Double(target.count) >= 0.6
    }

    static func answers(_ heard: String, accepts accepted: [String]) -> Bool {
        let text = " " + AlarmRequest.numbers(in: " " + heard.lowercased() + " ") + " "
        for answer in accepted {
            if let value = Double(answer) {
                // Any number said that equals it ("two", "2", "2.0").
                let numbers = text.components(separatedBy: CharacterSet(charactersIn: "0123456789.").inverted).compactMap(Double.init)
                if numbers.contains(where: { abs($0 - value) < 0.001 }) { return true }
            } else if text.contains(answer.lowercased()) || heard.contains(answer) {
                return true
            }
        }
        return false
    }

    private static func words(_ text: String) -> [String] {
        let small: Set = ["the", "a", "an", "and", "of", "to", "in", "is", "it", "for", "on", "be", "as", "that", "with"]
        return text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count > 1 && !small.contains($0) }
    }

    // MARK: Content

    /// Their subjects, from Settings (all of them when none are set).
    private static var subjects: [String] {
        Profile.subjects.components(separatedBy: ",").compactMap { StudyBuddy.pack(for: $0) }
    }

    private struct Fact { let subject: String; let text: String }
    private struct Question { let subject: String; let text: String; let answers: [String] }

    private static func facts(for subjects: [String]) -> [Fact] {
        let mine = allFacts.filter { subjects.contains($0.subject) || subjects.isEmpty }
        return mine.isEmpty ? allFacts : mine
    }

    private static func questions(for subjects: [String]) -> [Question] {
        let mine = allQuestions.filter { subjects.contains($0.subject) || subjects.isEmpty }
        return mine.isEmpty ? allQuestions : mine
    }

    /// King James Version (public domain).
    private static let verses: [(reference: String, text: String)] = [
        ("Psalm 118:24", "This is the day which the LORD hath made; we will rejoice and be glad in it."),
        ("Lamentations 3:22–23", "It is of the LORD's mercies that we are not consumed, because his compassions fail not. They are new every morning: great is thy faithfulness."),
        ("Philippians 4:13", "I can do all things through Christ which strengtheneth me."),
        ("Joshua 1:9", "Be strong and of a good courage; be not afraid, neither be thou dismayed: for the LORD thy God is with thee whithersoever thou goest."),
        ("Proverbs 3:5–6", "Trust in the LORD with all thine heart; and lean not unto thine own understanding. In all thy ways acknowledge him, and he shall direct thy paths."),
        ("Isaiah 40:31", "But they that wait upon the LORD shall renew their strength; they shall mount up with wings as eagles; they shall run, and not be weary; and they shall walk, and not faint."),
        ("Psalm 5:3", "My voice shalt thou hear in the morning, O LORD; in the morning will I direct my prayer unto thee, and will look up."),
        ("Colossians 3:23", "And whatsoever ye do, do it heartily, as to the Lord, and not unto men."),
        ("Proverbs 6:9", "How long wilt thou sleep, O sluggard? when wilt thou arise out of thy sleep?"),
        ("Psalm 143:8", "Cause me to hear thy lovingkindness in the morning; for in thee do I trust: cause me to know the way wherein I should walk; for I lift up my soul unto thee."),
        ("Matthew 6:34", "Take therefore no thought for the morrow: for the morrow shall take thought for the things of itself. Sufficient unto the day is the evil thereof."),
        ("2 Timothy 1:7", "For God hath not given us the spirit of fear; but of power, and of love, and of a sound mind."),
        ("Ephesians 5:14", "Awake thou that sleepest, and arise from the dead, and Christ shall give thee light."),
        ("Psalm 90:14", "O satisfy us early with thy mercy; that we may rejoice and be glad all our days."),
        ("Proverbs 16:3", "Commit thy works unto the LORD, and thy thoughts shall be established."),
        ("Isaiah 41:10", "Fear thou not; for I am with thee: be not dismayed; for I am thy God: I will strengthen thee; yea, I will help thee."),
        ("Galatians 6:9", "And let us not be weary in well doing: for in due season we shall reap, if we faint not."),
        ("Psalm 46:1", "God is our refuge and strength, a very present help in trouble."),
        ("Proverbs 20:13", "Love not sleep, lest thou come to poverty; open thine eyes, and thou shalt be satisfied with bread."),
        ("Psalm 30:5", "Weeping may endure for a night, but joy cometh in the morning."),
        ("Mark 1:35", "And in the morning, rising up a great while before day, he went out, and departed into a solitary place, and there prayed."),
        ("Psalm 119:105", "Thy word is a lamp unto my feet, and a light unto my path."),
    ]

    private static let allFacts: [Fact] = [
        Fact(subject: "Economics", text: "Zimbabwe's inflation hit an estimated 79.6 billion percent a month in November 2008, so prices roughly doubled every day."),
        Fact(subject: "Economics", text: "The Big Mac Index was started by The Economist in 1986 as a light-hearted way to test purchasing power parity."),
        Fact(subject: "Economics", text: "Adam Smith used the phrase invisible hand only three times in all of his writing."),
        Fact(subject: "Economics", text: "The Gini coefficient was published by the Italian statistician Corrado Gini in 1912."),
        Fact(subject: "Business Management", text: "Kodak engineer Steven Sasson built the first digital camera in 1975, but Kodak held back to protect its film business."),
        Fact(subject: "Business Management", text: "Toyota's just-in-time system was inspired by how American supermarkets restocked shelves only as items sold."),
        Fact(subject: "Business Management", text: "Frederick Herzberg found that pay is a hygiene factor: poor pay demotivates, but more pay rarely motivates for long."),
        Fact(subject: "Mathematics AI", text: "If you shuffle a deck of cards properly, that exact order has almost certainly never existed before in history."),
        Fact(subject: "Mathematics AI", text: "Graph theory began in 1736 when Leonhard Euler proved you couldn't walk the seven bridges of Königsberg crossing each exactly once."),
        Fact(subject: "Mathematics AI", text: "In a room of just twenty three people, there's a better than even chance that two share a birthday."),
        Fact(subject: "Environmental Systems and Societies", text: "Only about ten percent of the energy at one trophic level passes on to the next, which is why food chains are short."),
        Fact(subject: "Environmental Systems and Societies", text: "The Montreal Protocol of 1987 is the only UN treaty ratified by every country in the world."),
        Fact(subject: "Environmental Systems and Societies", text: "Phytoplankton in the ocean produce roughly half of the oxygen on Earth."),
        Fact(subject: "English A Language and Literature", text: "Shakespeare is credited with being the first recorded user of more than a thousand English words, including lonely and swagger."),
        Fact(subject: "English A Language and Literature", text: "The word nice once meant foolish or ignorant, from the Latin nescius, meaning not knowing."),
        Fact(subject: "Chinese B", text: "The Chinese word for crisis is often said to mean danger plus opportunity, but the second character really means a crucial point."),
        Fact(subject: "Chinese B", text: "Mandarin has four main tones, so the syllable ma can mean mother, hemp, horse or to scold."),
        Fact(subject: "Theory of Knowledge", text: "Pluto was reclassified as a dwarf planet in 2006, not because it changed, but because astronomers changed the definition of a planet."),
        Fact(subject: "Theory of Knowledge", text: "Karl Popper argued a theory is scientific only if it could, in principle, be proved false."),
    ]

    private static let allQuestions: [Question] = [
        Question(subject: "Economics", text: "If the marginal propensity to consume is 0.8, what is the multiplier?", answers: ["5"]),
        Question(subject: "Economics", text: "Price rises by 10% and quantity demanded falls by 20%. What is the PED, ignoring the minus sign?", answers: ["2"]),
        Question(subject: "Economics", text: "What do we call a good whose demand falls when income rises?", answers: ["inferior"]),
        Question(subject: "Economics", text: "Nominal GDP grows by 5% and inflation is 3%. Roughly what is real GDP growth, in percent?", answers: ["2"]),
        Question(subject: "Economics", text: "What is a tax that corrects a negative externality called?", answers: ["pigou", "pigovian", "pigouvian"]),
        Question(subject: "Business Management", text: "Fixed costs are 1,000 dollars, the price is 15 and variable cost is 5 per unit. What is the break-even quantity?", answers: ["100"]),
        Question(subject: "Business Management", text: "Revenue is 200 and gross profit is 40. What is the gross profit margin, in percent?", answers: ["20"]),
        Question(subject: "Business Management", text: "Current assets are 300 and current liabilities are 150. What is the current ratio?", answers: ["2"]),
        Question(subject: "Business Management", text: "Which motivation theorist described hygiene factors?", answers: ["herzberg"]),
        Question(subject: "Mathematics AI", text: "What is 15 percent of 80?", answers: ["12"]),
        Question(subject: "Mathematics AI", text: "What is the next term: 2, 6, 18, …?", answers: ["54"]),
        Question(subject: "Mathematics AI", text: "What is the gradient of y equals x squared at x equals 3?", answers: ["6"]),
        Question(subject: "Mathematics AI", text: "What is log base 10 of 1,000?", answers: ["3"]),
        Question(subject: "Mathematics AI", text: "What is the sum of the whole numbers from 1 to 10?", answers: ["55"]),
        Question(subject: "Environmental Systems and Societies", text: "Roughly what percentage of energy passes to the next trophic level?", answers: ["10"]),
        Question(subject: "Environmental Systems and Societies", text: "Which gas makes up about 78% of the atmosphere?", answers: ["nitrogen"]),
        Question(subject: "Environmental Systems and Societies", text: "With the rule of 70, how many years does a population growing at 2% a year take to double?", answers: ["35"]),
        Question(subject: "Environmental Systems and Societies", text: "Which 1987 agreement phased out CFCs?", answers: ["montreal"]),
        Question(subject: "English A Language and Literature", text: "What is a comparison using like or as called?", answers: ["simile"]),
        Question(subject: "English A Language and Literature", text: "What is repeating a word at the start of successive clauses called?", answers: ["anaphora"]),
        Question(subject: "Chinese B", text: "How do you say good morning in Chinese?", answers: ["早上好", "早安", "zao shang hao", "zaoshang hao"]),
        Question(subject: "Chinese B", text: "How do you say teacher in Chinese?", answers: ["老师", "lao shi", "laoshi"]),
        Question(subject: "Theory of Knowledge", text: "Name one of the five areas of knowledge in TOK.", answers: ["history", "human science", "natural science", "mathematics", "math", "the arts", "arts"]),
    ]
}
