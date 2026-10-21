import EventKit
import AppKit
import AVFoundation
import SwiftUI
import UniformTypeIdentifiers

/// The first launch, as a window of its own: Joe says hi at the notch, learns the user's name,
/// shows what he does in short animations, sets up school, notes, permissions and Claude, and ends
/// with the user's first real request. Replayable from Settings → General without losing anything
/// (everything is prefilled from what's saved).
@MainActor
final class Onboarding: NSObject, NSWindowDelegate {
    struct Actions {
        /// Joe at the notch, out loud: a subject line and a sentence.
        var greet: (_ subject: String, _ line: String) -> Void
        /// Joe talking over the tour: stops whatever he was saying and says this instead.
        var narrate: (_ subject: String, _ line: String) -> Void
        /// Whether he's still talking, to move on when he's done.
        var isSpeaking: () -> Bool
        /// Loads his voice early, so the tour isn't silent while it loads.
        var prepareVoice: () -> Void
        /// "Get Joe ready": starts (or retries) one model's download.
        var download: (ModelGuard.Model) -> Void = { _ in }
        var chooseVault: () -> Void
        var finished: () -> Void
    }

    let model: OnboardingModel
    private var window: NSWindow?

    init(actions: Actions) {
        model = OnboardingModel(actions: actions)
    }

    var isVisible: Bool { window?.isVisible == true }

    func show() {
        // A first setup that was quit or crashed partway picks up where it stopped; a replay starts over.
        model.step = Profile.isSetUp ? .hello : OnboardingModel.savedStep
        model.heard = nil
        if window == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 660),
                                  styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.isMovableByWindowBackground = true
            window.isReleasedWhenClosed = false
            window.backgroundColor = NSColor(red: 0.055, green: 0.063, blue: 0.086, alpha: 1)
            window.delegate = self
            window.contentView = NSHostingView(rootView: OnboardingView(model: model).environment(\.colorScheme, .dark))
            window.center()
            self.window = window
        }
        if NSApp.activationPolicy() != .regular { NSApp.setActivationPolicy(.regular) }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    /// The user asked Joe something while the window is up: the "Try it" step's moment.
    func heard(_ text: String) {
        guard isVisible, model.step == .tryIt else { return }
        withAnimation(.spring(response: 0.5, dampingFraction: 0.7)) { model.heard = text }
    }

    func close() { window?.close() }
}

@MainActor
final class OnboardingModel: ObservableObject {
    // The ManageBac link comes before School, so the subjects are already filled in from it.
    enum Step: Int, CaseIterable { case hello, name, models, tour, connect, school, notes, morning, permissions, claude, tryIt, done }

    /// The step a first setup reached, so quitting halfway doesn't mean clicking through it all again.
    static var savedStep: Step {
        get { Step(rawValue: UserDefaults.standard.integer(forKey: "onboardingStep")) ?? .hello }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "onboardingStep") }
    }

    @Published var step: Step = .hello
    @Published var heard: String?
    let actions: Onboarding.Actions

    init(actions: Onboarding.Actions) { self.actions = actions }

    func next() {
        guard let following = Step(rawValue: step.rawValue + 1) else { return }
        if step == .tour { actions.narrate("", "") } // moving on: he stops mid-sentence
        withAnimation(.easeInOut(duration: 0.35)) { step = following }
        Self.savedStep = following
        arrived()
    }

    func back() {
        guard let previous = Step(rawValue: step.rawValue - 1) else { return }
        withAnimation(.easeInOut(duration: 0.35)) { step = previous }
        Self.savedStep = previous
    }

    /// What Joe says at the notch as each step comes up.
    private func arrived() {
        let name = Profile.name
        switch step {
        case .tryIt: actions.greet("Your turn", "Hold the right Option key and ask me something.")
        case .done: actions.greet("You're all set, \(name)", "You're all set. I'm up here whenever you need me.")
        default: break
        }
    }
}

// MARK: - Look

private enum Tint {
    static let accent = Color(red: 1, green: 0.55, blue: 0.14)
    static let glow = Color(red: 1, green: 0.45, blue: 0.1)
    static let card = Color.white.opacity(0.06)
    static let line = Color.white.opacity(0.1)
    static let soft = Color.white.opacity(0.62)
}

private struct OnboardingView: View {
    @ObservedObject var model: OnboardingModel

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.05, green: 0.06, blue: 0.08), Color(red: 0.09, green: 0.1, blue: 0.13)],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
            VStack(spacing: 18) {
                ZStack {
                    Group {
                    switch model.step {
                    case .hello: HelloStep(model: model)
                    case .name: NameStep(model: model)
                    case .tour: TourStep(model: model)
                    case .school: SchoolStep(model: model)
                    case .notes: NotesStep(model: model)
                    case .morning: MorningStep(model: model)
                    case .connect: ConnectStep(model: model)
                    case .models: ModelsStep(model: model)
                    case .permissions: PermissionsStep(model: model)
                    case .claude: ClaudeStep(model: model)
                    case .tryIt: TryStep(model: model)
                    case .done: DoneStep(model: model)
                    }
                    }
                    .transition(.asymmetric(insertion: .opacity.combined(with: .offset(x: 36)),
                                            removal: .opacity.combined(with: .offset(x: -36))))
                    .id(model.step)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
                progress
            }
            .padding(.horizontal, 64)
            .padding(.top, 44)
            .padding(.bottom, 28)
        }
        .foregroundStyle(.white)
        .frame(width: 960, height: 660)
    }

    private var progress: some View {
        HStack(spacing: 7) {
            ForEach(OnboardingModel.Step.allCases, id: \.self) { step in
                Capsule()
                    .fill(step == model.step ? Tint.accent : Color.white.opacity(step.rawValue < model.step.rawValue ? 0.45 : 0.15))
                    .frame(width: step == model.step ? 26 : 7, height: 7)
            }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: model.step)
    }
}

// MARK: - Pieces

/// Joe's star, glowing and turning slowly.
private struct Star: View {
    var size: CGFloat = 96

    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            ZStack {
                Circle()
                    .fill(RadialGradient(colors: [Tint.glow.opacity(0.55), .clear], center: .center, startRadius: 0, endRadius: size * 1.4))
                    .frame(width: size * 2.8, height: size * 2.8)
                    .scaleEffect(1 + 0.08 * sin(t * 1.6))
                Image(systemName: "sparkle")
                    .font(.system(size: size, weight: .semibold))
                    .foregroundStyle(LinearGradient(colors: [Color(red: 1, green: 0.75, blue: 0.35), Tint.accent], startPoint: .top, endPoint: .bottom))
                    .rotationEffect(.degrees(sin(t * 0.8) * 8))
                    .scaleEffect(1 + 0.04 * sin(t * 2.2))
            }
        }
    }
}

/// Text that types itself out.
private struct Typed: View {
    let text: String
    var font: Font = .system(size: 44, weight: .bold)
    @State private var shown = 0

    var body: some View {
        Text(text.prefix(shown))
            .font(font)
            .task(id: text) {
                shown = 0
                for index in 0...text.count {
                    shown = index
                    try? await Task.sleep(for: .milliseconds(38))
                }
            }
    }
}

private struct Primary: View {
    let title: String
    var enabled = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .padding(.horizontal, 26)
                .frame(height: 44)
                .background(enabled ? Tint.accent : Color.white.opacity(0.12), in: Capsule())
                .foregroundStyle(enabled ? Color.black : Color.white.opacity(0.4))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .keyboardShortcut(.defaultAction)
    }
}

