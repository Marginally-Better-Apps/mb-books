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
                    Text("\(Int((book.progress * 100).rounded()))%")
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
                        .accessibilityLabel("\(book.title), \(Int((book.progress * 100).rounded())) percent")
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

/// Today's reading time, streak, and books finished this year.
private struct ReadingGoalsSection: View {
    let books: [Book]

    @Query(sort: \ReadingDay.day, order: .reverse) private var days: [ReadingDay]
    @AppStorage(GoalDefaults.dailyMinutesKey) private var dailyGoal = GoalDefaults.dailyMinutes
    @AppStorage(GoalDefaults.yearlyBooksKey) private var yearlyGoal = GoalDefaults.yearlyBooks

    var body: some View {
        let todayMinutes = (days.first { Calendar.current.isDateInToday($0.day) }?.seconds ?? 0) / 60
        let finishedThisYear = books.filter {
            guard let date = $0.dateFinished else { return false }
            return Calendar.current.isDate(date, equalTo: .now, toGranularity: .year)
        }.count
        let streak = ReadingStats.streak(from: days)

        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "Reading Goals")
            HStack(spacing: 14) {
                GoalCard {
                    HStack(spacing: 14) {
                        ZStack {
                            Circle().stroke(.quaternary, lineWidth: 8)
                            Circle()
                                .trim(from: 0, to: min(1, todayMinutes / Double(max(dailyGoal, 1))))
                                .stroke(.orange.gradient, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                                .rotationEffect(.degrees(-90))
                            Text("\(Int(todayMinutes))")
                                .font(.headline.monospacedDigit())
                        }
                        .frame(width: 56, height: 56)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Today's Reading").font(.subheadline.weight(.semibold))
                            Text("\(Int(todayMinutes)) of \(dailyGoal) min")
                                .font(.caption).foregroundStyle(.secondary)
                            if streak > 0 {
                                Label("\(streak)-day streak", systemImage: "flame.fill")
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(.orange)
                            }
                        }
                    }
                }
                GoalCard {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Books Read This Year").font(.subheadline.weight(.semibold))
                        HStack(spacing: 4) {
                            ForEach(0..<max(yearlyGoal, finishedThisYear), id: \.self) { index in
                                RoundedRectangle(cornerRadius: 2)
                                    .fill(index < finishedThisYear ? AnyShapeStyle(.orange.gradient) : AnyShapeStyle(.quaternary))
                                    .frame(width: 12, height: 18)
                            }
                        }
                        Text("\(finishedThisYear) of \(yearlyGoal)").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.horizontal, 20)
        }
    }
}

private struct GoalCard<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        content
            .frame(maxWidth: .infinity, minHeight: 92, alignment: .leading)
            .padding(14)
            .background(.background.secondary, in: .rect(cornerRadius: 20))
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
