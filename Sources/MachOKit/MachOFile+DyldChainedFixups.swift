//
//  MachOFile+DyldChainedFixups.swift
//
//
//  Created by p-x9 on 2024/01/11.
//
//

import Foundation
#if compiler(>=6.0) || (compiler(>=5.10) && hasFeature(AccessLevelOnImport))
internal import FileIO
internal import FileIOBinary
#else
@_implementationOnly import FileIO
@_implementationOnly import FileIOBinary
#endif
import MachOKitC

internal enum MachOFileChainedFixupsSourceState {
    case absent
    case available(MachOFile.DyldChainedFixups)
    case failed(DyldChainedFixupsReadError)
}

extension MachOFile {
    public struct DyldChainedFixups {
        typealias FileSlice = File.FileSlice

        let fileSlice: FileSlice
        let isSwapped: Bool
    }
}

extension MachOFile.DyldChainedFixups: DyldChainedFixupsProtocol {
    public var header: DyldChainedFixupsHeader? {
        try? parser.header()
    }

    public var startsInImage: DyldChainedStartsInImage? {
        try? parser.startsInImage()
    }

    public func startsInSegments(
        of startsInImage: DyldChainedStartsInImage?
    ) -> [DyldChainedStartsInSegment] {
        guard let startsInImage else { return [] }
        return parser.segments(of: startsInImage).value.map(\.info)
    }

    // xcrun dyld_info -fixup_chains "Path to Binary"
    public func pages(
        of startsInSegment: DyldChainedStartsInSegment?
    ) -> [DyldChainedPage] {
        guard let startsInSegment else { return [] }
        guard let segment = try? parser.segment(matching: startsInSegment) else {
            return []
        }
        return segment.pageStarts.enumerated().map {
            .init(offset: $1, index: $0)
        }
    }

    public var imports: [DyldChainedImport] {
        (try? parser.imports()) ?? []
    }

    public func symbolName(for nameOffset: Int) -> String? {
        try? parser.symbolName(for: nameOffset)
    }
}

extension MachOFile.DyldChainedFixups {
    internal var parser: DyldChainedFixupsParser {
        .init(
            view: .init(
                bytes: .init(start: fileSlice.ptr, count: fileSlice.size)
            ),
            isSwapped: isSwapped
        )
    }
}

extension MachOFile {
    internal func loadChainedFixupsSourceState() -> MachOFileChainedFixupsSourceState {
        guard let info = loadCommands.dyldChainedFixups else {
            return .absent
        }
        let offset = UInt64(info.layout.dataoff)
        let byteCount = UInt64(info.layout.datasize)
        guard let linkeditRange = chainedFixupsLinkeditRange(),
              offset >= linkeditRange.offset,
              byteCount > 0 else {
            return .failed(
                .init(
                    location: .payload,
                    reason: .invalidRange(
                        offset: offset,
                        byteCount: byteCount,
                        availableByteCount: 0
                    )
                )
            )
        }
        let relativeOffset = offset - linkeditRange.offset
        guard relativeOffset <= linkeditRange.size,
              byteCount <= linkeditRange.size - relativeOffset,
              let intOffset = Int(exactly: offset),
              let intByteCount = Int(exactly: byteCount),
              let fileSlice = _fileSliceForLinkEditData(
                offset: intOffset,
                length: intByteCount
              ) else {
            return .failed(
                .init(
                    location: .payload,
                    reason: .invalidRange(
                        offset: offset,
                        byteCount: byteCount,
                        availableByteCount: Int(exactly: linkeditRange.size) ?? 0
                    )
                )
            )
        }
        return .available(
            .init(fileSlice: fileSlice, isSwapped: isSwapped)
        )
    }

    private func chainedFixupsLinkeditRange() -> (offset: UInt64, size: UInt64)? {
        if let linkedit = loadCommands.linkedit64 {
            return (linkedit.layout.fileoff, linkedit.layout.filesize)
        }
        if let linkedit = loadCommands.linkedit {
            return (
                UInt64(linkedit.layout.fileoff),
                UInt64(linkedit.layout.filesize)
            )
        }
        return nil
    }
}

internal struct DyldChainedFixupPointerReport {
    var pointers: [DyldChainedFixupPointer]
    var failures: [DyldChainedFixupsReadError]
}

internal struct DyldChainedFixupPointerIndex {
    var pointersByFileOffset: [Int: DyldChainedFixupPointer]
    var orderedPointers: [DyldChainedFixupPointer]
    var failures: [DyldChainedFixupsReadError]