private struct StepFrame<Content: View>: View {
    @ObservedObject var model: OnboardingModel
    let title: String
    var subtitle: String?
    var canContinue = true
    var continueTitle = "Continue"
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 26) {
            VStack(alignment: .leading, spacing: 10) {
                Text(title).font(.system(size: 34, weight: .bold))
                if let subtitle { Text(subtitle).font(.system(size: 15)).foregroundStyle(Tint.soft) }
            }
            content.frame(maxHeight: .infinity, alignment: .top)
            HStack {
                Button("Back") { model.back() }.buttonStyle(.plain).foregroundStyle(Tint.soft)
                Spacer()
                Primary(title: continueTitle, enabled: canContinue) { model.next() }
            }
        }
        .padding(.top, 24)
        .padding(.bottom, 18)
    }
}

// MARK: - Steps

private struct HelloStep: View {
    @ObservedObject var model: OnboardingModel
    @State private var appeared = false

    var body: some View {
        VStack(spacing: 22) {
            Spacer()
            Star(size: 92).frame(height: 230)
            Typed(text: "Hi, I’m Joe.")
            Text("I live at the top of your screen. Talk to me, and I’ll take care of the rest.")
                .font(.system(size: 17)).foregroundStyle(Tint.soft)
                .opacity(appeared ? 1 : 0)
                .animation(.easeOut(duration: 0.8).delay(0.9), value: appeared)
            Spacer()
            Primary(title: "Hi, Joe") { model.next() }
                .opacity(appeared ? 1 : 0)
                .animation(.easeOut(duration: 0.6).delay(1.4), value: appeared)
        }
        .onAppear {
            appeared = true
            model.actions.greet("Hi, I’m Joe", "Hi! I'm Joe. Let's get you set up.")
        }
    }
}

private struct NameStep: View {
    @ObservedObject var model: OnboardingModel
    @AppStorage("userName") private var name = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 26) {
            Spacer()
            Star(size: 44).frame(height: 110)
            Text("What should I call you?").font(.system(size: 34, weight: .bold))
            TextField("Your name", text: $name)
                .textFieldStyle(.plain)
                .font(.system(size: 30, weight: .medium))
                .multilineTextAlignment(.center)
                .padding(.vertical, 14)
                .frame(width: 420)
                .background(Tint.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(focused ? Tint.accent : Tint.line, lineWidth: 1.5))
                .focused($focused) // Return presses Continue (its keyboard shortcut): one step, not two
            Spacer()
            HStack {
                Button("Back") { model.back() }.buttonStyle(.plain).foregroundStyle(Tint.soft)
                Spacer()
                Primary(title: "Continue", enabled: !trimmed.isEmpty) { model.next() }
            }
        }
        .onAppear {
            focused = true
            // The Mac already knows their name: one less thing to type.
            if trimmed.isEmpty, let first = NSFullUserName().split(separator: " ").first { name = String(first) }
        }
    }

    private var trimmed: String { name.trimmingCharacters(in: .whitespaces) }
}

/// Four things Joe does, each a short looping animation; they advance by themselves.
private struct TourStep: View {
    @ObservedObject var model: OnboardingModel
    @State private var page = 0
    /// What Joe says over each page: the feature, in his words.
    private var commentary: [String] {
        let name = Profile.name.isEmpty ? "" : ", \(Profile.name)"
        return [
            "Nice to meet you\(name). First trick: hold right Command and just talk. Whatever you say lands wherever you're typing, punctuation and all. Essays, emails, the group chat. Your keyboard's about to get jealous.",
            "This one's my favourite. Hold right Option and ask me anything. What's due tomorrow, find that worksheet, reply to your teacher. I answer up here at the notch, and if it's a job, I just do it.",
            "Every morning I build your day for you: your classes, what's due on ManageBac, and the emails that actually need you. No more checking five apps before first period.",
            "And the big stuff, like a formative or a slide deck, I take into the background and work through while you get on with your evening. I'll tell you when it's done.",
        ]
    }
    private let pages = [
        ("Write with your voice", "Hold right ⌘ and talk. Your words appear wherever you’re typing, punctuated.", "command"),
        ("Ask me anything", "Hold right ⌥ and ask. I answer at the notch, and I can do it for you.", "option"),
        ("I run your day", "Every morning: your classes, what’s due, and the emails that need you.", "sun.max"),
        ("Big jobs, in the background", "Hand me a formative or a deck. I work through it while you keep going.", "checklist"),
    ]

    var body: some View {
        StepFrame(model: model, title: pages[page].0, subtitle: pages[page].1) {
            VStack(spacing: 22) {
                ZStack {
                    RoundedRectangle(cornerRadius: 22, style: .continuous).fill(Tint.card)
                        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(Tint.line))
                    Group {
                        switch page {
                        case 0: DictationDemo()
                        case 1: AskDemo()
                        case 2: DaybookDemo()
                        default: ChecklistDemo()
                        }
                    }
                    .id(page)
                    .transition(.opacity.combined(with: .scale(scale: 0.97)))
                }
                .frame(height: 300)
                HStack(spacing: 8) {
                    ForEach(0..<pages.count, id: \.self) { index in
                        Button { withAnimation { page = index } } label: {
                            Label(pages[index].0, systemImage: pages[index].2)
                                .font(.system(size: 12.5, weight: page == index ? .semibold : .regular))
                                .padding(.horizontal, 12).frame(height: 30)
                                .background(page == index ? Tint.accent.opacity(0.18) : Color.clear, in: Capsule())
                                .foregroundStyle(page == index ? Tint.accent : Tint.soft)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        // Joe talks over each page, and it moves on when he's done (or when they pick another).
        .task(id: page) {
            model.actions.narrate(pages[page].0, commentary[page])
            let started = Date()
            try? await Task.sleep(for: .seconds(2))
            // Until he's finished, but never stuck on a page: a voice still loading gets 25 seconds.
            while !Task.isCancelled, model.actions.isSpeaking(), Date().timeIntervalSince(started) < 25 {
                try? await Task.sleep(for: .milliseconds(300))
            }
            try? await Task.sleep(for: .seconds(Date().timeIntervalSince(started) < 4 ? 3 : 0.9))
            guard !Task.isCancelled, page < pages.count - 1 else { return }
            withAnimation(.easeInOut(duration: 0.4)) { page += 1 }
        }
    }
}

private struct KeyCap: View {
    let label: String
    let pressed: Bool

    var body: some View {
        Text(label)
            .font(.system(size: 20, weight: .semibold))
            .frame(width: 92, height: 64)
            .background(RoundedRectangle(cornerRadius: 12).fill(pressed ? Tint.accent : Color.white.opacity(0.1)))
            .foregroundStyle(pressed ? Color.black : .white)
            .offset(y: pressed ? 3 : 0)
            .shadow(color: pressed ? Tint.glow.opacity(0.6) : .clear, radius: 14)
    }
}

private struct DictationDemo: View {
    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 4.5)
            let sentence = "Dear Ms Marquardt, Tuesday works for me. Thank you!"
            let typed = t < 0.6 ? 0 : min(sentence.count, Int((t - 0.6) * 22))
            HStack(spacing: 40) {
                VStack(spacing: 16) {
                    KeyCap(label: "⌘", pressed: t > 0.3 && t < 3)
                    HStack(spacing: 4) {
                        ForEach(0..<9, id: \.self) { index in
                            Capsule().fill(Tint.accent)
                                .frame(width: 5, height: t < 3 ? 8 + 22 * abs(sin(t * 7 + Double(index))) : 6)
                        }
                    }
                    .frame(height: 34)
                }
                VStack(alignment: .leading, spacing: 10) {
                    Text("Mail").font(.system(size: 12, weight: .semibold)).foregroundStyle(Tint.soft)
                    Text(sentence.prefix(typed) + (typed < sentence.count ? "▍" : ""))
                        .font(.system(size: 19)).frame(width: 340, height: 96, alignment: .topLeading)
                }
                .padding(20)
                .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 14))
            }
        }
    }
}

