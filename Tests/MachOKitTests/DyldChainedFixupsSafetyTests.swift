import Foundation
import XCTest
@_spi(Support) @testable import MachOKit

final class DyldChainedFixupsSafetyTests: XCTestCase {
    func testSparseSegmentOffsetsSkipAbsentEntriesAndPreserveIndex() throws {
        let blob = makeFixupsBlob(
            segmentOffsets: [0, 0x10, 0],
            segmentRelativeOffset: 0x10,
            entries: [0]
        )

        try withParser(for: blob) { parser in
            let report = parser.segments()
            XCTAssertTrue(report.failures.isEmpty)
            XCTAssertEqual(report.value.count, 1)
            XCTAssertEqual(report.value[0].info.segmentIndex, 1)
            XCTAssertEqual(report.value[0].pageStarts, [0])
        }
    }

    func testFileAndImageUseTheSameSparseTableProjection() throws {
        let blob = makeFixupsBlob(
            segmentOffsets: [0, 0x10, 0],
            segmentRelativeOffset: 0x10,
            entries: [0]
        )
        let machOData = makeMachO(fixupsBlob: blob)

        try withMachOFile(data: machOData) { machO in
            let fixups = try XCTUnwrap(machO.dyldChainedFixups)
            let starts = try XCTUnwrap(fixups.startsInImage)
            XCTAssertTrue(fixups.startsInSegments(of: nil).isEmpty)
            let segments = fixups.startsInSegments(of: starts)
            XCTAssertEqual(segments.map(\.segmentIndex), [1])
            XCTAssertEqual(fixups.pages(of: segments[0]).map(\.offset), [0])
        }

        blob.withUnsafeBytes { bytes in
            let fixups = MachOImage.DyldChainedFixups(
                basePointer: bytes.baseAddress!.assumingMemoryBound(to: UInt8.self),
                dyldChainedFixupsSize: bytes.count
            )
            let starts = fixups.startsInImage
            XCTAssertTrue(fixups.startsInSegments(of: nil).isEmpty)
            let segments = fixups.startsInSegments(of: starts)
            XCTAssertEqual(segments.map(\.segmentIndex), [1])
            XCTAssertEqual(fixups.pages(of: segments[0]).map(\.offset), [0])
        }
    }

    func testTruncatedSegmentOffsetTableIsBounded() throws {
        let blob = Data(
            makeFixupsBlob(
                segmentOffsets: [0, 0x10, 0],
                segmentRelativeOffset: 0x10,
                entries: [0]
            ).prefix(0x28)
        )

        try withParser(for: blob) { parser in
            let report = parser.segments()
            XCTAssertTrue(report.value.isEmpty)
            XCTAssertEqual(report.failures.first?.location, .segmentOffsets)
        }
    }

    func testTruncatedPagePrefixIsBounded() throws {
        let blob = makeFixupsBlob(
            segmentOffsets: [0, 0x0C],
            segmentRelativeOffset: 0x0C,
            declaredSize: 24,
            pageCount: 2,
            entries: [0]
        )

        try withParser(for: blob) { parser in
            let report = parser.segments()
            XCTAssertTrue(report.value.isEmpty)
            XCTAssertEqual(report.failures.first?.location, .pageStarts(segment: 1))
        }
    }

    func testTruncatedImportsAreAllOrNothing() throws {
        var blob = makeFixupsBlob(
            segmentOffsets: [0, 0x0C],
            segmentRelativeOffset: 0x0C,
            entries: [0]
        )
        let importsOffset = blob.count
        blob.append(Data(count: 4))
        blob.write(UInt32(2), at: 0x10)
        blob.write(UInt32(importsOffset + 4), at: 0x0C)

        try withParser(for: blob) { parser in
            XCTAssertThrowsError(try parser.imports())
        }
        blob.withUnsafeBytes { bytes in
            let fixups = MachOImage.DyldChainedFixups(
                basePointer: bytes.baseAddress!.assumingMemoryBound(to: UInt8.self),
                dyldChainedFixupsSize: bytes.count
            )
            XCTAssertTrue(fixups.imports.isEmpty)
        }
    }