    mutating func insert(_ pointer: DyldChainedFixupPointer) {
        guard pointersByFileOffset[pointer.offset] == nil else {
            failures.append(
                .init(
                    location: .resolver,
                    reason: .invalidValue(
                        field: "duplicatePointerOffset",
                        value: UInt64(exactly: pointer.offset) ?? 0
                    )
                )
            )
            return
        }
        pointersByFileOffset[pointer.offset] = pointer
        orderedPointers.append(pointer)
    }
}

private struct DyldChainedFixupFileSegment {
    let fileOffset: UInt64
    let fileSize: UInt64
    let virtualMemoryOffset: UInt64
}

extension MachOFile.DyldChainedFixups {
    // https://github.com/apple-oss-distributions/dyld/blob/d1a0f6869ece370913a3f749617e457f3b4cd7c4/common/MachOLoaded.cpp#L884
    // xcrun dyld_info -fixup_chain_details "Path to Binary"
    // xcrun dyld_info -fixups "Path to Binary"
    public func pointers(
        of startsInSegment: DyldChainedStartsInSegment,
        in machO: MachOFile
    ) -> [DyldChainedFixupPointer] {
        guard let segment = try? parser.segment(matching: startsInSegment) else {
            return []
        }
        return pointerReport(for: segment, in: machO).pointers
    }

    public func pointer(
        for offset: UInt64,
        in machO: MachOFile
    ) -> DyldChainedFixupPointer? {
        machO.chainedFixupPointer(at: offset)
    }

    internal func pointerReport(in machO: MachOFile) -> DyldChainedFixupPointerReport {
        let index = pointerIndex(in: machO)
        return .init(
            pointers: index.orderedPointers,
            failures: index.failures
        )
    }

    internal func pointerIndex(in machO: MachOFile) -> DyldChainedFixupPointerIndex {
        let segmentReport = parser.segments()
        var index = DyldChainedFixupPointerIndex(
            pointersByFileOffset: [:],
            orderedPointers: [],
            failures: segmentReport.failures
        )
        if let failure = pointerFormatConsistencyFailure(
            in: segmentReport.value
        ) {
            index.failures.append(failure)
            return index
        }
        do {
            try validateSegmentCount(in: machO)
        } catch let error as DyldChainedFixupsReadError {
            if !index.failures.contains(error) {
                index.failures.append(error)
            }
            return index
        } catch {
            index.failures.append(.init(location: .startsInImage, reason: .arithmeticOverflow))
            return index
        }
        for segment in segmentReport.value {
            let segmentPointers = pointerReport(for: segment, in: machO)
            index.failures.append(contentsOf: segmentPointers.failures)
            for pointer in segmentPointers.pointers {
                index.insert(pointer)
            }
        }
        return index
    }

    private func pointerFormatConsistencyFailure(
        in segments: [ParsedDyldChainedFixupsSegment]
    ) -> DyldChainedFixupsReadError? {
        guard let first = segments.first else { return nil }
        let expectedFormat = first.info.layout.pointer_format
        for segment in segments.dropFirst() {
            guard segment.info.layout.pointer_format != expectedFormat else {
                continue
            }
            return .init(
                location: .segment(index: segment.info.segmentIndex),
                reason: .invalidValue(
                    field: "pointer_format consistency",
                    value: UInt64(segment.info.layout.pointer_format)
                )
            )
        }
        return nil
    }