private struct AskDemo: View {
    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 4.5)
            let open = t > 1.2 && t < 4.2
            VStack(spacing: 0) {
                // The top of a screen, with the notch dropping an answer.
                VStack(alignment: .leading, spacing: 6) {
                    if open {
                        Text("Econ quiz is Thursday").font(.system(size: 14, weight: .semibold))
                        Text("Chapter 4 elasticity. I’ve added a 30-minute review to tomorrow.")
                            .font(.system(size: 12.5)).foregroundStyle(Tint.soft)
                    }
                }
                .padding(.horizontal, 18).padding(.vertical, open ? 14 : 0)
                .frame(width: open ? 380 : 160, height: open ? 92 : 30, alignment: .topLeading)
                .background(Color.black, in: UnevenRoundedRectangle(bottomLeadingRadius: 18, bottomTrailingRadius: 18))
                .animation(.spring(response: 0.5, dampingFraction: 0.75), value: open)
                Spacer()
                HStack(spacing: 14) {
                    KeyCap(label: "⌥", pressed: t > 0.2 && t < 1.2)
                    Text(t < 1.2 ? "“When’s my Econ quiz?”" : " ").font(.system(size: 16)).foregroundStyle(Tint.soft)
                }
                .padding(.bottom, 28)
            }
        }
    }
}

private struct DaybookDemo: View {
    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 4.5)
            let tasks = ["Math AI homework, due 14:25", "Reply to Ms Marquardt", "ESS formative draft", "Volleyball, leave 15:00"]
            VStack(alignment: .leading, spacing: 12) {
                Text("Good morning · Monday, 3 classes").font(.system(size: 15, weight: .semibold))
                ForEach(Array(tasks.enumerated()), id: \.offset) { index, task in
                    let done = t > 1 + Double(index) * 0.8
                    HStack(spacing: 10) {
                        Image(systemName: done ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(done ? Tint.accent : Tint.soft)
                            .scaleEffect(done ? 1.15 : 1)
                            .animation(.spring(response: 0.3, dampingFraction: 0.5), value: done)
                        Text(task).font(.system(size: 15)).strikethrough(done).foregroundStyle(done ? Tint.soft : .white)
                    }
                }
            }
            .padding(26)
            .frame(width: 420, alignment: .leading)
            .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 16))
        }
    }
}

private struct ChecklistDemo: View {
    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 4.5)
            let steps = ["Read the ESS task", "Answer questions 1–4", "Draw the food web", "Save it as a new doc"]
            let current = min(steps.count, Int(t / 1.0))
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    ProgressView().controlSize(.small).tint(Tint.accent)
                    Text("\(min(current, steps.count))/\(steps.count) · \(steps[min(current, steps.count - 1)])")
                        .font(.system(size: 13, weight: .semibold))
                }
                .padding(.horizontal, 14).frame(height: 34)
                .background(Color.black, in: Capsule())
                ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                    HStack(spacing: 10) {
                        Image(systemName: index < current ? "checkmark.circle.fill" : index == current ? "circle.dotted" : "circle")
                            .foregroundStyle(index < current ? .green : index == current ? Tint.accent : Tint.soft)
                        Text(step).font(.system(size: 15)).foregroundStyle(index <= current ? .white : Tint.soft)
                    }
                }
            }
        }
    }
}

/// School, programme and subjects. Subjects are picked by IB group (left), from that group's
/// subjects (middle), into "Your subjects" (right), each with an SL / HL switch.
private struct SchoolStep: View {
    @ObservedObject var model: OnboardingModel
    @AppStorage("profileSchool") private var school = ""
    @AppStorage("profileProgramme") private var programme = ""
    @AppStorage("profileSubjects") private var subjects = ""
    @AppStorage("profileProject") private var project = ""
    @State private var group = 0

    private static let programmes = ["IB Diploma, year 1 (DP1)", "IB Diploma, year 2 (DP2)", "IB MYP, years 1–3", "IB MYP, year 4 (MYP4)",
                                     "IB MYP, year 5 (MYP5)", "IB Career-related", "Other"]
    private static let groups: [(name: String, symbol: String, subjects: [String])] = [
        ("Language & literature", "book", ["English A Lang & Lit", "English A Literature", "Chinese A Lang & Lit", "Chinese A Literature", "Literature & Performance"]),
        ("Language acquisition", "character.bubble", ["Chinese B", "English B", "Spanish B", "French B", "Mandarin ab initio", "Spanish ab initio", "French ab initio"]),
        ("Individuals & societies", "person.3", ["Economics", "Business Management", "Psychology", "History", "Geography", "Global Politics", "Digital Society", "Philosophy"]),
        ("Sciences", "atom", ["Biology", "Chemistry", "Physics", "ESS", "Computer Science", "Sports, Exercise & Health", "Design Technology"]),
        ("Mathematics", "function", ["Math AA", "Math AI"]),
        ("The arts", "paintpalette", ["Visual Arts", "Music", "Theatre", "Film", "Dance"]),
    ]

