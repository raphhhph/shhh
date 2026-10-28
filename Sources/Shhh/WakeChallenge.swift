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

    /// How many challenges have rung today (0 for the first), counted as each one rings.
    static func nextRing() -> Int {
        let today = Date().formatted(.localDay)
        let defaults = UserDefaults.standard
        let count = defaults.string(forKey: "wakeChallengeDay") == today ? defaults.integer(forKey: "wakeChallengeCount") : 0
        defaults.set(today, forKey: "wakeChallengeDay")
        defaults.set(count + 1, forKey: "wakeChallengeCount")
        return count
    }

    static func applies(to alarm: Alarm) -> Bool {
        guard isEnabled, alarm.kind == .alarm else { return false }
        // "Wake up" at any hour (a nap, a night shift, a test) gets one too.
        if alarm.title.range(of: #"\bwake\b"#, options: [.regularExpression, .caseInsensitive]) != nil { return true }
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
            // A different subject each time, then the next fact in it.
            let pool = facts(for: subjects)
            let names = Array(Set(pool.map(\.subject))).sorted()
            let subject = names[(day / 3) % names.count]
            let inSubject = pool.filter { $0.subject == subject }
            let fact = inSubject[(day / 3 / names.count) % inSubject.count]
            return WakeChallenge(kind: .fact, prompt: fact.text, source: fact.subject + " · " + fact.topic, answers: [])
        default:
            let pool = questions(for: subjects)
            let names = Array(Set(pool.map(\.subject))).sorted()
            let subject = names[(day / 3 + seed) % names.count]
            let inSubject = pool.filter { $0.subject == subject }
            let question = inSubject[(day / 3 / names.count) % inSubject.count]
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
        case .fact: "Hold right ⌥ and read this \(source.components(separatedBy: " · ")[0]) fact aloud"
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
    /// Chinese in a fact ("尊敬的 opens a formal letter") is counted a character at a time, and only
    /// when the speech recogniser wrote Chinese: the English one hears 尊敬的 as "zun jing de" or
    /// nonsense, which made the Chinese B facts nearly impossible to pass.
    static func readAloud(_ heard: String, matches passage: String) -> Bool {
        let hanzi = heard.unicodeScalars.contains(where: isHan)
        let target = words(passage).filter { hanzi || !$0.unicodeScalars.contains(where: isHan) }
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
            .flatMap { word -> [String] in
                // Chinese has no spaces: each character is a word.
                word.unicodeScalars.contains(where: isHan) ? word.map(String.init) : [word]
            }
            .filter { ($0.count > 1 || $0.unicodeScalars.contains(where: isHan)) && !small.contains($0) }
    }

    private static func isHan(_ scalar: Unicode.Scalar) -> Bool {
        (0x4E00...0x9FFF).contains(scalar.value) || (0x3400...0x4DBF).contains(scalar.value)
    }

    // MARK: Content

    /// Their subjects, from Settings (all of them when none are set).
    private static var subjects: [String] {
        Profile.subjects.components(separatedBy: ",").compactMap { StudyBuddy.pack(for: $0) ?? otherSubject($0) }
    }

    /// Subjects with challenges but no Study pack yet, so a student taking them gets their own facts.
    private static func otherSubject(_ subject: String) -> String? {
        let words = subject.lowercased()
        let keys: [(String, [String])] = [
            ("Biology", ["biology", "bio "]),
            ("Chemistry", ["chemistry", "chem "]),
            ("Physics", ["physics"]),
            ("History", ["history"]),
            ("Psychology", ["psychology", "psych "]),
            ("Mathematics AA", ["math aa", "maths aa", "analysis and approaches", "a&a"]),
            ("Geography", ["geography"]),
        ]
        return keys.first { entry in entry.1.contains { (words + " ").contains($0) } }?.0
    }

    private struct Fact { let subject: String; let topic: String; let text: String }
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

    /// Facts worth knowing for the exams: dated real-world examples for evaluation, case studies,
    /// exam technique and useful language, each with the topic it's for.
    private static let allFacts: [Fact] = [
        Fact(subject: "Economics", topic: "2.7 Indirect taxes on demerit goods", text: "Mexico's 2014 tax of one peso per litre on sugary drinks cut purchases by about 6% in its first year, and by 12% by the end of that year."),
        Fact(subject: "Economics", topic: "2.8 Tradable permits", text: "The EU Emissions Trading System, started in 2005, caps emissions and lets firms trade permits. By 2023, emissions in the sectors it covers were about 47% below 2005 levels."),
        Fact(subject: "Economics", topic: "3.5 Monetary policy", text: "The Bank of Japan kept interest rates negative from 2016 to March 2024 to fight deflation, the last major central bank to leave negative rates."),
        Fact(subject: "Economics", topic: "3.3 Inflation and 3.5 Monetary policy", text: "US inflation peaked at 9.1% in June 2022, a four-decade high, and the Federal Reserve raised interest rates from near zero to over 5% in about a year."),
        Fact(subject: "Economics", topic: "2.8 Negative externalities", text: "Singapore's Electronic Road Pricing, started in 1998, charges drivers to use busy roads at peak times: a real-world fix for the externality of congestion."),
        Fact(subject: "Economics", topic: "2.11 Oligopoly and collusion", text: "In October 2022, OPEC+ agreed to cut oil output by 2 million barrels a day to hold prices up: collusive oligopoly in action."),
        Fact(subject: "Economics", topic: "4.2 Tariffs", text: "In 2018 the US put tariffs of 25% on steel and 10% on aluminium imports. Studies found almost all of the cost was passed on to American buyers."),
        Fact(subject: "Business Management", topic: "4.5 Product life cycle and 5.8 Innovation", text: "Kodak built the first digital camera in 1975 but held it back to protect its film business, and filed for bankruptcy in 2012."),
        Fact(subject: "Business Management", topic: "5.6 Just-in-time vs just-in-case", text: "After the 2011 Fukushima earthquake, Toyota began keeping buffer stocks of key chips, so in the 2021 chip shortage it kept producing longer than its rivals."),
        Fact(subject: "Business Management", topic: "1.3 Corporate social responsibility", text: "In 2022, Patagonia's founder gave the company to a trust and a non-profit, so all profits not reinvested go to fighting climate change."),
        Fact(subject: "Business Management", topic: "1.5 Growth and change", text: "Nokia sold around 40% of the world's mobile phones in 2008, but sold its phone business to Microsoft in 2013 after missing the smartphone shift."),
        Fact(subject: "Business Management", topic: "2.1 Training and 5.3 Quality", text: "In 2008, Starbucks closed over 7,000 American stores for an afternoon to retrain baristas, to restore the quality of its coffee."),
        Fact(subject: "Business Management", topic: "Ansoff matrix", text: "Netflix moved from posting DVDs to streaming in 2007, replacing its own business before a rival could: product development on Ansoff's matrix."),
        Fact(subject: "Environmental Systems and Societies", topic: "4.2 Water security", text: "The Aral Sea lost about 90% of its volume after the Soviet Union diverted its rivers for cotton irrigation from the 1960s."),
        Fact(subject: "Environmental Systems and Societies", topic: "2.1 Trophic cascades", text: "When wolves were brought back to Yellowstone in 1995, elk grazed less along rivers and riverside trees recovered: a classic trophic cascade."),
        Fact(subject: "Environmental Systems and Societies", topic: "6.4 Stratospheric ozone", text: "Thanks to the 1987 Montreal Protocol, the ozone layer over Antarctica is expected to recover to its 1980 level around 2066."),
        Fact(subject: "Environmental Systems and Societies", topic: "3.3 Conservation", text: "Since 1997, Costa Rica has paid landowners to protect forest. Forest cover has risen from about a fifth of the country in the 1980s to over half today."),
        Fact(subject: "Environmental Systems and Societies", topic: "4.4 Eutrophication", text: "In 2007 an algal bloom in Lake Taihu cut off drinking water for about two million people in Wuxi: eutrophication from farm and factory runoff."),
        Fact(subject: "Environmental Systems and Societies", topic: "7.2 Energy choices", text: "China's Three Gorges Dam, the world's largest power station, displaced about 1.3 million people: renewable energy with real social costs."),
        Fact(subject: "Mathematics AI", topic: "1.4 Financial mathematics", text: "The rule of 72: divide 72 by the annual interest rate to estimate the years to double. At 6%, money doubles in about 12 years."),
        Fact(subject: "Mathematics AI", topic: "4.9 Normal distribution", text: "In a normal distribution, about 68% of values lie within one standard deviation of the mean, 95% within two, and 99.7% within three."),
        Fact(subject: "Mathematics AI", topic: "4.11 Chi-squared tests", text: "In a chi-squared test every expected frequency must be at least 5. If not, combine categories, which reduces the degrees of freedom."),
        Fact(subject: "Mathematics AI", topic: "4.4 and 4.10 Correlation", text: "A Pearson's r near zero only rules out a linear relationship. Spearman's rank measures any relationship that keeps going one way."),
        Fact(subject: "Mathematics AI", topic: "Exam technique", text: "Give final answers to three significant figures unless told otherwise, and never round in the middle of a calculation: early rounding loses accuracy marks."),
        Fact(subject: "English A Language and Literature", topic: "Paper 1", text: "Paper 1 rewards a clear thesis that answers the guiding question, then how each technique creates an effect on the reader, not a list of devices."),
        Fact(subject: "English A Language and Literature", topic: "Individual oral", text: "In the individual oral, one global issue must run through both your literary and non-literary text: ten minutes of talk, then five of questions."),
        Fact(subject: "English A Language and Literature", topic: "Analysing advertisements", text: "Ads use the second person and imperatives for direct address and urgency. Name the technique, quote it, then explain its effect on the target audience."),
        Fact(subject: "Chinese B", topic: "Paper 1 formal letter", text: "A formal letter opens with 尊敬的, and ends with 此致 then 敬礼 on the next line, your name and the date. Register is marked."),
        Fact(subject: "Chinese B", topic: "Useful idiom", text: "一举两得 means one action, two gains. Use it in an essay about a solution with two benefits, like cycling to school."),
        Fact(subject: "Chinese B", topic: "Sharing the planet", text: "可持续发展 means sustainable development, 温室气体 means greenhouse gases, and 节能减排 means saving energy and cutting emissions."),
        Fact(subject: "Chinese B", topic: "Giving opinions", text: "Balance an argument with 一方面 and 另一方面, on one hand and on the other, then conclude with 总的来说, overall."),
        Fact(subject: "Theory of Knowledge", topic: "Classification and knowledge", text: "Pluto was reclassified as a dwarf planet in 2006, not because Pluto changed but because the definition of a planet did."),
        Fact(subject: "Theory of Knowledge", topic: "Human sciences: reliability", text: "In 2015 a large project tried to repeat 100 published psychology studies and got the same significant result in only about 36% of them."),
        Fact(subject: "Theory of Knowledge", topic: "Natural sciences: ethics", text: "Thalidomide was sold from 1957 as safe in pregnancy and caused birth defects in over 10,000 babies before it was withdrawn."),
        Fact(subject: "Theory of Knowledge", topic: "Shared knowledge", text: "A 2005 study in Nature found Wikipedia's science articles about as accurate as Encyclopaedia Britannica's, though anyone can edit them."),
        Fact(subject: "Biology", topic: "Enzymes", text: "Most human enzymes work best near 37 degrees. Well above their optimum the active site changes shape: the enzyme is denatured, and that can't be undone."),
        Fact(subject: "Biology", topic: "Cell structure", text: "Prokaryotic cells have no nucleus and small 70S ribosomes. Eukaryotic cells have 80S ribosomes, but their mitochondria and chloroplasts still carry 70S ones."),
        Fact(subject: "Biology", topic: "Antibiotic resistance", text: "Antibiotics kill bacteria but not viruses, which have no metabolism of their own. Overusing them selects for resistant bacteria such as MRSA."),
        Fact(subject: "Biology", topic: "Exam technique", text: "Outline means a brief account; explain means give reasons. In an explain answer, every point needs its because."),
        Fact(subject: "Chemistry", topic: "Equilibrium", text: "Le Chatelier's principle: a system at equilibrium shifts to oppose a change. A catalyst moves neither the position nor the constant, it only gets there faster."),
        Fact(subject: "Chemistry", topic: "The Haber process", text: "The Haber process makes ammonia from nitrogen and hydrogen over an iron catalyst at about 450 degrees: a compromise between yield and rate."),
        Fact(subject: "Chemistry", topic: "The mole", text: "One mole holds 6.02 times ten to the 23 particles, and one mole of an ideal gas fills 22.7 cubic decimetres at STP in the IB data booklet."),
        Fact(subject: "Chemistry", topic: "Exam technique", text: "Give units with every answer and state symbols in every equation that asks for them: both are easy marks to lose."),
        Fact(subject: "Physics", topic: "Energy", text: "Kinetic energy is half m v squared, so doubling your speed makes four times the kinetic energy: why braking distances grow so fast."),
        Fact(subject: "Physics", topic: "Radioactive decay", text: "Half-life is the time for half the radioactive nuclei to decay. After three half-lives, one eighth of the original nuclei remain."),
        Fact(subject: "Physics", topic: "Waves", text: "Light from the Sun takes about eight minutes and twenty seconds to reach Earth: you always see the Sun as it was."),
        Fact(subject: "Physics", topic: "Exam technique", text: "Use g as 9.81 metres per second squared from the data booklet, and match the significant figures of the data you were given."),
        Fact(subject: "History", topic: "Cold War", text: "The Berlin Wall went up in August 1961 and fell on 9 November 1989. Germany reunified less than a year later, on 3 October 1990."),
        Fact(subject: "History", topic: "World War One", text: "The Treaty of Versailles was signed on 28 June 1919, five years to the day after Franz Ferdinand was shot in Sarajevo."),
        Fact(subject: "History", topic: "Rise of authoritarian states", text: "Mao Zedong proclaimed the People's Republic of China on 1 October 1949, after the Communists won the civil war against the Guomindang."),
        Fact(subject: "History", topic: "Source analysis", text: "For a source's value and limitations, use origin, purpose and content, and tie each point to the question, not to sources in general."),
        Fact(subject: "Psychology", topic: "Memory", text: "Patient HM had parts of both hippocampi removed in 1953. Afterwards he could not form new long-term memories of facts and events."),
        Fact(subject: "Psychology", topic: "Conformity", text: "In Asch's line study, about 75% of participants went along with the group's wrong answer at least once."),
        Fact(subject: "Psychology", topic: "Research methods", text: "A correlation can't show cause and effect. Only an experiment, where the independent variable is changed on purpose, can."),
        Fact(subject: "Psychology", topic: "Memory", text: "Miller's 1956 paper suggested short-term memory holds about seven items, plus or minus two."),
        Fact(subject: "Mathematics AA", topic: "Calculus", text: "The derivative of sine x is cosine x, and of cosine x is minus sine x, but only with angles in radians."),
        Fact(subject: "Mathematics AA", topic: "Proof by induction", text: "Induction needs a base case, the step from n equals k to n equals k plus one, and a concluding sentence: the sentence carries a mark."),
        Fact(subject: "Mathematics AA", topic: "Exam technique", text: "Paper 1 has no calculator: know exact values, like sine of thirty degrees is one half and cosine of sixty degrees is one half."),
        Fact(subject: "Geography", topic: "Population", text: "Japan's population peaked around 2008 at about 128 million and has fallen since: a key case study of an ageing population."),
        Fact(subject: "Geography", topic: "Climate change", text: "The 2015 Paris Agreement aims to keep warming well below 2 degrees, and to try for 1.5 degrees, above pre-industrial levels."),
        Fact(subject: "Geography", topic: "Hazards", text: "The 2004 Indian Ocean tsunami, set off by a magnitude 9.1 earthquake near Sumatra, killed about 230,000 people in 14 countries."),
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
        Question(subject: "Biology", text: "Which organelle is the site of aerobic respiration?", answers: ["mitochondria", "mitochondrion"]),
        Question(subject: "Biology", text: "How many chromosomes are in a human body cell?", answers: ["46"]),
        Question(subject: "Biology", text: "Which molecule brings amino acids to the ribosome?", answers: ["trna", "t rna", "transfer"]),
        Question(subject: "Chemistry", text: "What is the pH of pure water at 25 degrees?", answers: ["7"]),
        Question(subject: "Chemistry", text: "Which group of the periodic table are the noble gases?", answers: ["18"]),
        Question(subject: "Physics", text: "What is the SI unit of force?", answers: ["newton"]),
        Question(subject: "Physics", text: "What is the SI unit of power?", answers: ["watt"]),
        Question(subject: "History", text: "In which year did World War Two end?", answers: ["1945", "19 45"]),
        Question(subject: "History", text: "Who led the Bolsheviks in the 1917 October Revolution?", answers: ["lenin"]),
        Question(subject: "Psychology", text: "Which brain structure, damaged in patient HM, is key to forming new memories?", answers: ["hippocampus", "hippocampi"]),
        Question(subject: "Psychology", text: "In an experiment, what do you call the variable the researcher changes?", answers: ["independent"]),
        Question(subject: "Mathematics AA", text: "What is log base 10 of 1000?", answers: ["3"]),
        Question(subject: "Mathematics AA", text: "What is the derivative of x squared?", answers: ["2x", "2 x"]),
        Question(subject: "Geography", text: "Which river does the Three Gorges Dam cross?", answers: ["yangtze", "yangzi", "chang jiang"]),
        Question(subject: "Geography", text: "What is the largest ocean?", answers: ["pacific"]),
    ]
}