    private func pointerReport(
        for startsInSegment: ParsedDyldChainedFixupsSegment,
        in machO: MachOFile
    ) -> DyldChainedFixupPointerReport {
        let segmentIndex = startsInSegment.info.segmentIndex
        let location = DyldChainedFixupsReadError.Location.segment(index: segmentIndex)
        do {
            try validateSegmentCount(in: machO)
        } catch let error as DyldChainedFixupsReadError {
            return .init(pointers: [], failures: [error])
        } catch {
            return .init(
                pointers: [],
                failures: [.init(location: .segmentOffsets, reason: .arithmeticOverflow)]
            )
        }
        guard let pointerFormat = startsInSegment.info.pointerFormat else {
            return .init(
                pointers: [],
                failures: [
                    .init(
                        location: location,
                        reason: .unsupportedFormat(
                            value: UInt64(startsInSegment.info.layout.pointer_format)
                        )
                    )
                ]
            )
        }
        guard pointerFormat.is64Bit == machO.is64Bit else {
            return .init(
                pointers: [],
                failures: [
                    .init(
                        location: location,
                        reason: .invalidValue(
                            field: "pointer_format bitness",
                            value: UInt64(pointerFormat.rawValue)
                        )
                    )
                ]
            )
        }
        guard let segment = fileSegment(at: segmentIndex, in: machO) else {
            return .init(
                pointers: [],
                failures: [
                    .init(
                        location: location,
                        reason: .invalidIndex(
                            index: segmentIndex,
                            count: machOSegmentCount(in: machO)
                        )
                    )
                ]
            )
        }
        guard startsInSegment.info.layout.segment_offset == segment.virtualMemoryOffset else {
            return .init(
                pointers: [],
                failures: [
                    .init(
                        location: location,
                        reason: .invalidValue(
                            field: "segment_offset",
                            value: startsInSegment.info.layout.segment_offset
                        )
                    )
                ]
            )
        }

        let pageSize = UInt64(startsInSegment.info.layout.page_size)
        guard [UInt64(0x1000), UInt64(0x4000)].contains(pageSize) else {
            return .init(
                pointers: [],
                failures: [
                    .init(
                        location: location,
                        reason: .invalidValue(field: "page_size", value: pageSize)
                    )
                ]
            )
        }

        var report = DyldChainedFixupPointerReport(pointers: [], failures: [])
        for (pageIndex, pageStart) in startsInSegment.pageStarts.enumerated() {
            if pageStart == UInt16(DYLD_CHAINED_PTR_START_NONE) {
                continue
            }
            switch chainStarts(
                for: pageStart,
                pageIndex: pageIndex,
                pointerFormat: pointerFormat,
                machOIs64Bit: machO.is64Bit,
                pageSize: pageSize,
                segment: startsInSegment
            ) {
            case let .success(chainStarts):
                for chainStart in chainStarts {
                    let chainReport = walkChain(
                        from: UInt64(chainStart),
                        pageIndex: pageIndex,
                        pageSize: pageSize,
                        pointerFormat: pointerFormat,
                        segment: segment,
                        segmentIndex: segmentIndex,
                        machO: machO
                    )
                    report.pointers.append(contentsOf: chainReport.pointers)
                    report.failures.append(contentsOf: chainReport.failures)
                }
            case let .failure(error):
                report.failures.append(error)
            }
        }
        return report
    }

    private func chainStarts(
        for pageStart: UInt16,
        pageIndex: Int,
        pointerFormat: DyldChainedFixupPointerFormat,
        machOIs64Bit: Bool,
        pageSize: UInt64,
        segment: ParsedDyldChainedFixupsSegment
    ) -> Result<[UInt16], DyldChainedFixupsReadError> {
        guard pageStart & UInt16(DYLD_CHAINED_PTR_START_MULTI) != 0 else {
            return .success([pageStart])
        }

        let location = DyldChainedFixupsReadError.Location.multiStart(
            segment: segment.info.segmentIndex,
            page: pageIndex
        )
        guard !machOIs64Bit, !pointerFormat.is64Bit else {
            return .failure(
                .init(
                    location: location,
                    reason: .invalidValue(
                        field: "multiStartPointerFormat",
                        value: UInt64(pointerFormat.rawValue)
                    )
                )
            )
        }
        var index = Int(pageStart & ~UInt16(DYLD_CHAINED_PTR_START_MULTI))
        guard index >= segment.pageStarts.count,
              segment.allStartEntries.indices.contains(index) else {
            return .failure(
                .init(
                    location: location,
                    reason: .invalidIndex(
                        index: index,
                        count: segment.allStartEntries.count
                    )
                )
            )
        }

        var starts: [UInt16] = []
        var terminated = false
        while segment.allStartEntries.indices.contains(index) {
            let entry = segment.allStartEntries[index]
            starts.append(entry & ~UInt16(DYLD_CHAINED_PTR_START_LAST))
            if entry & UInt16(DYLD_CHAINED_PTR_START_LAST) != 0 {
                terminated = true
                break
            }
            let (nextIndex, overflow) = index.addingReportingOverflow(1)
            guard !overflow else {
                return .failure(.init(location: location, reason: .arithmeticOverflow))
            }
            index = nextIndex
        }
        guard terminated else {
            return .failure(.init(location: location, reason: .unterminatedTable))
        }
        let pointerWidth = UInt64(pointerFormat.is64Bit ? 8 : 4)
        var previous: UInt16?
        for start in starts {
            if let previous, start <= previous {
                return .failure(
                    .init(
                        location: location,
                        reason: .invalidValue(
                            field: "multiStartOrder",
                            value: UInt64(start)
                        )
                    )
                )
            }
            let startOffset = UInt64(start)
            guard startOffset <= pageSize,
                  pointerWidth <= pageSize - startOffset else {
                return .failure(
                    .init(
                        location: location,
                        reason: .invalidRange(
                            offset: startOffset,
                            byteCount: pointerWidth,
                            availableByteCount: Int(pageSize)
                        )
                    )
                )
            }
            previous = start
        }
        return .success(starts)
    }

