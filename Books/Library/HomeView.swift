import SwiftData
import SwiftUI

enum GoalDefaults {
    static let dailyMinutesKey = "dailyReadingGoalMinutes"
    static let yearlyBooksKey = "yearlyBooksGoal"
    static let dailyMinutes = 5
    static let yearlyBooks = 3
}

struct HomeView: View {
    @Query(sort: \Book.dateAdded, order: .reverse) private var books: [Book]

    var body: some View {
        NavigationStack {
            ScrollView {
                if books.isEmpty {
                    EmptyLibraryView().padding(.top, 80)
                } else {
                    LazyVStack(alignment: .leading, spacing: 32) {
                        let reading = books.filter(\.isReading).sorted { ($0.lastOpened ?? .distantPast) > ($1.lastOpened ?? .distantPast) }
                        if !reading.isEmpty {
                            ContinueCarousel(books: Array(reading.prefix(10)))
                        }
                        ReadingGoalsSection(books: books)
                        let wantToRead = books.filter(\.wantToRead)
                        if !wantToRead.isEmpty {
                            BookShelf(title: "Want to Read", books: wantToRead, sourcePrefix: "home-want")
                        }
                        BookShelf(title: "Recently Added", books: Array(books.prefix(15)), sourcePrefix: "home-recent")
                    }
                    .padding(.vertical)
                }
            }
            .navigationTitle("Home")
            .toolbar { LibraryToolbar() }
        }
    }
}

struct EmptyLibraryView: View {
    @Environment(\.importBooks) private var importBooks

    var body: some View {
        ContentUnavailableView {
            Label("Your Library Is Empty", systemImage: "books.vertical")
        } description: {
            Text("Add EPUB books from Files, or open an EPUB from another app with MB Books.")
        } actions: {
            Button("Add Books", systemImage: "plus") { importBooks() }
                .buttonStyle(.glassProminent)
                .accessibilityIdentifier("library.addBooks")
        }
    }
}

/// A cover with its progress underneath, as wide as the cover whatever its shape.
private struct ContinueItem: View {
    let book: Book
    let source: String
    @State private var coverWidth: CGFloat = 160

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            BookCover(book: book, cornerRadius: 6)
                .frame(height: 250, alignment: .bottom)
                .fixedSize(horizontal: true, vertical: false)
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { coverWidth = max(100, $0) }
                .zoomSource(source)
            VStack(alignment: .leading, spacing: 4) {
                ProgressView(value: book.progress)
                    .tint(.primary)
                HStack {
                    Text(book.percentRead, format: .percent)
                        .font(.caption.weight(.semibold).monospacedDigit())
                    Spacer(minLength: 4)
                    if let opened = book.lastOpened {
                        Text(opened, format: .relative(presentation: .named))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
            .frame(width: coverWidth)
        }
    }
}

/// Large covers of books in progress, like Apple Books' "Continue" row.
private struct ContinueCarousel: View {
    let books: [Book]
    @Environment(\.openBook) private var openBook

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "Continue")
            ScrollView(.horizontal) {
                LazyHStack(alignment: .bottom, spacing: 20) {
                    ForEach(books) { book in
                        let source = "home-continue-\(book.id)"
                        Button {
                            openBook(book, source)
                        } label: {
                            ContinueItem(book: book, source: source)
                        }
                        .buttonStyle(.plain)
                        .bookInteractions(book)
                        .accessibilityLabel("\(book.title), \(book.percentRead.formatted(.percent))")
                        .accessibilityIdentifier("continue.\(book.title)")
                    }
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.viewAligned)
            .contentMargins(.horizontal, 20, for: .scrollContent)
            .scrollIndicators(.hidden)
        }
    }
}

/// Today's reading time, streak, and books finished this year. Tapping a card opens Settings to change the goals.
private struct ReadingGoalsSection: View {
    let books: [Book]

    @Query(sort: \ReadingDay.day, order: .reverse) private var days: [ReadingDay]
    @AppStorage(GoalDefaults.dailyMinutesKey) private var dailyGoal = GoalDefaults.dailyMinutes
    @AppStorage(GoalDefaults.yearlyBooksKey) private var yearlyGoal = GoalDefaults.yearlyBooks
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let todayMinutes = Int((days.first { Calendar.current.isDateInToday($0.day) }?.seconds ?? 0) / 60)
        let finishedThisYear = books.filter {
            guard let date = $0.dateFinished else { return false }
            return Calendar.current.isDate(date, equalTo: .now, toGranularity: .year)
        }.count
        let streak = ReadingStats.streak(from: days)
        // Side by side, unless the text is too large to share a row.
        let layout = dynamicTypeSize.isAccessibilitySize ? AnyLayout(VStackLayout(spacing: 12)) : AnyLayout(HStackLayout(spacing: 12))

        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "Reading Goals")
            layout {
                GoalCard(title: "Today", value: todayMinutes, goal: "of \(dailyGoal) min") {
                    GoalRing(progress: Double(todayMinutes) / Double(max(dailyGoal, 1)))
                } detail: {
                    if streak > 0 {
                        Label("\(streak)-day streak", systemImage: "flame.fill")
                            .foregroundStyle(.tint)
                    } else {
                        Text(todayMinutes >= dailyGoal ? "Goal met" : "\(max(dailyGoal - todayMinutes, 0)) min to go")
                            .foregroundStyle(.secondary)
                    }
                }
                .accessibilityIdentifier("goals.today")
                GoalCard(title: "This Year", value: finishedThisYear, goal: "of \(yearlyGoal) books") {
                    EmptyView()
                } detail: {
                    BooksReadMeter(finished: finishedThisYear, goal: yearlyGoal)
                }
                .accessibilityIdentifier("goals.year")
            }
            .buttonStyle(.plain)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 20)
        }
    }
}

