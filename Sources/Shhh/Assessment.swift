import Foundation

/// Tells an assessment sat in class (a test, an exam paper, an oral) from work handed in (an
/// upload, a draft, an essay written at home), so the plans revise for one and work on the other,
/// and a past exam isn't raised as "overdue · upload it".
///
/// It scores what ManageBac and the calendar give: the title, the description, the time (a
/// deadline during a class is sat in it, one at 23:59 is handed in) and explicit words ("in
/// class", "submit"). An explicit word wins; otherwise the score decides, and a tie is take-home.
enum Assessment {
    enum Kind: String { case inClass = "exam", takeHome = "take-home" }

    /// Words that mean it's sat: an exam, a test, a paper, an oral.
    private static let sat = #"\b(exam|exams|test|quiz|mock|paper\s*[123]|p[123]|unit test|oral|io|individual oral|viva|presentation|listening|reading comprehension|timed|sit)\b"#
    /// Words that only ever mean it's sat, whatever else the title says.
    private static let surelySat = #"\b(in[- ]class|during class|in lesson|exam conditions|closed[- ]book|under timed conditions|test day)\b"#
    /// Words that mean it's handed in.
    private static let handedIn = #"\b(homework|hw|upload|submit|submission|hand in|turnitin|draft|bibliography|reflection|worksheet|portfolio|outline|proposal|write[- ]up|lab report|report|research|notes|prep|preparation|practice|revision)\b"#
    /// Words that only ever mean it's handed in.
    private static let surelyHandedIn = #"\b(take[- ]home|upload to|submit (it )?(on|to|via)|dropbox|due by 23|online submission)\b"#

    static func kind(_ item: CalendarFeed.Item) -> Kind {
        guard item.kind == .deadline, item.subject != "project" else { return .takeHome }
        let text = item.title + " " + item.detail
        func has(_ pattern: String) -> Bool { text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil }
        if has(surelySat) { return .inClass }
        if has(surelyHandedIn) { return .takeHome }
        var score = 0
        if has(sat) { score += 2 }
        if has(handedIn) { score -= 2 }
        // A timed deadline: during one of that day's classes it's sat there; late at night it's handed in.
        if !item.allDay {
            let calendar = Calendar.current
            let hour = calendar.component(.hour, from: item.start)
            if hour >= 22 || hour < 6 {
                score -= 2
            } else if Daybook.timeline(item.start).contains(where: { slot in
                slot.kind == .lesson && slot.start <= item.start && item.start < (slot.end ?? slot.start.addingTimeInterval(3600))
            }) {
                score += 1
            }
        }
        return score > 0 ? .inClass : .takeHome
    }

    static func isInClass(_ item: CalendarFeed.Item) -> Bool { kind(item) == .inClass }

    /// Words for something done, not studied for: a form, a payment, bringing a thing.
    private static let errand = #"\b(form|permission slip|consent|sign|signed|payment|pay|fee|bring|return (the|your)|uniform|photo|ticket|sign[- ]up|register|registration|attendance|meeting|trip|level changes?)\b"#

    /// Whether it's worth a study block. An errand ("bring signed trip form") isn't; neither is
    /// something both sat and an errand ("register for the oral"), which is the errand.
    static func needsStudy(_ item: CalendarFeed.Item) -> Bool {
        guard item.subject != "project" else { return true }
        return (item.title + " " + item.detail).range(of: errand, options: [.regularExpression, .caseInsensitive]) == nil
    }

    /// What a study block for a sat assessment starts with: "revise for Chinese Paper 1".
    static let revise = "revise for "

    /// "exam tomorrow 10:00" or "due Thu 29 Oct", for a plan or task line.
    static func due(_ item: CalendarFeed.Item, _ now: Date) -> String {
        (isInClass(item) ? "exam " : "due ") + Daybook.when(item, now)
    }
}