    private func walkChain(
        from startOffsetInPage: UInt64,
        pageIndex: Int,
        pageSize: UInt64,
        pointerFormat: DyldChainedFixupPointerFormat,
        segment: DyldChainedFixupFileSegment,
        segmentIndex: Int,
        machO: MachOFile
    ) -> DyldChainedFixupPointerReport {
        let location = DyldChainedFixupsReadError.Location.chain(
            segment: segmentIndex,
            page: pageIndex
        )
        let fileView = DyldChainedFixupsByteView(
            bytes: .init(start: machO.fileHandle.ptr, count: machO.fileHandle.size)
        )
        guard let headerStartOffset = UInt64(exactly: machO.headerStartOffset),
              let pageIndex = UInt64(exactly: pageIndex) else {
            return .init(
                pointers: [],
                failures: [.init(location: location, reason: .arithmeticOverflow)]
            )
        }

        var pointers: [DyldChainedFixupPointer] = []
        do {
            let pageOffset = try fileView.checkedMultiply(
                pageIndex,
                pageSize,
                location: location
            )
            var offsetInPage = startOffsetInPage
            while true {
                let pointerWidth = UInt64(pointerFormat.is64Bit ? 8 : 4)
                guard offsetInPage <= pageSize,
                      pointerWidth <= pageSize - offsetInPage else {
                    throw DyldChainedFixupsReadError(
                        location: location,
                        reason: .invalidRange(
                            offset: offsetInPage,
                            byteCount: pointerWidth,
                            availableByteCount: Int(exactly: pageSize) ?? 0
                        )
                    )
                }
                let segmentRelativeOffset = try fileView.checkedAdd(
                    pageOffset,
                    offsetInPage,
                    location: location
                )
                guard segmentRelativeOffset <= segment.fileSize,
                      pointerWidth <= segment.fileSize - segmentRelativeOffset else {
                    throw DyldChainedFixupsReadError(
                        location: location,
                        reason: .invalidRange(
                            offset: segmentRelativeOffset,
                            byteCount: pointerWidth,
                            availableByteCount: Int(exactly: segment.fileSize) ?? 0
                        )
                    )
                }
                let pointerFileOffset = try fileView.checkedAdd(
                    segment.fileOffset,
                    segmentRelativeOffset,
                    location: location
                )
                let absoluteFileOffset = try fileView.checkedAdd(
                    headerStartOffset,
                    pointerFileOffset,
                    location: location
                )
                let fixupInfo: DyldChainedFixupPointerInfo?
                if pointerFormat.is64Bit {
                    let rawValue: UInt64 = try fileView.loadUnaligned(
                        at: absoluteFileOffset,
                        location: location
                    )
                    fixupInfo = _fixupInfo(rawValue: rawValue, pointerFormat: pointerFormat)
                } else {
                    let rawValue: UInt32 = try fileView.loadUnaligned(
                        at: absoluteFileOffset,
                        location: location
                    )
                    fixupInfo = _fixupInfo(rawValue: rawValue, pointerFormat: pointerFormat)
                }
                guard let fixupInfo else {
                    throw DyldChainedFixupsReadError(
                        location: location,
                        reason: .unsupportedFormat(value: UInt64(pointerFormat.rawValue))
                    )
                }
                guard let pointerOffset = Int(exactly: pointerFileOffset) else {
                    throw DyldChainedFixupsReadError(
                        location: location,
                        reason: .arithmeticOverflow
                    )
                }
                pointers.append(
                    .init(offset: pointerOffset, fixupInfo: fixupInfo)
                )
                guard fixupInfo.next != 0 else {
                    return .init(pointers: pointers, failures: [])
                }
                let delta = try fileView.checkedMultiply(
                    UInt64(pointerFormat.stride),
                    UInt64(fixupInfo.next),
                    location: location
                )
                offsetInPage = try fileView.checkedAdd(
                    offsetInPage,
                    delta,
                    location: location
                )
            }
        } catch let error as DyldChainedFixupsReadError {
            return .init(pointers: pointers, failures: [error])
        } catch {
            return .init(
                pointers: pointers,
                failures: [.init(location: location, reason: .arithmeticOverflow)]
            )
        }
    }