/// A goal: its title, how far along it is, and a detail line. Opens Settings, where goals are changed.
private struct GoalCard<Accessory: View, Detail: View>: View {
    let title: LocalizedStringKey
    let value: Int
    let goal: LocalizedStringKey
    @ViewBuilder let accessory: Accessory
    @ViewBuilder let detail: Detail

    @Environment(\.showSettings) private var showSettings

    var body: some View {
        Button(action: showSettings) {
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(value, format: .number)
                        .font(.system(.title, design: .rounded, weight: .bold))
                        .contentTransition(.numericText())
                    Text(goal)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                detail
                    .font(.footnote.weight(.medium))
                    .frame(minHeight: 18, alignment: .leading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            // An overlay, so the cards' rows line up whether or not they have an accessory.
            .overlay(alignment: .topTrailing) { accessory }
            .padding(16)
            .background(.background.secondary, in: .rect(cornerRadius: 20))
            .contentShape(.rect(cornerRadius: 20))
        }
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens Settings to change your reading goals.")
    }
}

/// A small ring showing today's progress toward the daily goal.
private struct GoalRing: View {
    let progress: Double

    var body: some View {
        ZStack {
            Circle().stroke(.quaternary, lineWidth: 5)
            Circle()
                .trim(from: 0, to: min(1, progress))
                .stroke(.tint, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: 26, height: 26)
        .accessibilityHidden(true)
    }
}

/// One mark per book for small goals; a bar for larger ones, whose marks wouldn't fit.
private struct BooksReadMeter: View {
    let finished: Int
    let goal: Int

    var body: some View {
        let count = max(goal, finished)
        Group {
            if count <= 12 {
                HStack(spacing: 4) {
                    ForEach(0..<count, id: \.self) { index in
                        Capsule()
                            .fill(index < finished ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary))
                            .frame(maxWidth: 14)
                    }
                }
            } else {
                GeometryReader { proxy in
                    Capsule()
                        .fill(.quaternary)
                        .overlay(alignment: .leading) {
                            Capsule()
                                .fill(.tint)
                                .frame(width: proxy.size.width * min(1, Double(finished) / Double(max(goal, 1))))
                        }
                }
            }
        }
        .frame(height: 8)
        .accessibilityHidden(true)
    }
}

/// A titled horizontal row of covers.
struct BookShelf: View {
    let title: LocalizedStringKey
    let books: [Book]
    let sourcePrefix: String

    @Environment(\.openBook) private var openBook

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: title)
            ScrollView(.horizontal) {
                LazyHStack(alignment: .bottom, spacing: 16) {
                    ForEach(books) { book in
                        let source = "\(sourcePrefix)-\(book.id)"
                        Button {
                            openBook(book, source)
                        } label: {
                            VStack(alignment: .leading, spacing: 8) {
                                BookCover(book: book)
                                    .frame(height: 170, alignment: .bottom)
                                    .zoomSource(source)
                                BookProgressBadge(book: book)
                            }
                        }
                        .buttonStyle(.plain)
                        .bookInteractions(book)
                        .accessibilityLabel(book.title)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.viewAligned)
            .contentMargins(.horizontal, 20, for: .scrollContent)
            .scrollIndicators(.hidden)
        }
    }
}

struct SectionHeader: View {
    let title: LocalizedStringKey

    var body: some View {
        Text(title)
            .font(.title2.weight(.bold))
            .padding(.horizontal, 20)
            .accessibilityAddTraits(.isHeader)
    }
}

extension View {
    /// Marks this view as the source of the zoom transition into the reader.
    func zoomSource(_ id: String) -> some View {
        modifier(ZoomSource(id: id))
    }
}

private struct ZoomSource: ViewModifier {
    let id: String
    @Environment(\.readerTransition) private var namespace

    func body(content: Content) -> some View {
        if let namespace {
            content.matchedTransitionSource(id: id, in: namespace)
        } else {
            content
        }
    }
}