    var body: some View {
        StepFrame(model: model, title: "Your school",
                  subtitle: subjects.isEmpty || CalendarFeed.links.isEmpty
                      ? "So I know your classes, your deadlines and how each subject is assessed."
                      : "I filled in your subjects from ManageBac. Fix anything I got wrong, and set HL or SL.") {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 12) {
                    field("School", "Your school’s name", $school)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Programme").font(.system(size: 12, weight: .medium)).foregroundStyle(Tint.soft)
                        Menu {
                            ForEach(Self.programmes, id: \.self) { option in Button(option) { programme = option } }
                        } label: {
                            HStack {
                                Text(programme.isEmpty ? "Choose" : programme).font(.system(size: 14)).lineLimit(1)
                                Spacer()
                                Image(systemName: "chevron.up.chevron.down").font(.system(size: 10, weight: .bold)).foregroundStyle(Tint.soft)
                            }
                            .padding(.horizontal, 12).frame(height: 38)
                            .background(Tint.card, in: RoundedRectangle(cornerRadius: 10))
                            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Tint.line))
                        }
                        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
                    }
                    .frame(width: 240)
                    field("A project of yours (optional)", "A business, club…", $project).frame(width: 220)
                }
                HStack(alignment: .top, spacing: 14) {
                    // The six groups.
                    VStack(spacing: 4) {
                        ForEach(Self.groups.indices, id: \.self) { index in
                            let count = Self.groups[index].subjects.filter { level(of: $0) != nil }.count
                            Button { withAnimation(.easeOut(duration: 0.2)) { group = index } } label: {
                                HStack(spacing: 9) {
                                    Image(systemName: Self.groups[index].symbol).frame(width: 18)
                                    Text(Self.groups[index].name).font(.system(size: 13, weight: group == index ? .semibold : .regular)).lineLimit(1)
                                    Spacer(minLength: 4)
                                    if count > 0 { Circle().fill(Tint.accent).frame(width: 7, height: 7) }
                                }
                                .padding(.horizontal, 10).frame(height: 34)
                                .background(group == index ? Color.white.opacity(0.1) : .clear, in: RoundedRectangle(cornerRadius: 8))
                                .foregroundStyle(group == index ? .white : Tint.soft)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .frame(width: 214)
                    // That group's subjects.
                    VStack(alignment: .leading, spacing: 8) {
                        LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                            ForEach(Self.groups[group].subjects, id: \.self) { subject in
                                let picked = level(of: subject) != nil
                                Button { withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) { toggle(subject) } } label: {
                                    HStack(spacing: 6) {
                                        Image(systemName: picked ? "checkmark" : "plus").font(.system(size: 11, weight: .bold))
                                        // Two lines for the long names ("Literature & Performance") rather than cut short.
                                        Text(subject).font(.system(size: 12.5, weight: picked ? .semibold : .regular)).lineLimit(2)
                                            .minimumScaleFactor(0.9).fixedSize(horizontal: false, vertical: true)
                                        Spacer(minLength: 0)
                                    }
                                    .padding(.horizontal, 12).frame(minHeight: 36)
                                    .background(picked ? Tint.accent.opacity(0.2) : Tint.card, in: RoundedRectangle(cornerRadius: 10))
                                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(picked ? Tint.accent : Tint.line))
                                    .foregroundStyle(picked ? Tint.accent : .white)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .id(group)
                        .transition(.opacity)
                    }
                    .frame(maxWidth: .infinity)
                    // Their picks.
                    VStack(alignment: .leading, spacing: 6) {
                        let list = chosen
                        HStack {
                            Text("Your subjects").font(.system(size: 13, weight: .semibold))
                            Spacer()
                            Text("\(list.count) of 6 · \(list.filter { $0.1 == "HL" }.count) HL")
                                .font(.system(size: 11.5).monospacedDigit()).foregroundStyle(list.count == 6 ? .green : Tint.soft)
                        }
                        if list.isEmpty {
                            Text("Pick from the groups on the left.").font(.system(size: 12.5)).foregroundStyle(Tint.soft).padding(.top, 6)
                        }
                        ForEach(list, id: \.0) { subject, level in
                            HStack(spacing: 6) {
                                Text(subject).font(.system(size: 12.5)).lineLimit(1)
                                Spacer(minLength: 4)
                                HStack(spacing: 0) {
                                    ForEach(["SL", "HL"], id: \.self) { option in
                                        Button { setLevel(subject, option) } label: {
                                            Text(option).font(.system(size: 10.5, weight: .bold))
                                                .frame(width: 28, height: 20)
                                                .background(level == option ? Tint.accent : .clear, in: RoundedRectangle(cornerRadius: 5))
                                                .foregroundStyle(level == option ? Color.black : Tint.soft)
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                                .padding(2)
                                .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 7))
                                Button { withAnimation { toggle(subject) } } label: { Image(systemName: "xmark").font(.system(size: 9, weight: .bold)) }
                                    .buttonStyle(.plain).foregroundStyle(Tint.soft)
                            }
                            .frame(height: 30)
                            .transition(.opacity.combined(with: .move(edge: .trailing)))
                        }
                    }
                    .padding(14)
                    .frame(width: 270, alignment: .topLeading)
                    .background(Tint.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Tint.line))
                }
            }
        }
    }

    private func field(_ label: String, _ placeholder: String, _ value: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.system(size: 12, weight: .medium)).foregroundStyle(Tint.soft)
            TextField(placeholder, text: value)
                .textFieldStyle(.plain).font(.system(size: 14))
                .padding(.horizontal, 12).frame(height: 38)
                .background(Tint.card, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Tint.line))
        }
    }

    /// The subjects as saved ("Math AI HL, ESS SL…"), each with its level.
    private var chosen: [(String, String)] {
        subjects.split(separator: ",").compactMap { part in
            let words = part.trimmingCharacters(in: .whitespaces)
            guard !words.isEmpty else { return nil }
            for level in ["HL", "SL"] where words.hasSuffix(" " + level) {
                return (String(words.dropLast(3)), level)
            }
            return (words, "SL")
        }
    }

    private func save(_ list: [(String, String)]) {
        subjects = list.map { "\($0.0) \($0.1)" }.joined(separator: ", ")
    }

    private func level(of subject: String) -> String? {
        chosen.first { $0.0.caseInsensitiveCompare(subject) == .orderedSame }?.1
    }

    private func toggle(_ subject: String) {
        var list = chosen
        if let index = list.firstIndex(where: { $0.0.caseInsensitiveCompare(subject) == .orderedSame }) {
            list.remove(at: index)
        } else {
            list.append((subject, "SL"))
        }
        save(list)
    }

    private func setLevel(_ subject: String, _ level: String) {
        save(chosen.map { $0.0 == subject ? ($0.0, level) : $0 })
    }
}

/// "Get Joe ready": the downloads, each started here with its size and progress, and Retry if the
/// internet drops. Continue works while they download.
private struct ModelsStep: View {
    @ObservedObject var model: OnboardingModel
    @State private var tick = 0
    /// Each download's last progress and when it last moved, to tell a stalled one from a slow one.
    @State private var lastMoved: [ModelGuard.Model: (fraction: Double, at: Date)] = [:]
    @State private var mirrorNote: String?
    @State private var chinese = Transcriber.languages == .chinese
    private let timer = Timer.publish(every: 0.7, on: .main, in: .common).autoconnect()
    private static let stallSeconds: TimeInterval = 45

    private var models: [ModelGuard.Model] {
        Transcriber.languages == .chinese ? [.speech, .chinese, .voice, .mandarin] : [.speech, .voice]
    }