    private func fileSegment(
        at index: Int,
        in machO: MachOFile
    ) -> DyldChainedFixupFileSegment? {
        if machO.is64Bit {
            let segments = Array(machO.segments64)
            guard segments.indices.contains(index),
                  let preferredLoadAddress = machO.loadCommands.text64?.layout.vmaddr else {
                return nil
            }
            let segment = segments[index].layout
            guard segment.vmaddr >= preferredLoadAddress else { return nil }
            return .init(
                fileOffset: segment.fileoff,
                fileSize: segment.filesize,
                virtualMemoryOffset: segment.vmaddr - preferredLoadAddress
            )
        }

        let segments = Array(machO.segments32)
        guard segments.indices.contains(index),
              let preferredLoadAddress = machO.loadCommands.text?.layout.vmaddr else {
            return nil
        }
        let segment = segments[index].layout
        guard segment.vmaddr >= preferredLoadAddress else { return nil }
        return .init(
            fileOffset: UInt64(segment.fileoff),
            fileSize: UInt64(segment.filesize),
            virtualMemoryOffset: UInt64(segment.vmaddr - preferredLoadAddress)
        )
    }

    private func validateSegmentCount(in machO: MachOFile) throws {
        let starts = try parser.startsInImage()
        guard let fixupSegmentCount = Int(exactly: starts.layout.seg_count) else {
            throw invalidSegmentCount(starts.layout.seg_count)
        }
        if machO.is64Bit {
            let segments = Array(machO.segments64)
            guard let linkeditIndex = segments.firstIndex(
                where: { $0.segmentName == "__LINKEDIT" }
            ) else {
                throw invalidSegmentCount(starts.layout.seg_count)
            }
            try validateSegmentCount(
                fixupSegmentCount,
                linkeditIndex: linkeditIndex,
                virtualMemorySizes: segments.map(\.layout.vmsize),
                encodedValue: starts.layout.seg_count
            )
        } else {
            let segments = Array(machO.segments32)
            guard let linkeditIndex = segments.firstIndex(
                where: { $0.segmentName == "__LINKEDIT" }
            ) else {
                throw invalidSegmentCount(starts.layout.seg_count)
            }
            try validateSegmentCount(
                fixupSegmentCount,
                linkeditIndex: linkeditIndex,
                virtualMemorySizes: segments.map { UInt64($0.layout.vmsize) },
                encodedValue: starts.layout.seg_count
            )
        }
    }

    private func validateSegmentCount(
        _ fixupSegmentCount: Int,
        linkeditIndex: Int,
        virtualMemorySizes: [UInt64],
        encodedValue: UInt32
    ) throws {
        let expectedSegmentCount = linkeditIndex + 1
        guard fixupSegmentCount <= expectedSegmentCount else {
            throw invalidSegmentCount(encodedValue)
        }
        let extraSegmentCount = expectedSegmentCount - fixupSegmentCount
        for extraIndex in 0 ..< extraSegmentCount {
            let segmentIndex = linkeditIndex - (extraIndex + 1)
            guard virtualMemorySizes.indices.contains(segmentIndex),
                  virtualMemorySizes[segmentIndex] == 0 else {
                throw invalidSegmentCount(encodedValue)
            }
        }
    }

    private func invalidSegmentCount(
        _ encodedValue: UInt32
    ) -> DyldChainedFixupsReadError {
        .init(
            location: .segmentOffsets,
            reason: .invalidValue(
                field: "seg_count",
                value: UInt64(encodedValue)
            )
        )
    }

    private func machOSegmentCount(in machO: MachOFile) -> Int {
        machO.is64Bit
            ? Array(machO.segments64).count
            : Array(machO.segments32).count
    }

    private func _fixupInfo(
        rawValue: UInt64,
        pointerFormat: DyldChainedFixupPointerFormat
    ) -> DyldChainedFixupPointerInfo? {
        .init(rawValue: rawValue, pointerFormat: pointerFormat)
    }

    private func _fixupInfo(
        rawValue: UInt32,
        pointerFormat: DyldChainedFixupPointerFormat
    ) -> DyldChainedFixupPointerInfo? {
        .init(rawValue: rawValue, pointerFormat: pointerFormat)
    }
}
