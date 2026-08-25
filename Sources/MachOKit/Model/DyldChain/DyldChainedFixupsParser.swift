//
//  DyldChainedFixupsParser.swift
//

import Foundation

/// A bounded-read failure found while validating chained-fixup metadata.
@_spi(Support)
public struct DyldChainedFixupsReadError: Error, Sendable, Equatable, LocalizedError {
    public enum Location: Sendable, Equatable {
        case header
        case startsInImage
        case segmentOffsets
        case segment(index: Int)
        case pageStarts(segment: Int)
        case multiStart(segment: Int, page: Int)
        case chain(segment: Int, page: Int)
        case imports
        case symbolName
        case resolver
    }

    public enum Reason: Sendable, Equatable {
        case invalidRange(offset: UInt64, byteCount: UInt64, availableByteCount: Int)
        case arithmeticOverflow
        case invalidIndex(index: Int, count: Int)
        case invalidValue(field: String, value: UInt64)
        case unterminatedTable
        case unsupportedFormat(value: UInt64)
    }

    public let location: Location
    public let reason: Reason

    public init(location: Location, reason: Reason) {
        self.location = location
        self.reason = reason
    }

    public var errorDescription: String? {
        "Malformed chained fixups at \(location): \(reason)"
    }
}

internal struct DyldChainedFixupsReadReport<Value> {
    var value: Value
    var failures: [DyldChainedFixupsReadError]
}

internal struct DyldChainedFixupsByteView {
    let bytes: UnsafeRawBufferPointer

    func checkedRange(
        offset: UInt64,
        byteCount: UInt64,
        location: DyldChainedFixupsReadError.Location
    ) throws -> Range<Int> {
        guard let start = Int(exactly: offset),
              let count = Int(exactly: byteCount),
              start <= bytes.count,
              count <= bytes.count - start else {
            throw DyldChainedFixupsReadError(
                location: location,
                reason: .invalidRange(
                    offset: offset,
                    byteCount: byteCount,
                    availableByteCount: bytes.count
                )
            )
        }
        return start ..< start + count
    }

    func loadUnaligned<T>(
        at offset: UInt64,
        as type: T.Type = T.self,
        location: DyldChainedFixupsReadError.Location
    ) throws -> T {
        let range = try checkedRange(
            offset: offset,
            byteCount: UInt64(MemoryLayout<T>.size),
            location: location
        )
        return bytes.loadUnaligned(fromByteOffset: range.lowerBound, as: type)
    }

    func loadArray<T>(
        at offset: UInt64,
        count: UInt64,
        as type: T.Type = T.self,
        location: DyldChainedFixupsReadError.Location
    ) throws -> [T] {
        let byteCount = try checkedMultiply(
            count,
            UInt64(MemoryLayout<T>.size),
            location: location
        )
        let range = try checkedRange(
            offset: offset,
            byteCount: byteCount,
            location: location
        )
        guard let elementCount = Int(exactly: count) else {
            throw DyldChainedFixupsReadError(
                location: location,
                reason: .arithmeticOverflow
            )
        }
        let stride = MemoryLayout<T>.size
        return (0 ..< elementCount).map { index in
            bytes.loadUnaligned(
                fromByteOffset: range.lowerBound + index * stride,
                as: type
            )
        }
    }

    func nullTerminatedString(
        at offset: UInt64,
        location: DyldChainedFixupsReadError.Location
    ) throws -> String {
        let range = try checkedRange(
            offset: offset,
            byteCount: 0,
            location: location
        )
        guard let terminator = (range.lowerBound ..< bytes.count).first(
            where: { bytes[$0] == 0 }
        ) else {
            throw DyldChainedFixupsReadError(
                location: location,
                reason: .unterminatedTable
            )
        }
        return String(
            decoding: bytes[range.lowerBound ..< terminator],
            as: UTF8.self
        )
    }

    func checkedAdd(
        _ lhs: UInt64,
        _ rhs: UInt64,
        location: DyldChainedFixupsReadError.Location
    ) throws -> UInt64 {
        let (result, overflow) = lhs.addingReportingOverflow(rhs)
        guard !overflow else {
            throw DyldChainedFixupsReadError(
                location: location,
                reason: .arithmeticOverflow
            )
        }
        return result
    }