    var body: some View {
        StepFrame(model: model, title: "Get Joe ready", subtitle: "Joe runs on this Mac: speech and his voice download once (about \(String(format: "%.1f", models.reduce(0) { $0 + $1.megabytes } / 1024)) GB). You can continue while they download.") {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(models) { item in row(item) }
                // Many IB students speak Chinese: both languages, in one sentence too. Adds two downloads.
                if Transcriber.languages != .european { // chose European languages in Settings: theirs
                    Toggle("I speak Chinese too (Mandarin or Cantonese)", isOn: $chinese)
                        .font(.system(size: 13.5)).tint(Tint.accent)
                        .onChange(of: chinese) { Transcriber.languages = chinese ? .chinese : .english }
                }
                HStack {
                    // Only what isn't already on its way: a second start of the same download doesn't help.
                    Primary(title: "Download all", enabled: models.contains { canStart($0) }) {
                        for item in models where canStart(item) { model.actions.download(item) }
                    }
                    .frame(width: 180)
                    Spacer()
                    Text(mirrorNote ?? "In mainland China without a VPN: Settings → Advanced → Download models from → China mirror.")
                        .font(.system(size: 11.5)).foregroundStyle(Tint.soft).frame(maxWidth: 360, alignment: .trailing)
                }
                .padding(.top, 6)
                if let space = diskWarning {
                    Label(space, systemImage: "externaldrive.badge.exclamationmark").font(.system(size: 12.5)).foregroundStyle(.orange)
                }
            }
            .id(tick)
        }
        .onReceive(timer) { _ in
            tick += 1
            for item in models {
                guard case .downloading(let fraction) = ModelGuard.status(item) else { lastMoved[item] = nil; continue }
                if lastMoved[item]?.fraction != fraction { lastMoved[item] = (fraction, Date()) }
            }
        }
        .task { await chooseMirror() }
        .onAppear {
            // A Mac set up in Chinese, and no choice made yet: start with Chinese on.
            if UserDefaults.standard.string(forKey: "speechLanguages") == nil, Transcriber.languages == .english,
               Locale.preferredLanguages.contains(where: { $0.hasPrefix("zh") }) {
                chinese = true
            }
        }
    }

    /// No progress for a while. Not near the end: a finished download sits at 99% while macOS
    /// prepares it, which can take a minute.
    private func isStalled(_ item: ModelGuard.Model) -> Bool {
        guard let moved = lastMoved[item], moved.fraction < 0.97 else { return false }
        return Date().timeIntervalSince(moved.at) > Self.stallSeconds
    }

    private func canStart(_ item: ModelGuard.Model) -> Bool {
        switch ModelGuard.status(item) {
        case .notDownloaded, .failed: true
        case .downloading, .ready: false
        }
    }

    /// Not enough room for what's left to download, said before it fails halfway.
    private var diskWarning: String? {
        let needed = models.filter { ModelGuard.status($0) != .ready }.reduce(0) { $0 + $1.megabytes } * 1_048_576
        guard needed > 0,
              let free = try? FileManager.default.homeDirectoryForCurrentUser
                  .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage,
              Double(free) < needed * 1.2 else { return nil }
        return "Only \(free / 1_073_741_824) GB free on this Mac: these need about \(String(format: "%.1f", needed / 1_073_741_824)) GB. Free some space first."
    }

    /// In mainland China without a VPN, Hugging Face doesn't load and every download fails. If they
    /// haven't chosen yet, and Hugging Face can't be reached but the mirror can, use the mirror.
    private func chooseMirror() async {
        guard UserDefaults.standard.object(forKey: "modelMirrorChina") == nil else { return }
        func reachable(_ address: String) async -> Bool {
            var request = URLRequest(url: URL(string: address)!, timeoutInterval: 6)
            request.httpMethod = "HEAD"
            return (try? await URLSession.shared.data(for: request)) != nil
        }
        let huggingFace = await reachable("https://huggingface.co")
        let mirror = await reachable("https://hf-mirror.com")
        guard !huggingFace, mirror else { return }
        ModelDownloads.useChinaMirror = true
        mirrorNote = "Hugging Face can't be reached from here, so I'm downloading from the China mirror (Settings → Advanced)."
    }

    private func row(_ item: ModelGuard.Model) -> some View {
        let status = ModelGuard.status(item)
        return HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(item.title).font(.system(size: 14.5, weight: .semibold))
                switch status {
                case .notDownloaded: Text("\(Int(item.megabytes)) MB").font(.system(size: 12)).foregroundStyle(Tint.soft)
                case .downloading(let fraction):
                    ProgressView(value: fraction).tint(isStalled(item) ? .orange : Tint.accent).frame(maxWidth: 380)
                    // A hung download can't be restarted from here; after a relaunch it resumes (FluidAudio's
                    // .partial files, kept by ModelGuard) and the welcome reopens on this page.
                    Text(isStalled(item) ? "Stuck at \(Int(fraction * 100))%. Check your internet. If it still doesn't move, quit and reopen Joe: the download carries on from where it stopped, and you'll be back on this page."
                                         : "\(Int(fraction * 100))% of \(Int(item.megabytes)) MB")
                        .font(.system(size: 11.5)).foregroundStyle(isStalled(item) ? .orange : Tint.soft)
                case .ready: Label("Ready", systemImage: "checkmark.circle.fill").font(.system(size: 12.5)).foregroundStyle(.green)
                case .failed(let message): Text(message).font(.system(size: 12)).foregroundStyle(.orange).lineLimit(2)
                }
            }
            Spacer()
            switch status {
            case .notDownloaded: Primary(title: "Download", enabled: true) { model.actions.download(item) }.frame(width: 130)
            case .failed: Primary(title: "Retry", enabled: true) { model.actions.download(item) }.frame(width: 130)
            default: EmptyView()
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Tint.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

/// The student's school, connected once: the ManageBac link (or Google's) feeds deadlines, events,
/// the Daybook and the morning briefing, and fills in their subjects for the next step. The Mac's
/// Calendar is only offered without a link, so nothing is asked for twice. Spotify and messages
/// aren't set up here: they connect from the dashboard when the student wants them.
private struct ConnectStep: View {
    @ObservedObject var model: OnboardingModel
    @State private var link = ""
    @State private var links = CalendarFeed.links
    @State private var linkStatus: String?
    @State private var found: [String] = []
    @State private var reading = false
    @State private var macCalendar = EKEventStore.authorizationStatus(for: .event) == .fullAccess
    @State private var dayToday = ""
    @State private var timetableStatus: String?
    @State private var importing = false

    var body: some View {
        StepFrame(model: model, title: "Your school, connected",
                  subtitle: "Paste your ManageBac link once: I'll keep your deadlines and events up to date and fill in your subjects. Skip it and add it later in Settings.") {
            VStack(alignment: .leading, spacing: 10) {
                card(icon: "flag.fill", tint: .red, title: "ManageBac",
                     detail: "ManageBac → Calendar → Subscribe → copy the link. (No ManageBac? A Google Calendar iCal link works too: settings → Secret address in iCal format.)") {
                    HStack(spacing: 10) {
                        TextField("webcal://…managebac.com/… or a Google iCal link", text: $link)
                            .textFieldStyle(.plain).padding(.horizontal, 12).frame(height: 36)
                            .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 9))
                            .onSubmit { if link.contains("://") { add() } }
                        Primary(title: reading ? "Reading…" : "Add", enabled: link.contains("://") && !reading) { add() }.frame(width: 110)
                    }
                    if let linkStatus { Text(linkStatus).font(.system(size: 12.5)).foregroundStyle(Tint.soft) }
                    if !found.isEmpty {
                        VStack(alignment: .leading, spacing: 5) {
                            ForEach(found, id: \.self) { line in
                                Label(line, systemImage: "checkmark.circle.fill").font(.system(size: 13)).foregroundStyle(.green)
                            }
                        }
                        .transition(.opacity)
                    } else if !links.isEmpty {
                        Text("\(links.count) calendar link\(links.count == 1 ? "" : "s") added").font(.system(size: 12.5)).foregroundStyle(.green)
                    }
                }
                // Lessons aren't in the ManageBac link: a picture of the timetable gives Joe today's classes,
                // Now and Next, and the Daybook's lessons.
                card(icon: "tablecells", tint: .purple, title: "Your timetable",
                     detail: "A photo, screenshot or PDF of your class timetable. I'll read it once; it takes a minute or two.") {
                    HStack(spacing: 10) {
                        Primary(title: importing ? "Reading…" : "Choose a file", enabled: !importing) { chooseTimetable() }.frame(width: 160)
                        TextField("Rotating timetable? Today's day, e.g. Day 3", text: $dayToday)
                            .textFieldStyle(.plain).padding(.horizontal, 12).frame(height: 36)
                            .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 9))
                        if importing { ProgressView().controlSize(.small) }
                    }
                    if let timetableStatus { Text(timetableStatus).font(.system(size: 12.5)).foregroundStyle(Tint.soft) }
                }
                if links.isEmpty {
                    card(icon: "calendar", tint: .blue, title: "Or your Mac's Calendar", detail: "If your school calendar is already in the Calendar app, I can read it from there.") {
                        if macCalendar {
                            Label("Connected", systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.system(size: 13))
                        } else {
                            Primary(title: "Use my Mac's Calendar", enabled: true) {
                                CalendarFeed.requestMacCalendar { macCalendar = EKEventStore.authorizationStatus(for: .event) == .fullAccess }
                            }.frame(width: 220)
                        }
                    }
                }
            }
        }
        .onAppear { if !links.isEmpty { found = summary() } }
    }

    private func card<Content: View>(icon: String, tint: Color, title: String, detail: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon).font(.system(size: 16, weight: .semibold)).foregroundStyle(tint)
                .frame(width: 34, height: 34).background(tint.opacity(0.15), in: RoundedRectangle(cornerRadius: 9))
            VStack(alignment: .leading, spacing: 8) {
                Text(title).font(.system(size: 15, weight: .semibold))
                Text(detail).font(.system(size: 12.5)).foregroundStyle(Tint.soft).fixedSize(horizontal: false, vertical: true)
                content()
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Tint.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func add() {
        let new = link.trimmingCharacters(in: .whitespacesAndNewlines)
        CalendarFeed.links = Array(Set(CalendarFeed.links + [new]))
        links = CalendarFeed.links
        link = ""
        linkStatus = "Reading it…"
        reading = true
        Task {
            let result = await CalendarFeed.refreshLinks()
            reading = false
            guard result.hasSuffix("items") else { linkStatus = "Couldn't read it: \(result)"; return }
            // The school's ManageBac address names it ("swis.managebac.cn"): the School step's first field.
            if Profile.school.isEmpty, let host = URL(string: new.replacingOccurrences(of: "webcal://", with: "https://"))?.host,
               host.contains("managebac"), let name = host.split(separator: ".").first, name.lowercased() != "managebac" {
                Profile.school = name.count <= 5 ? name.uppercased() : name.capitalized
            }
            // Their subjects, so the next step is already filled in (only if they haven't picked any).
            let subjects = CalendarFeed.subjectGuesses()
            if Profile.subjects.isEmpty, !subjects.isEmpty { Profile.subjects = subjects.joined(separator: ", ") }
            linkStatus = nil
            withAnimation { found = summary() }
        }
    }

    private func chooseTimetable() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image, .pdf]
        panel.message = "Choose a photo, screenshot or PDF of your timetable"
        guard panel.runModal() == .OK, let file = panel.url else { return }
        importing = true
        timetableStatus = "Reading your timetable…"
        let day = dayToday.trimmingCharacters(in: .whitespaces)
        Task {
            timetableStatus = await Daybook.importTimetable(from: file, dayToday: day.isEmpty ? nil : day)
            importing = false
        }
    }

    /// What the link gave Joe, in a few lines, so the student sees it worked without checking.
    private func summary() -> [String] {
        let items = CalendarFeed.linkItems()
        guard !items.isEmpty else { return [] }
        var lines = ["\(items.count) items: deadlines and events, kept up to date every 30 minutes"]
        if let next = CalendarFeed.upcomingDeadlines(1).first {
            lines.append("Next due: \(next.title), \(next.start.formatted(.dateTime.weekday(.wide).day().month()))")
        }
        // Only when it filled them in: subjects they'd already chosen stay theirs, and listing other
        // guesses here would disagree with the next page.
        let subjects = CalendarFeed.subjectGuesses()
        if !subjects.isEmpty, Profile.subjects == subjects.joined(separator: ", ") {
            lines.append("Subjects: \(subjects.joined(separator: ", ")). Check them on the next page")
        }
        return lines
    }
}

