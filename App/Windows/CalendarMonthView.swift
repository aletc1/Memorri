import AppKit
import MemorriCore
import SwiftUI

/// The month calendar of the Items window (spec 012): each item as a chip in the cell of its day. The grid itself comes from `ItemCalendar`.
struct CalendarMonthView: View {
    let model: ItemsViewModel

    var body: some View {
        let grid = model.grid
        VStack(spacing: 0) {
            header(grid)
            Divider()
            weekdays(grid)
            VStack(spacing: 1) {
                ForEach(Array(grid.weeks.enumerated()), id: \.offset) { _, week in
                    HStack(spacing: 1) {
                        ForEach(week) { cell in DayCell(cell: cell, model: model) }
                    }
                }
            }
            .background(Color(nsColor: .separatorColor))
            if !grid.undated.isEmpty { undated(grid.undated) }
            if grid.weeks.flatMap({ $0 }).allSatisfy({ $0.chips.isEmpty }) && grid.undated.isEmpty {
                Text("Nothing on this month").font(.callout).foregroundStyle(.secondary).padding(6)
            }
        }
    }

    private func header(_ grid: MonthGrid) -> some View {
        HStack(spacing: 8) {
            Button { model.shiftMonth(-1) } label: { Image(systemName: "chevron.left") }
                .keyboardShortcut(.leftArrow, modifiers: .command).help("Previous month").accessibilityLabel("Previous month")
            Text(grid.title).font(.headline).frame(minWidth: 130)
            Button { model.shiftMonth(1) } label: { Image(systemName: "chevron.right") }
                .keyboardShortcut(.rightArrow, modifiers: .command).help("Next month").accessibilityLabel("Next month")
            Spacer(minLength: 0)
            Button("Today") { model.goToToday() }.help("Go back to the month of today").accessibilityLabel("Go to today")
        }
        .padding(8)
    }

    private func weekdays(_ grid: MonthGrid) -> some View {
        HStack(spacing: 1) {
            ForEach(Array(grid.weekdays.enumerated()), id: \.offset) { _, name in
                Text(name).font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(.vertical, 3)
            }
        }
        .accessibilityHidden(true)
    }

    private func undated(_ chips: [CalendarChip]) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Divider()
            Text("No date").font(.caption).foregroundStyle(.secondary)
            ScrollView { VStack(spacing: 2) { ForEach(chips) { ChipButton(chip: $0, model: model) } } }.frame(maxHeight: 90)
        }
        .padding(8)
    }
}

private struct DayCell: View {
    let cell: CalendarCell
    let model: ItemsViewModel
    @State private var showAll = false

    private var spoken: String {
        let count = cell.chips.count
        return "\(cell.day.text), \(count == 0 ? "no items" : count == 1 ? "1 item" : "\(count) items")"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text("\(cell.day.day)").font(.caption.weight(cell.isToday ? .bold : .regular))
                    .foregroundStyle(cell.isToday ? Color.white : (cell.inMonth ? Color.primary : Color.secondary))
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(cell.isToday ? Color.accentColor : Color.clear, in: Capsule())
                Spacer(minLength: 0)
            }
            ForEach(cell.shown) { ChipButton(chip: $0, model: model) }
            if cell.hiddenCount > 0 {
                Button("+\(cell.hiddenCount) more") { showAll = true }
                    .buttonStyle(.plain).font(.caption2).foregroundStyle(.secondary)
                    .popover(isPresented: $showAll) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(cell.day.text).font(.headline)
                            ForEach(cell.chips) { ChipButton(chip: $0, model: model) }
                        }
                        .padding(10).frame(width: 260)
                    }
                    .accessibilityLabel("\(cell.hiddenCount) more items on \(cell.day.text)")
            }
            Spacer(minLength: 0)
        }
        .padding(3)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(cell.inMonth ? Color(nsColor: .controlBackgroundColor) : Color(nsColor: .windowBackgroundColor))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(spoken)
    }
}

private struct ChipButton: View {
    let chip: CalendarChip
    let model: ItemsViewModel

    private var symbol: String {
        switch chip.kind {
        case .appointment: "calendar"
        case .task: "checklist"
        case .reminder: "bell"
        case .deadline: "flag"
        }
    }

    var body: some View {
        let selected = model.selection.contains(chip.id)
        Button { model.choose(chip.id, extending: NSEvent.modifierFlags.contains(.command)) } label: {
            HStack(spacing: 3) {
                Image(systemName: symbol).imageScale(.small)
                if let time = chip.time { Text(time).monospacedDigit() }
                Text(chip.title).lineLimit(1)
                if chip.needsReview { Image(systemName: "circle.fill").foregroundStyle(.orange).imageScale(.small) }
            }
            .font(.caption)
            .padding(.horizontal, 4).padding(.vertical, 2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? Color.accentColor.opacity(0.35) : Color.secondary.opacity(0.15), in: RoundedRectangle(cornerRadius: 4))
            .opacity(chip.dimmed ? 0.5 : 1)
        }
        .buttonStyle(.plain)
        .help(chip.title)
        .accessibilityLabel(chip.spokenLabel)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