    func checkedMultiply(
        _ lhs: UInt64,
        _ rhs: UInt64,
        location: DyldChainedFixupsReadError.Location
    ) throws -> UInt64 {
        let (result, overflow) = lhs.multipliedReportingOverflow(by: rhs)
        guard !overflow else {
            throw DyldChainedFixupsReadError(
                location: location,
                reason: .arithmeticOverflow
            )
        }
        return result
    }
}

internal struct ParsedDyldChainedFixupsSegment {
    let info: DyldChainedStartsInSegment
    let pageStarts: [UInt16]
    let allStartEntries: [UInt16]
}

internal struct DyldChainedFixupsParser {
    let view: DyldChainedFixupsByteView
    let isSwapped: Bool

    func header() throws -> DyldChainedFixupsHeader {
        let layout: DyldChainedFixupsHeader.Layout = try view.loadUnaligned(
            at: 0,
            location: .header
        )
        let header = DyldChainedFixupsHeader(layout: layout)
        return isSwapped ? header.swapped : header
    }

    func startsInImage() throws -> DyldChainedStartsInImage {
        let header = try header()
        let offset = UInt64(header.layout.starts_offset)
        let layout: DyldChainedStartsInImage.Layout = try view.loadUnaligned(
            at: offset,
            location: .startsInImage
        )
        guard let intOffset = Int(exactly: offset) else {
            throw DyldChainedFixupsReadError(
                location: .startsInImage,
                reason: .arithmeticOverflow
            )
        }
        let starts = DyldChainedStartsInImage(layout: layout, offset: intOffset)
        return isSwapped ? starts.swapped : starts
    }

    func segments(
        of startsInImage: DyldChainedStartsInImage? = nil
    ) -> DyldChainedFixupsReadReport<[ParsedDyldChainedFixupsSegment]> {
        do {
            let starts = try canonicalStartsInImage(for: startsInImage)
            let startsOffset = UInt64(starts.offset)
            let tableFieldOffset = UInt64(
                DyldChainedStartsInImage.layoutOffset(of: \.seg_info_offset)
            )
            let tableOffset = try view.checkedAdd(
                startsOffset,
                tableFieldOffset,
                location: .segmentOffsets
            )
            let tableByteCount = try view.checkedMultiply(
                UInt64(starts.layout.seg_count),
                UInt64(MemoryLayout<UInt32>.size),
                location: .segmentOffsets
            )
            let tableEnd = try view.checkedAdd(
                tableOffset,
                tableByteCount,
                location: .segmentOffsets
            )
            let importsOffset = UInt64(try header().layout.imports_offset)
            guard importsOffset == 0 || tableEnd <= importsOffset else {
                throw DyldChainedFixupsReadError(
                    location: .segmentOffsets,
                    reason: .invalidRange(
                        offset: tableOffset,
                        byteCount: tableByteCount,
                        availableByteCount: Int(exactly: importsOffset) ?? 0
                    )
                )
            }
            var offsets: [UInt32] = try view.loadArray(
                at: tableOffset,
                count: UInt64(starts.layout.seg_count),
                location: .segmentOffsets
            )
            if isSwapped {
                offsets = offsets.map(\.byteSwapped)
            }

            var parsed: [ParsedDyldChainedFixupsSegment] = []
            var failures: [DyldChainedFixupsReadError] = []
            for (segmentIndex, relativeOffset) in offsets.enumerated() {
                // A zero entry is the format's normal "no fixups for this segment" sentinel.
                guard relativeOffset != 0 else { continue }
                do {
                    let absoluteOffset = try view.checkedAdd(
                        startsOffset,
                        UInt64(relativeOffset),
                        location: .segment(index: segmentIndex)
                    )
                    guard absoluteOffset >= tableEnd else {
                        throw DyldChainedFixupsReadError(
                            location: .segment(index: segmentIndex),
                            reason: .invalidValue(
                                field: "seg_info_offset",
                                value: UInt64(relativeOffset)
                            )
                        )
                    }
                    parsed.append(
                        try segment(
                            at: UInt64(relativeOffset),
                            startsInImageOffset: startsOffset,
                            segmentIndex: segmentIndex
                        )
                    )
                } catch let error as DyldChainedFixupsReadError {
                    failures.append(error)
                } catch {
                    failures.append(
                        .init(location: .segment(index: segmentIndex), reason: .arithmeticOverflow)
                    )
                }
            }
            return .init(value: parsed, failures: failures)
        } catch let error as DyldChainedFixupsReadError {
            return .init(value: [], failures: [error])
        } catch {
            return .init(
                value: [],
                failures: [.init(location: .startsInImage, reason: .arithmeticOverflow)]
            )
        }
    }