private struct NotesStep: View {
    @ObservedObject var model: OnboardingModel
    @State private var refresh = 0

    var body: some View {
        StepFrame(model: model, title: "Where should I keep notes?",
                  subtitle: "Lecture notes, your daily plan and my memory of your days go in one folder you own. Not sure? Just continue and I'll make a Joe folder.") {
            VStack(spacing: 16) {
                HStack(spacing: 16) {
                    option("book.closed", "My Obsidian vault", "Use the vault you already have.") { model.actions.chooseVault(); refresh += 1 }
                    option("folder.badge.plus", "Make a Joe folder", "In Documents. Open it in Obsidian any time.") { makeFolder(); refresh += 1 }
                }
                if let vault = Assistant.vaultURL {
                    Label(vault.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"), systemImage: "checkmark.circle.fill")
                        .font(.system(size: 13.5, weight: .medium)).foregroundStyle(.green)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .id(refresh)
        }
        .onDisappear {
            // Moving on without choosing: the Joe folder, so notes and the Daybook work anyway.
            if Assistant.vaultURL == nil, model.step.rawValue > OnboardingModel.Step.notes.rawValue { makeFolder() }
        }
    }

    private func option(_ symbol: String, _ title: String, _ detail: String, _ action: @escaping () -> Void) -> some View {
        Button(action: { withAnimation { action() } }) {
            VStack(alignment: .leading, spacing: 10) {
                Image(systemName: symbol).font(.system(size: 28)).foregroundStyle(Tint.accent)
                Text(title).font(.system(size: 18, weight: .semibold))
                Text(detail).font(.system(size: 13)).foregroundStyle(Tint.soft)
            }
            .padding(24)
            .frame(maxWidth: .infinity, minHeight: 170, alignment: .topLeading)
            .background(Tint.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Tint.line))
        }
        .buttonStyle(.plain)
    }

    private func makeFolder() {
        let folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Joe", isDirectory: true)
        for sub in ["School/Lecture Notes", "Meetings", "Notes", "Daybook/History", "People"] {
            try? FileManager.default.createDirectory(at: folder.appendingPathComponent(sub), withIntermediateDirectories: true)
        }
        Assistant.vaultURL = folder
        Daybook.addDefaultRoutines()
    }
}

/// Their wake-up time, so the wake-up alarm (with its challenge) and the morning briefing work from
/// the first morning instead of waiting to be discovered. Skippable; an existing wake-up alarm is kept.
private struct MorningStep: View {
    @ObservedObject var model: OnboardingModel
    /// Their wake-up alarm if they have one: shown in the picker to change, never a second one.
    private let existing = AlarmStore.load().first { $0.repeats != nil && $0.title.lowercased().contains("wake") }
    @State private var time = Calendar.current.date(bySettingHour: 7, minute: 0, second: 0, of: Date()) ?? Date()
    @State private var schoolDays = true
    @State private var wanted = true

    var body: some View {
        StepFrame(model: model, title: "Your mornings",
                  subtitle: "I'll wake you up, check you're really awake with a quick question, then tell you what your day looks like.",
                  continueTitle: existing == nil && wanted ? "Set my alarm" : "Continue") {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 18) {
                    Image(systemName: "alarm.fill").font(.system(size: 22)).foregroundStyle(Tint.accent)
                        .frame(width: 48, height: 48).background(Tint.accent.opacity(0.14), in: Circle())
                    VStack(alignment: .leading, spacing: 4) {
                        Text(existing == nil ? "Wake me up at" : "Your wake-up alarm").font(.system(size: 15, weight: .semibold))
                        DatePicker("", selection: $time, displayedComponents: .hourAndMinute)
                            .labelsHidden().datePickerStyle(.field).frame(width: 110)
                    }
                    Spacer()
                    Picker("", selection: $schoolDays) {
                        Text("School days").tag(true)
                        Text("Every day").tag(false)
                    }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 220)
                }
                .padding(18)
                .background(Tint.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .opacity(wanted ? 1 : 0.4)
                .disabled(!wanted)
                if existing == nil {
                    Toggle("I don't want a wake-up alarm", isOn: Binding(get: { !wanted }, set: { wanted = !$0 }))
                        .font(.system(size: 13.5)).tint(Tint.accent)
                } else {
                    Label("You already have one. Change the time or days here, or leave it as it is.", systemImage: "checkmark.circle.fill")
                        .font(.system(size: 13.5)).foregroundStyle(.green)
                }
            }
        }
        .onAppear {
            guard let existing else { return }
            time = existing.fireAt
            schoolDays = existing.repeatDays != Set(1...7)
        }
        .onDisappear(perform: save)
    }