    func testSymbolNameRequiresTerminatorInsideFixupsBlob() throws {
        var blob = makeFixupsBlob(
            segmentOffsets: [0, 0x0C],
            segmentRelativeOffset: 0x0C,
            entries: [0]
        )
        let importsOffset = blob.count
        blob.append(Data(count: 4))
        let symbolsOffset = blob.count
        blob.append(contentsOf: [0x61, 0x62, 0x63])
        blob.write(UInt32(importsOffset), at: 0x08)
        blob.write(UInt32(symbolsOffset), at: 0x0C)
        blob.write(UInt32(1), at: 0x10)

        try withParser(for: blob) { parser in
            XCTAssertEqual(try parser.imports().count, 1)
            XCTAssertThrowsError(try parser.symbolName(for: 0))
        }
    }

    func testValidMultiStartUsesTrailingFlexibleEntries() throws {
        let blob = makeFixupsBlob(
            segmentOffsets: [0, 0x0C],
            segmentRelativeOffset: 0x0C,
            pointerFormat: UInt16(DYLD_CHAINED_PTR_32),
            entries: [0x8001, 0x0004, 0x8008]
        )
        var machOData = makeMachO(fixupsBlob: blob)
        machOData.write(UInt32(0), at: 0x1004)
        machOData.write(UInt32(0), at: 0x1008)

        try withMachOFile(data: machOData) { machO in
            let fixups = try XCTUnwrap(machO.dyldChainedFixups)
            try machO.validateChainedFixups()
            let starts = try XCTUnwrap(fixups.startsInImage)
            let segment = try XCTUnwrap(fixups.startsInSegments(of: starts).first)
            XCTAssertEqual(fixups.pointers(of: segment, in: machO).map(\.offset), [0x1004, 0x1008])
        }
    }

    func testMultiStartIndexOutsideFlexibleEntriesFailsNormally() throws {
        let blob = makeFixupsBlob(
            segmentOffsets: [0, 0x0C],
            segmentRelativeOffset: 0x0C,
            pointerFormat: UInt16(DYLD_CHAINED_PTR_32),
            entries: [0x8003, 0x0004, 0x8008]
        )

        try withMachOFile(data: makeMachO(fixupsBlob: blob)) { machO in
            let fixups = try XCTUnwrap(machO.dyldChainedFixups)
            let report = fixups.pointerReport(in: machO)
            XCTAssertTrue(report.pointers.isEmpty)
            XCTAssertEqual(report.failures.first?.location, .multiStart(segment: 1, page: 0))
            XCTAssertThrowsError(try machO.validateChainedFixups())
        }
    }

    func testMultiStartWithoutLastEntryFailsNormally() throws {
        let blob = makeFixupsBlob(
            segmentOffsets: [0, 0x0C],
            segmentRelativeOffset: 0x0C,
            pointerFormat: UInt16(DYLD_CHAINED_PTR_32),
            entries: [0x8001, 0x0004, 0x0008]
        )

        try withMachOFile(data: makeMachO(fixupsBlob: blob)) { machO in
            let fixups = try XCTUnwrap(machO.dyldChainedFixups)
            let report = fixups.pointerReport(in: machO)
            XCTAssertTrue(report.pointers.isEmpty)
            XCTAssertEqual(
                report.failures.first,
                .init(location: .multiStart(segment: 1, page: 0), reason: .unterminatedTable)
            )
        }
    }

    func testMultiStartIsRejectedFor64BitPointerFormat() throws {
        let blob = makeFixupsBlob(
            segmentOffsets: [0, 0x0C],
            segmentRelativeOffset: 0x0C,
            entries: [0x8001, 0x0004, 0x8008]
        )

        try withMachOFile(data: makeMachO(fixupsBlob: blob)) { machO in
            let fixups = try XCTUnwrap(machO.dyldChainedFixups)
            let report = fixups.pointerReport(in: machO)
            XCTAssertTrue(report.pointers.isEmpty)
            XCTAssertEqual(report.failures.first?.location, .multiStart(segment: 1, page: 0))
        }
    }

    func testSegmentFileRangeOwnsFileBackedPointerCoordinate() throws {
        let blob = makeFixupsBlob(
            segmentOffsets: [0, 0x10, 0],
            segmentRelativeOffset: 0x10,
            segmentOffset: 0x4000,
            entries: [0]
        )
        let machOData = makeMachO(
            fixupsBlob: blob,
            dataSegmentFileOffset: 0x1000,
            dataSegmentVMOffset: 0x4000
        )

        try withMachOFile(data: machOData) { machO in
            let fixups = try XCTUnwrap(machO.dyldChainedFixups)
            try machO.validateChainedFixups()
            let pointer = try XCTUnwrap(fixups.pointer(for: 0x1000, in: machO))
            XCTAssertEqual(pointer.offset, 0x1000)
            XCTAssertNil(fixups.pointer(for: 0x4000, in: machO))
            XCTAssertEqual(machO.resolveRebase(at: 0x1000), 0)
            XCTAssertNil(machO.resolveRebase(at: 0x4000))
        }
    }

