import SwiftUI

struct WrappingFlowLayout: Layout {
    var spacing: CGFloat = 8
    var rowSpacing: CGFloat = 8

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        let rows = arrangedRows(proposal: proposal, subviews: subviews)
        let width = rows.map(\.width).max() ?? 0
        let height = rows.reduce(0) { partialResult, row in
            partialResult + row.height
        } + CGFloat(max(rows.count - 1, 0)) * rowSpacing

        return CGSize(
            width: proposal.width ?? width,
            height: height
        )
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        let rows = arrangedRows(
            proposal: ProposedViewSize(width: bounds.width, height: proposal.height),
            subviews: subviews
        )

        var y = bounds.minY
        for row in rows {
            var x = bounds.minX
            for element in row.elements {
                element.subview.place(
                    at: CGPoint(x: x, y: y),
                    proposal: ProposedViewSize(width: element.size.width, height: element.size.height)
                )
                x += element.size.width + spacing
            }
            y += row.height + rowSpacing
        }
    }

    private func arrangedRows(
        proposal: ProposedViewSize,
        subviews: Subviews
    ) -> [Row] {
        let maximumRowWidth = max(proposal.width ?? .greatestFiniteMagnitude, 0)
        var rows: [Row] = []
        var currentRow = Row()

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            let projectedWidth = currentRow.elements.isEmpty
                ? size.width
                : currentRow.width + spacing + size.width

            if !currentRow.elements.isEmpty && projectedWidth > maximumRowWidth {
                rows.append(currentRow)
                currentRow = Row()
            }

            currentRow.elements.append(RowElement(subview: subview, size: size))
            currentRow.width = currentRow.elements.dropLast().reduce(size.width) { partialResult, element in
                partialResult + element.size.width + spacing
            }
            currentRow.height = max(currentRow.height, size.height)
        }

        if !currentRow.elements.isEmpty {
            rows.append(currentRow)
        }

        return rows
    }
}

private struct Row {
    var elements: [RowElement] = []
    var width: CGFloat = 0
    var height: CGFloat = 0
}

private struct RowElement {
    let subview: LayoutSubview
    let size: CGSize
}