    func segment(
        matching info: DyldChainedStartsInSegment
    ) throws -> ParsedDyldChainedFixupsSegment {
        let starts = try startsInImage()
        guard let absoluteOffset = UInt64(exactly: info.offset),
              let startsOffset = UInt64(exactly: starts.offset) else {
            throw DyldChainedFixupsReadError(
                location: .segment(index: info.segmentIndex),
                reason: .arithmeticOverflow
            )
        }
        guard absoluteOffset >= startsOffset else {
            throw DyldChainedFixupsReadError(
                location: .segment(index: info.segmentIndex),
                reason: .invalidValue(field: "offset", value: absoluteOffset)
            )
        }
        return try segment(
            at: absoluteOffset - startsOffset,
            startsInImageOffset: startsOffset,
            segmentIndex: info.segmentIndex
        )
    }

    func imports() throws -> [DyldChainedImport] {
        let header = try header()
        let count = UInt64(header.layout.imports_count)
        guard count > 0 else { return [] }
        guard let format = header.importsFormat else {
            throw DyldChainedFixupsReadError(
                location: .imports,
                reason: .unsupportedFormat(value: UInt64(header.layout.imports_format))
            )
        }
        let offset = UInt64(header.layout.imports_offset)

        switch format {
        case .general:
            let values: [DyldChainedImportGeneral.Layout] = try importLayouts(
                header: header,
                offset: offset,
                count: count
            )
            if isSwapped {
                return values.map { DyldChainedImportGeneral(layout: $0).swapped }.map(DyldChainedImport.general)
            }
            return values.map { .general(.init(layout: $0)) }
        case .addend:
            let values: [DyldChainedImportAddend.Layout] = try importLayouts(
                header: header,
                offset: offset,
                count: count
            )
            if isSwapped {
                return values.map { DyldChainedImportAddend(layout: $0).swapped }.map(DyldChainedImport.addend)
            }
            return values.map { .addend(.init(layout: $0)) }
        case .addend64:
            let values: [DyldChainedImportAddend64.Layout] = try importLayouts(
                header: header,
                offset: offset,
                count: count
            )
            if isSwapped {
                return values.map { DyldChainedImportAddend64(layout: $0).swapped }.map(DyldChainedImport.addend64)
            }
            return values.map { .addend64(.init(layout: $0)) }
        }
    }

    func symbolName(for nameOffset: Int) throws -> String {
        let header = try header()
        guard header.symbolsFormat == .uncompressed else {
            throw DyldChainedFixupsReadError(
                location: .symbolName,
                reason: .unsupportedFormat(value: UInt64(header.layout.symbols_format))
            )
        }
        guard let relativeOffset = UInt64(exactly: nameOffset) else {
            throw DyldChainedFixupsReadError(
                location: .symbolName,
                reason: .invalidValue(field: "nameOffset", value: UInt64(bitPattern: Int64(nameOffset)))
            )
        }
        let offset = try view.checkedAdd(
            UInt64(header.layout.symbols_offset),
            relativeOffset,
            location: .symbolName
        )
        return try view.nullTerminatedString(at: offset, location: .symbolName)
    }

    private func canonicalStartsInImage(
        for candidate: DyldChainedStartsInImage?
    ) throws -> DyldChainedStartsInImage {
        let canonical = try startsInImage()
        guard let candidate else { return canonical }
        guard candidate.offset == canonical.offset else {
            throw DyldChainedFixupsReadError(
                location: .startsInImage,
                reason: .invalidValue(
                    field: "offset",
                    value: UInt64(bitPattern: Int64(candidate.offset))
                )
            )
        }
        return canonical
    }