    /// On the way forward only: going back doesn't set anything.
    private func save() {
        guard wanted, model.step.rawValue > OnboardingModel.Step.morning.rawValue else { return }
        let calendar = Calendar.current
        let parts = calendar.dateComponents([.hour, .minute], from: time)
        let today = calendar.date(bySettingHour: parts.hour ?? 7, minute: parts.minute ?? 0, second: 0, of: Date()) ?? time
        let repeats = schoolDays ? "weekdays" : "daily"
        var alarm = existing ?? Alarm(fireAt: today, title: "Wake up", kind: .alarm, repeats: repeats)
        if let existing {
            guard !AlarmStore.isLocked(existing) else { return } // in its last hour: only the challenge stops it
            let before = calendar.dateComponents([.hour, .minute], from: existing.fireAt)
            let sameDays = (existing.repeatDays != Set(1...7)) == schoolDays
            guard before.hour != parts.hour || before.minute != parts.minute || !sameDays else { return } // unchanged
            // Days they set by voice ("mon,wed,fri") stay unless they picked the other option.
            if !sameDays { alarm.repeats = repeats }
            alarm.fireAt = today
        }
        // The first ring has to fall on one of its days: set up on a Friday evening, a weekday alarm
        // waits for Monday instead of ringing on Saturday once.
        alarm.fireAt = alarm.next(after: Date()) ?? today
        if existing != nil {
            AlarmStore.save(AlarmStore.load().map { $0.id == alarm.id ? alarm : $0 })
        } else {
            AlarmStore.add(alarm)
        }
    }
}

/// Each permission ticks itself off the moment it's granted (checked every half second).
private struct PermissionsStep: View {
    @ObservedObject var model: OnboardingModel

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { _ in
            let mic = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
            let access = AXIsProcessTrusted()
            StepFrame(model: model, title: "Two quick permissions", subtitle: "So I can hear you and type for you. Nothing is recorded unless you hold a key.",
                      canContinue: mic && access) {
                VStack(spacing: 14) {
                    row("mic.fill", "Microphone", "To hear you while you hold a key", mic) {
                        AVCaptureDevice.requestAccess(for: .audio) { _ in }
                    }
                    row("hand.raised.fill", "Accessibility", "To type what you say, and press keys for you", access) {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                    }
                    row("rectangle.dashed", "Screen Recording (optional)", "So I can see what you mean by “this”", CGPreflightScreenCaptureAccess()) {
                        CGRequestScreenCaptureAccess()
                    }
                }
            }
        }
    }

    private func row(_ symbol: String, _ title: String, _ detail: String, _ granted: Bool, _ ask: @escaping () -> Void) -> some View {
        HStack(spacing: 16) {
            Image(systemName: symbol).font(.system(size: 20)).foregroundStyle(Tint.accent)
                .frame(width: 44, height: 44).background(Tint.accent.opacity(0.14), in: Circle())
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 16, weight: .semibold))
                Text(detail).font(.system(size: 13)).foregroundStyle(Tint.soft)
            }
            Spacer()
            if granted {
                Image(systemName: "checkmark.circle.fill").font(.system(size: 26)).foregroundStyle(.green)
                    .transition(.scale.combined(with: .opacity))
            } else {
                Button("Allow", action: ask)
                    .buttonStyle(.plain)
                    .font(.system(size: 13.5, weight: .semibold))
                    .padding(.horizontal, 18).frame(height: 34)
                    .background(Color.white.opacity(0.12), in: Capsule())
            }
        }
        .padding(16)
        .background(Tint.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .animation(.spring(response: 0.35, dampingFraction: 0.6), value: granted)
    }
}

private struct ClaudeStep: View {
    @ObservedObject var model: OnboardingModel
    @StateObject private var claude = ClaudeSetup()
    @AppStorage("useAPIKey") private var useAPIKey = false
    @State private var key = ""
    @State private var code = ""
    @State private var saved = AIAccount.maskedKey
    @AppStorage("aiProvider") private var aiProvider = "claude"
    @State private var codexStatus = ""
    @State private var codexBusy = false

    var body: some View {
        StepFrame(model: model, title: "My brain: Claude", subtitle: "I think with Claude. One click and I'll set it up, on your own Claude plan.",
                  canContinue: aiProvider == "chatgpt" ? codexStatus.hasPrefix("Signed in with ChatGPT") : claude.isReady || (useAPIKey && saved != nil)) {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 14) {
                    Group {
                        switch claude.state {
                        case .ready: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        case .installing, .signingIn, .checking: ProgressView().controlSize(.small).frame(width: 26)
                        case .failed: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        default: Image(systemName: "sparkle").foregroundStyle(Tint.accent)
                        }
                    }
                    .font(.system(size: 26))
                    VStack(alignment: .leading, spacing: 4) {
                        Text(title).font(.system(size: 16, weight: .semibold))
                        Text(subtitle).font(.system(size: 13)).foregroundStyle(Tint.soft).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    if [.notInstalled, .signedOut].contains(claude.state) || { if case .failed = claude.state { return true }; return false }() {
                        Primary(title: claude.state == .notInstalled ? "Install and connect" : "Connect Claude", enabled: true) { claude.connect() }
                            .frame(width: 190)
                    }
                }
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Tint.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                // Gmail, Google Calendar and Drive reach Joe through the student's claude.ai connectors,
                // so they're one click away here instead of something to discover later.
                if claude.isReady, !useAPIKey {
                    HStack(spacing: 14) {
                        Image(systemName: "envelope.fill").font(.system(size: 18)).foregroundStyle(Tint.accent).frame(width: 32)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Your email and Google Calendar").font(.system(size: 14.5, weight: .semibold))
                            Text("Connect Gmail, Google Calendar and Drive on claude.ai, and I can read your school email and draft replies.")
                                .font(.system(size: 12.5)).foregroundStyle(Tint.soft).fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer()
                        if ClaudeConnectors.has("gmail") {
                            Label("Gmail connected", systemImage: "checkmark.circle.fill").font(.system(size: 13)).foregroundStyle(.green)
                        } else {
                            Button("Open claude.ai") { NSWorkspace.shared.open(URL(string: "https://claude.ai/settings/connectors")!) }
                                .buttonStyle(.plain)
                                .font(.system(size: 13.5, weight: .semibold))
                                .padding(.horizontal, 18).frame(height: 34)
                                .background(Color.white.opacity(0.12), in: Capsule())
                        }
                    }
                    .padding(.horizontal, 18).padding(.vertical, 14)
                    .background(Tint.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
                if claude.needsCode {
                    HStack(spacing: 10) {
                        TextField("Paste the code from the Claude page", text: $code)
                            .textFieldStyle(.plain).padding(.horizontal, 14).frame(height: 40)
                            .background(Tint.card, in: RoundedRectangle(cornerRadius: 10))
                        Primary(title: "Send", enabled: code.count >= 6) { claude.send(code: code); code = "" }
                    }
                }
                Toggle("Use an Anthropic API key instead of a Claude plan", isOn: $useAPIKey).font(.system(size: 14)).tint(Tint.accent)
                if useAPIKey {
                    HStack(spacing: 10) {
                        SecureField("sk-ant-…", text: $key)
                            .textFieldStyle(.plain).padding(.horizontal, 14).frame(height: 40)
                            .background(Tint.card, in: RoundedRectangle(cornerRadius: 10))
                        Primary(title: "Save", enabled: key.count >= 20) { AIAccount.save(key); key = ""; saved = AIAccount.maskedKey }
                    }
                    if let saved { Text("Saved: \(saved)").font(.system(size: 12.5)).foregroundStyle(.green) }
                }
                // Students who pay for ChatGPT instead: Joe runs on OpenAI's Codex, signed in to that plan.
                Toggle("I have ChatGPT, not Claude", isOn: Binding(get: { aiProvider == "chatgpt" },
                                                                   set: { aiProvider = $0 ? "chatgpt" : "claude" }))
                    .font(.system(size: 14)).tint(Tint.accent)
                if aiProvider == "chatgpt" {
                    HStack(spacing: 10) {
                        Text(codexBusy ? "Finish signing in to ChatGPT in your browser…" : codexStatus)
                            .font(.system(size: 13)).foregroundStyle(codexStatus.hasPrefix("Signed in with ChatGPT") ? .green : Tint.soft)
                        Spacer()
                        if !codexStatus.hasPrefix("Signed in with ChatGPT") {
                            Primary(title: CodexSession.executable == nil ? "Install and connect" : "Connect ChatGPT", enabled: !codexBusy) {
                                codexBusy = true
                                Task { codexStatus = await CodexAccount.connect(); codexBusy = false }
                            }
                            .frame(width: 190)
                        }
                    }
                }
            }
        }
        .task(id: aiProvider) { if aiProvider == "chatgpt" { codexStatus = await CodexAccount.status() } }
    }

    private var title: String {
        switch claude.state {
        case .checking: "Checking for Claude…"
        case .notInstalled: "Claude isn't set up yet"
        case .signedOut: "Claude is installed: sign in"
        case .installing: "Installing Claude Code…"
        case .signingIn: "Signing in…"
        case .ready: "Claude is connected"
        case .failed: "That didn't work"
        }
    }

    private var subtitle: String {
        switch claude.state {
        case .notInstalled: "I'll install Claude Code (Anthropic's app for the Mac) and open the sign-in page. No Terminal."
        case .signedOut: "Click Connect and log in with your Claude account in the browser."
        case .installing, .signingIn: claude.detail
        case .ready: "I'll use your Claude plan, so there's nothing extra to pay."
        case .failed(let message): message
        case .checking: ""
        }
    }
}

/// The first real request. Speech recognition has to be there for it: if they skipped the download
/// or it's still going, this step shows it and starts it, instead of a key that silently does nothing.
private struct TryStep: View {
    @ObservedObject var model: OnboardingModel

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.7)) { _ in content(ModelGuard.status(.speech)) }
            .onAppear {
                switch ModelGuard.status(.speech) {
                case .notDownloaded, .failed: model.actions.download(.speech)
                default: break
                }
            }
    }

    @ViewBuilder private func content(_ speech: ModelGuard.Status) -> some View {
        VStack(spacing: 24) {
            Spacer()
            if model.heard == nil, speech != .ready {
                ProgressView(value: progress(speech)).tint(Tint.accent).frame(width: 320)
                Text("Almost ready to listen").font(.system(size: 34, weight: .bold))
                Text(waiting(speech)).font(.system(size: 16)).foregroundStyle(Tint.soft)
                    .multilineTextAlignment(.center).frame(maxWidth: 620)
                if case .failed = speech {
                    Primary(title: "Retry", enabled: true) { model.actions.download(.speech) }.frame(width: 140)
                }
            } else if let heard = model.heard {
                Image(systemName: "checkmark.circle.fill").font(.system(size: 64)).foregroundStyle(.green)
                    .transition(.scale.combined(with: .opacity))
                Text("I heard you").font(.system(size: 34, weight: .bold))
                Text("“\(heard)”").font(.system(size: 18)).foregroundStyle(Tint.soft).multilineTextAlignment(.center).frame(maxWidth: 620)
                Text("My answer is up at the notch.").font(.system(size: 14)).foregroundStyle(Tint.soft)
            } else {
                TimelineView(.animation) { context in
                    let t = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 2.4)
                    KeyCap(label: "⌥", pressed: t < 1.2).scaleEffect(1.4)
                }
                .frame(height: 110)
                Text("Your turn").font(.system(size: 34, weight: .bold))
                Text("Hold the right ⌥ key, say “What can you do?”, then let go.")
                    .font(.system(size: 18)).foregroundStyle(Tint.soft)
            }
            Spacer()
            HStack {
                Button("Back") { model.back() }.buttonStyle(.plain).foregroundStyle(Tint.soft)
                Spacer()
                if model.heard == nil {
                    Button("Skip for now") { model.next() }.buttonStyle(.plain).foregroundStyle(Tint.soft).padding(.trailing, 16)
                }
                Primary(title: "Continue", enabled: model.heard != nil) { model.next() }
            }
        }
    }

    private func progress(_ speech: ModelGuard.Status) -> Double {
        if case .downloading(let fraction) = speech { return fraction }
        return 0
    }

    private func waiting(_ speech: ModelGuard.Status) -> String {
        switch speech {
        case .downloading(let fraction): "Speech recognition is downloading (\(Int(fraction * 100))%). You can try me as soon as it's done."
        case .failed(let message): message
        default: "Getting speech recognition ready. This takes a minute the first time."
        }
    }
}

