import SwiftUI

struct TreemapLayout: Layout {
    var weights: [Double]
    
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        return proposal.replacingUnspecifiedDimensions()
    }
    
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rects = squarify(weights: weights, rect: bounds)
        for (index, subview) in subviews.enumerated() {
            guard index < rects.count else { break }
            let rect = rects[index]
            subview.place(at: CGPoint(x: rect.minX, y: rect.minY), proposal: ProposedViewSize(rect.size))
        }
    }
    
    private func squarify(weights: [Double], rect: CGRect) -> [CGRect] {
        let total = weights.reduce(0, +)
        guard total > 0 else { return [] }
        let areas = weights.map { CGFloat($0 / total) * rect.width * rect.height }
        
        var remainingAreas = areas
        var remainingRect = rect
        var result: [CGRect] = []
        
        while !remainingAreas.isEmpty {
            let vertical = remainingRect.width >= remainingRect.height
            let side = vertical ? remainingRect.height : remainingRect.width
            
            var row: [CGFloat] = []
            var rowSum: CGFloat = 0
            var temp = remainingAreas
            var bestWorst: CGFloat = .greatestFiniteMagnitude
            
            while !temp.isEmpty {
                let next = temp.removeFirst()
                let newRow = row + [next]
                let newSum = rowSum + next
                let newWorst = worstRatio(weights: newRow, sum: newSum, side: side)
                if row.isEmpty || newWorst < bestWorst {
                    row = newRow
                    rowSum = newSum
                    bestWorst = newWorst
                    remainingAreas = temp
                } else {
                    temp.insert(next, at: 0)
                    break
                }
            }
            
            let (rowRect, newRemaining) = splitRect(rect: remainingRect, area: rowSum, vertical: vertical)
            let rowRects = tileRow(areas: row, rect: rowRect, vertical: vertical)
            result.append(contentsOf: rowRects)
            remainingRect = newRemaining
        }
        
        return result
    }
    
    private func worstRatio(weights: [CGFloat], sum: CGFloat, side: CGFloat) -> CGFloat {
        guard sum > 0, side > 0, !weights.isEmpty else { return .infinity }
        let maxW = weights.max() ?? 0
        let minW = weights.min() ?? 0
        let sideSquared = side * side
        let sumSquared = sum * sum
        let ratio1 = (sideSquared * maxW) / sumSquared
        let ratio2 = sumSquared / (sideSquared * minW)
        return max(ratio1, ratio2)
    }
    
    private func splitRect(rect: CGRect, area: CGFloat, vertical: Bool) -> (CGRect, CGRect) {
        if vertical {
            let width = min(area / rect.height, rect.width)
            let rowRect = CGRect(x: rect.minX, y: rect.minY, width: width, height: rect.height)
            let remaining = CGRect(x: rect.minX + width, y: rect.minY, width: rect.width - width, height: rect.height)
            return (rowRect, remaining)
        } else {
            let height = min(area / rect.width, rect.height)
            let rowRect = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: height)
            let remaining = CGRect(x: rect.minX, y: rect.minY + height, width: rect.width, height: rect.height - height)
            return (rowRect, remaining)
        }
    }
    
    private func tileRow(areas: [CGFloat], rect: CGRect, vertical: Bool) -> [CGRect] {
        let total = areas.reduce(0, +)
        guard total > 0 else { return [] }
        var offset: CGFloat = 0
        var rects: [CGRect] = []
        for area in areas {
            if vertical {
                // Row is a full-width column; slice it by height so each tile keeps the full row width.
                let height = (area / total) * rect.height
                rects.append(CGRect(x: rect.minX, y: rect.minY + offset, width: rect.width, height: height))
                offset += height
            } else {
                // Row is a full-height band; slice it by width so each tile keeps the full row height.
                let width = (area / total) * rect.width
                rects.append(CGRect(x: rect.minX + offset, y: rect.minY, width: width, height: rect.height))
                offset += width
            }
        }
        return rects
    }
}