    func testPointerWidthCannotCrossSegmentEnd() throws {
        let blob = makeFixupsBlob(
            segmentOffsets: [0, 0x0C],
            segmentRelativeOffset: 0x0C,
            entries: [0x0FFC]
        )

        try withMachOFile(data: makeMachO(fixupsBlob: blob)) { machO in
            let fixups = try XCTUnwrap(machO.dyldChainedFixups)
            let report = fixups.pointerReport(in: machO)
            XCTAssertTrue(report.pointers.isEmpty)
            XCTAssertEqual(report.failures.first?.location, .chain(segment: 1, page: 0))
        }
    }

    func testChainCannotContinueIntoTheNextPage() throws {
        let blob = makeFixupsBlob(
            segmentOffsets: [0, 0x0C],
            segmentRelativeOffset: 0x0C,
            entries: [0x0FF8]
        )
        var machOData = makeMachO(fixupsBlob: blob)
        machOData.write(UInt64(2) << 51, at: 0x1FF8)

        try withMachOFile(data: machOData) { machO in
            let fixups = try XCTUnwrap(machO.dyldChainedFixups)
            let report = fixups.pointerReport(in: machO)
            XCTAssertEqual(report.pointers.map(\.offset), [0x1FF8])
            XCTAssertEqual(report.failures.first?.location, .chain(segment: 1, page: 0))
        }
    }

    func testSegmentFileSliceOutOfRangeFailsWithoutTrap() throws {
        let blob = makeFixupsBlob(
            segmentOffsets: [0, 0x0C],
            segmentRelativeOffset: 0x0C,
            entries: [0]
        )
        let machOData = makeMachO(
            fixupsBlob: blob,
            dataSegmentFileSize: 4
        )

        try withMachOFile(data: machOData) { machO in
            let fixups = try XCTUnwrap(machO.dyldChainedFixups)
            XCTAssertTrue(fixups.pointerReport(in: machO).pointers.isEmpty)
            XCTAssertThrowsError(try machO.validateChainedFixups())
        }
    }
}

private extension DyldChainedFixupsSafetyTests {
    func withParser(
        for data: Data,
        _ body: (DyldChainedFixupsParser) throws -> Void
    ) throws {
        try data.withUnsafeBytes { bytes in
            try body(
                .init(
                    view: .init(bytes: bytes),
                    isSwapped: false
                )
            )
        }
    }