private struct DoneStep: View {
    @ObservedObject var model: OnboardingModel

    var body: some View {
        VStack(spacing: 16) {
            Spacer()
            Star(size: 56).frame(height: 120)
            Typed(text: "You’re all set, \(Profile.name).")
            VStack(alignment: .leading, spacing: 10) {
                tip("command", "Hold right ⌘ to write with your voice")
                tip("option", "Hold right ⌥ to ask me anything (double-tap for a long one)")
            }
            // What's working now, so nothing is left to discover; anything missing is one place away.
            LazyVGrid(columns: [GridItem(.fixed(300), alignment: .leading), GridItem(.fixed(300), alignment: .leading)], spacing: 8) {
                ForEach(ready, id: \.0) { title, done in
                    HStack(spacing: 8) {
                        Image(systemName: done ? "checkmark.circle.fill" : "circle.dashed").frame(width: 18)
                        Text(title)
                    }
                    .font(.system(size: 13)).foregroundStyle(done ? Color.green : Tint.soft)
                }
            }
            .padding(14)
            .background(Tint.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            if ready.contains(where: { !$0.1 }) {
                Text("Anything not ticked can be added any time in Settings.").font(.system(size: 12)).foregroundStyle(Tint.soft)
            }
            Spacer()
            Primary(title: "Start using Joe") {
                OnboardingModel.savedStep = .hello
                model.actions.finished()
            }
        }
    }

    /// Icons in a fixed-width column, so each line's text starts in the same place.
    private func tip(_ symbol: String, _ text: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).frame(width: 22)
            Text(text)
        }
        .font(.system(size: 15)).foregroundStyle(Tint.soft)
    }

    private var ready: [(String, Bool)] {
        let timetable = Daybook.timetableURL.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
        return [
            ("Speech recognition", ModelGuard.status(.speech) == .ready),
            ("My voice", ModelGuard.status(.voice) == .ready),
            ("ManageBac deadlines and events", !CalendarFeed.links.isEmpty),
            ("Your subjects", !Profile.subjects.isEmpty),
            ("Your timetable", timetable),
            ("Wake-up alarm and morning briefing", AlarmStore.load().contains { $0.repeats != nil && $0.title.lowercased().contains("wake") }),
            ("Notes folder", Assistant.vaultURL != nil),
            ("Gmail", ClaudeConnectors.has("gmail")),
        ]
    }
}

// MARK: - Snapshots

extension Onboarding {
    /// `Joe --onboarding-snapshot <step> <file.png>`: one step of the welcome, drawn off screen.
    @MainActor static func snapshot(step: String, to file: URL, done: @escaping () -> Void) {
        let model = OnboardingModel(actions: .init(greet: { _, _ in }, narrate: { _, _ in }, isSpeaking: { false },
                                                   prepareVoice: {}, download: { _ in }, chooseVault: {}, finished: {}))
        model.step = OnboardingModel.Step.allCases.first { "\($0)" == step } ?? .hello
        let view = NSHostingView(rootView: OnboardingView(model: model).environment(\.colorScheme, .dark))
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 960, height: 660), styleMask: [.borderless], backing: .buffered, defer: false)
        window.backgroundColor = NSColor(red: 0.055, green: 0.063, blue: 0.086, alpha: 1)
        window.contentView = view
        window.orderFrontRegardless()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            MainActor.assumeIsolated {
                if let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                    view.cacheDisplay(in: view.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?.write(to: file)
                }
                done()
            }
        }
    }
}