    private func importLayouts<T>(
        header: DyldChainedFixupsHeader,
        offset: UInt64,
        count: UInt64
    ) throws -> [T] {
        let byteCount = try view.checkedMultiply(
            count,
            UInt64(MemoryLayout<T>.size),
            location: .imports
        )
        let end = try view.checkedAdd(offset, byteCount, location: .imports)
        let symbolsOffset = UInt64(header.layout.symbols_offset)
        guard symbolsOffset == 0 || end <= symbolsOffset else {
            throw DyldChainedFixupsReadError(
                location: .imports,
                reason: .invalidRange(
                    offset: offset,
                    byteCount: byteCount,
                    availableByteCount: Int(exactly: symbolsOffset) ?? 0
                )
            )
        }
        return try view.loadArray(
            at: offset,
            count: count,
            location: .imports
        )
    }

    private func segment(
        at relativeOffset: UInt64,
        startsInImageOffset: UInt64,
        segmentIndex: Int
    ) throws -> ParsedDyldChainedFixupsSegment {
        let location = DyldChainedFixupsReadError.Location.segment(index: segmentIndex)
        let offset = try view.checkedAdd(
            startsInImageOffset,
            relativeOffset,
            location: location
        )
        let layout: DyldChainedStartsInSegment.Layout = try view.loadUnaligned(
            at: offset,
            location: location
        )
        guard let intOffset = Int(exactly: offset) else {
            throw DyldChainedFixupsReadError(location: location, reason: .arithmeticOverflow)
        }
        var info = DyldChainedStartsInSegment(
            layout: layout,
            offset: intOffset,
            segmentIndex: segmentIndex
        )
        if isSwapped {
            info = info.swapped
        }

        let pageStartsFieldOffset = UInt64(
            DyldChainedStartsInSegment.layoutOffset(of: \.page_start)
        )
        let pageCount = UInt64(info.layout.page_count)
        let pagePrefixByteCount = try view.checkedMultiply(
            pageCount,
            UInt64(MemoryLayout<UInt16>.size),
            location: .pageStarts(segment: segmentIndex)
        )
        let pageTableMinimumSize = try view.checkedAdd(
            pageStartsFieldOffset,
            pagePrefixByteCount,
            location: .pageStarts(segment: segmentIndex)
        )
        let minimumSize = max(
            UInt64(MemoryLayout<DyldChainedStartsInSegment.Layout>.size),
            pageTableMinimumSize
        )
        let declaredSize = UInt64(info.layout.size)
        guard declaredSize >= minimumSize else {
            throw DyldChainedFixupsReadError(
                location: .pageStarts(segment: segmentIndex),
                reason: .invalidRange(
                    offset: offset,
                    byteCount: minimumSize,
                    availableByteCount: Int(exactly: declaredSize) ?? 0
                )
            )
        }
        _ = try view.checkedRange(
            offset: offset,
            byteCount: declaredSize,
            location: location
        )
        let segmentEnd = try view.checkedAdd(
            offset,
            declaredSize,
            location: location
        )
        let importsOffset = UInt64(try header().layout.imports_offset)
        guard importsOffset == 0 || segmentEnd <= importsOffset else {
            throw DyldChainedFixupsReadError(
                location: location,
                reason: .invalidRange(
                    offset: offset,
                    byteCount: declaredSize,
                    availableByteCount: Int(exactly: importsOffset) ?? 0
                )
            )
        }

        let flexibleByteCount = declaredSize - pageStartsFieldOffset
        guard flexibleByteCount.isMultiple(of: UInt64(MemoryLayout<UInt16>.size)) else {
            throw DyldChainedFixupsReadError(
                location: .pageStarts(segment: segmentIndex),
                reason: .invalidValue(field: "size", value: declaredSize)
            )
        }
        let entryCount = flexibleByteCount / UInt64(MemoryLayout<UInt16>.size)
        let entriesOffset = try view.checkedAdd(
            offset,
            pageStartsFieldOffset,
            location: .pageStarts(segment: segmentIndex)
        )
        var allEntries: [UInt16] = try view.loadArray(
            at: entriesOffset,
            count: entryCount,
            location: .pageStarts(segment: segmentIndex)
        )
        if isSwapped {
            allEntries = allEntries.map(\.byteSwapped)
        }
        guard let pageCountInt = Int(exactly: pageCount) else {
            throw DyldChainedFixupsReadError(
                location: .pageStarts(segment: segmentIndex),
                reason: .arithmeticOverflow
            )
        }
        return .init(
            info: info,
            pageStarts: Array(allEntries.prefix(pageCountInt)),
            allStartEntries: allEntries
        )
    }
}