    func withMachOFile(
        data: Data,
        _ body: (MachOFile) throws -> Void
    ) throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("MachOKit-ChainedFixups-\(UUID().uuidString)")
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        try body(MachOFile(url: url))
    }

    func makeFixupsBlob(
        segmentOffsets: [UInt32],
        segmentRelativeOffset: UInt32,
        declaredSize: UInt32? = nil,
        pageSize: UInt16 = 0x1000,
        pointerFormat: UInt16 = UInt16(DYLD_CHAINED_PTR_64_OFFSET),
        segmentOffset: UInt64 = 0x4000,
        pageCount: UInt16 = 1,
        entries: [UInt16]
    ) -> Data {
        let startsOffset = 0x20
        let recordOffset = startsOffset + Int(segmentRelativeOffset)
        let recordSize = Int(declaredSize ?? UInt32(22 + entries.count * 2))
        let importsOffset = recordOffset + recordSize
        var data = Data(count: importsOffset)

        data.write(UInt32(0), at: 0x00)
        data.write(UInt32(startsOffset), at: 0x04)
        data.write(UInt32(importsOffset), at: 0x08)
        data.write(UInt32(importsOffset), at: 0x0C)
        data.write(UInt32(0), at: 0x10)
        data.write(UInt32(DYLD_CHAINED_IMPORT), at: 0x14)
        data.write(UInt32(0), at: 0x18)

        data.write(UInt32(segmentOffsets.count), at: startsOffset)
        for (index, offset) in segmentOffsets.enumerated() {
            data.write(offset, at: startsOffset + 4 + index * 4)
        }

        data.write(UInt32(recordSize), at: recordOffset)
        data.write(pageSize, at: recordOffset + 4)
        data.write(pointerFormat, at: recordOffset + 6)
        data.write(segmentOffset, at: recordOffset + 8)
        data.write(UInt32(0), at: recordOffset + 16)
        data.write(pageCount, at: recordOffset + 20)
        for (index, entry) in entries.enumerated() {
            let offset = recordOffset + 22 + index * 2
            guard offset + 2 <= data.count else { break }
            data.write(entry, at: offset)
        }
        return data
    }

    func makeMachO(
        fixupsBlob: Data,
        dataSegmentFileOffset: UInt64 = 0x1000,
        dataSegmentFileSize: UInt64 = 0x1000,
        dataSegmentVMOffset: UInt64 = 0x4000
    ) -> Data {
        let preferredLoadAddress: UInt64 = 0x1_0000_0000
        let linkeditFileOffset: UInt64 = 0x2000
        let fileSize = 0x3000
        var data = Data(count: fileSize)

        data.write(UInt32(MH_MAGIC_64), at: 0)
        data.write(UInt32(bitPattern: CPU_TYPE_ARM64), at: 4)
        data.write(UInt32(0), at: 8)
        data.write(UInt32(MH_DYLIB), at: 12)
        data.write(UInt32(4), at: 16)
        data.write(UInt32(72 * 3 + 16), at: 20)
        data.write(UInt32(0), at: 24)
        data.write(UInt32(0), at: 28)

        writeSegment64(
            name: "__TEXT",
            vmAddress: preferredLoadAddress,
            vmSize: 0x1000,
            fileOffset: 0,
            fileSize: 0x1000,
            at: 32,
            in: &data
        )
        writeSegment64(
            name: "__DATA",
            vmAddress: preferredLoadAddress + dataSegmentVMOffset,
            vmSize: 0x1000,
            fileOffset: dataSegmentFileOffset,
            fileSize: dataSegmentFileSize,
            at: 32 + 72,
            in: &data
        )
        writeSegment64(
            name: "__LINKEDIT",
            vmAddress: preferredLoadAddress + 0x8000,
            vmSize: 0x1000,
            fileOffset: linkeditFileOffset,
            fileSize: 0x1000,
            at: 32 + 72 * 2,
            in: &data
        )

        let fixupsCommandOffset = 32 + 72 * 3
        data.write(UInt32(LC_DYLD_CHAINED_FIXUPS), at: fixupsCommandOffset)
        data.write(UInt32(16), at: fixupsCommandOffset + 4)
        data.write(UInt32(linkeditFileOffset), at: fixupsCommandOffset + 8)
        data.write(UInt32(fixupsBlob.count), at: fixupsCommandOffset + 12)
        data.replaceSubrange(
            Int(linkeditFileOffset) ..< Int(linkeditFileOffset) + fixupsBlob.count,
            with: fixupsBlob
        )
        return data
    }

    func writeSegment64(
        name: String,
        vmAddress: UInt64,
        vmSize: UInt64,
        fileOffset: UInt64,
        fileSize: UInt64,
        at offset: Int,
        in data: inout Data
    ) {
        data.write(UInt32(LC_SEGMENT_64), at: offset)
        data.write(UInt32(72), at: offset + 4)
        let nameBytes = Array(name.utf8.prefix(16))
        data.replaceSubrange(offset + 8 ..< offset + 8 + nameBytes.count, with: nameBytes)
        data.write(vmAddress, at: offset + 24)
        data.write(vmSize, at: offset + 32)
        data.write(fileOffset, at: offset + 40)
        data.write(fileSize, at: offset + 48)
        data.write(UInt32(bitPattern: VM_PROT_READ | VM_PROT_WRITE), at: offset + 56)
        data.write(UInt32(bitPattern: VM_PROT_READ | VM_PROT_WRITE), at: offset + 60)
        data.write(UInt32(0), at: offset + 64)
        data.write(UInt32(0), at: offset + 68)
    }
}

private extension Data {
    mutating func write<T: FixedWidthInteger>(_ value: T, at offset: Int) {
        var value = value.littleEndian
        Swift.withUnsafeBytes(of: &value) { bytes in
            replaceSubrange(offset ..< offset + bytes.count, with: bytes)
        }
    }
}
