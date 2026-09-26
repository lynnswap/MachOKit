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
        var blob = Data(
            makeFixupsBlob(
                segmentOffsets: [0, 0x10, 0],
                segmentRelativeOffset: 0x10,
                entries: [0]
            ).prefix(0x28)
        )
        blob.write(UInt32(0x28), at: 0x08)
        blob.write(UInt32(0x28), at: 0x0C)

        try withParser(for: blob) { parser in
            let report = parser.segments()
            XCTAssertTrue(report.value.isEmpty)
            XCTAssertEqual(report.failures.first?.location, .segmentOffsets)
        }
    }

    func testTruncatedPagePrefixIsBounded() throws {
        let blob = makeFixupsBlob(
            segmentOffsets: [0, 0x10, 0],
            segmentRelativeOffset: 0x10,
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
            segmentOffsets: [0, 0x10, 0],
            segmentRelativeOffset: 0x10,
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
            segmentOffsets: [0, 0x10, 0],
            segmentRelativeOffset: 0x10,
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
            segmentOffsets: [0, 0x10, 0],
            segmentRelativeOffset: 0x10,
            pointerFormat: UInt16(DYLD_CHAINED_PTR_32),
            entries: [0x8001, 0x0004, 0x8008]
        )
        var machOData = makeMachO32(fixupsBlob: blob)
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
            segmentOffsets: [0, 0x10, 0],
            segmentRelativeOffset: 0x10,
            pointerFormat: UInt16(DYLD_CHAINED_PTR_32),
            entries: [0x8003, 0x0004, 0x8008]
        )

        try withMachOFile(data: makeMachO32(fixupsBlob: blob)) { machO in
            let fixups = try XCTUnwrap(machO.dyldChainedFixups)
            let report = fixups.pointerReport(in: machO)
            XCTAssertTrue(report.pointers.isEmpty)
            XCTAssertEqual(report.failures.first?.location, .multiStart(segment: 1, page: 0))
            XCTAssertThrowsError(try machO.validateChainedFixups())
        }
    }

    func testMultiStartWithoutLastEntryFailsNormally() throws {
        let blob = makeFixupsBlob(
            segmentOffsets: [0, 0x10, 0],
            segmentRelativeOffset: 0x10,
            pointerFormat: UInt16(DYLD_CHAINED_PTR_32),
            entries: [0x8001, 0x0004, 0x0008]
        )

        try withMachOFile(data: makeMachO32(fixupsBlob: blob)) { machO in
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
            segmentOffsets: [0, 0x10, 0],
            segmentRelativeOffset: 0x10,
            entries: [0x8001, 0x0004, 0x8008]
        )

        try withMachOFile(data: makeMachO(fixupsBlob: blob)) { machO in
            let fixups = try XCTUnwrap(machO.dyldChainedFixups)
            let report = fixups.pointerReport(in: machO)
            XCTAssertTrue(report.pointers.isEmpty)
            XCTAssertEqual(report.failures.first?.location, .multiStart(segment: 1, page: 0))
        }
    }

    func testMultiStartsMustBeStrictlyAscending() throws {
        for entries: [UInt16] in [
            [0x8001, 0x0008, 0x8004],
            [0x8001, 0x0004, 0x8004],
        ] {
            let blob = makeFixupsBlob(
            segmentOffsets: [0, 0x10, 0],
            segmentRelativeOffset: 0x10,
                pointerFormat: UInt16(DYLD_CHAINED_PTR_32),
                entries: entries
            )
            try withMachOFile(data: makeMachO32(fixupsBlob: blob)) { machO in
                let fixups = try XCTUnwrap(machO.dyldChainedFixups)
                let failure = try XCTUnwrap(fixups.pointerReport(in: machO).failures.first)
                XCTAssertEqual(failure.location, .multiStart(segment: 1, page: 0))
                guard case let .invalidValue(field, _) = failure.reason else {
                    return XCTFail("Expected invalid multi-start ordering")
                }
                XCTAssertEqual(field, "multiStartOrder")
            }
        }
    }

    func testMultiStartsValidateEveryPointerWidthBeforeWalking() throws {
        let blob = makeFixupsBlob(
            segmentOffsets: [0, 0x10, 0],
            segmentRelativeOffset: 0x10,
            pointerFormat: UInt16(DYLD_CHAINED_PTR_32),
            entries: [0x8001, 0x0004, 0x8FFF]
        )

        try withMachOFile(data: makeMachO32(fixupsBlob: blob)) { machO in
            let fixups = try XCTUnwrap(machO.dyldChainedFixups)
            let report = fixups.pointerReport(in: machO)
            XCTAssertTrue(report.pointers.isEmpty)
            XCTAssertEqual(report.failures.first?.location, .multiStart(segment: 1, page: 0))
        }
    }

    func testPointerFormatBitnessMustMatchMachO() throws {
        let blob = makeFixupsBlob(
            segmentOffsets: [0, 0x10, 0],
            segmentRelativeOffset: 0x10,
            pointerFormat: UInt16(DYLD_CHAINED_PTR_32),
            entries: [0]
        )

        try withMachOFile(data: makeMachO(fixupsBlob: blob)) { machO in
            let fixups = try XCTUnwrap(machO.dyldChainedFixups)
            let failure = try XCTUnwrap(fixups.pointerReport(in: machO).failures.first)
            XCTAssertEqual(failure.location, .segment(index: 1))
            XCTAssertThrowsError(try machO.validateChainedFixups())
        }
    }

    func testAllChainedFixupSegmentsMustSharePointerFormat() throws {
        let format = UInt16(DYLD_CHAINED_PTR_64_OFFSET)
        let sameFormat = makeTwoSegmentFixupsBlob(
            secondPointerFormat: format
        )
        try withMachOFile(data: makeMachO(fixupsBlob: sameFormat)) { machO in
            try machO.validateChainedFixups()
            let fixups = try XCTUnwrap(machO.dyldChainedFixups)
            XCTAssertEqual(
                fixups.pointerReport(in: machO).pointers.map(\.offset),
                [0x1000, 0x2100]
            )
        }

        let mixedFormat = makeTwoSegmentFixupsBlob(
            secondPointerFormat: UInt16(DYLD_CHAINED_PTR_64)
        )
        try withMachOFile(data: makeMachO(fixupsBlob: mixedFormat)) { machO in
            let fixups = try XCTUnwrap(machO.dyldChainedFixups)
            let report = fixups.pointerReport(in: machO)
            XCTAssertTrue(report.pointers.isEmpty)
            let failure = try XCTUnwrap(report.failures.first)
            XCTAssertEqual(failure.location, .segment(index: 2))
            guard case let .invalidValue(field, _) = failure.reason else {
                return XCTFail("Expected mixed pointer-format failure")
            }
            XCTAssertEqual(field, "pointer_format consistency")
            XCTAssertThrowsError(try machO.validateChainedFixups())
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
            XCTAssertEqual(machO.chainedFixupPointer(at: 0x1000)?.offset, 0x1000)
            XCTAssertNil(machO.chainedFixupPointer(at: 0x4000))
            XCTAssertNil(machO.chainedFixupPointer(at: .max))
            machO.invalidateChainedFixupsCache()
            XCTAssertEqual(machO.chainedFixupPointer(at: 0x1000)?.offset, 0x1000)
        }
    }

    func testPointerWidthCannotCrossSegmentEnd() throws {
        let blob = makeFixupsBlob(
            segmentOffsets: [0, 0x10, 0],
            segmentRelativeOffset: 0x10,
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
            segmentOffsets: [0, 0x10, 0],
            segmentRelativeOffset: 0x10,
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
            segmentOffsets: [0, 0x10, 0],
            segmentRelativeOffset: 0x10,
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

    func testAbsentAndUnreadableChainedFixupPayloadsRemainDistinct() throws {
        var absentData = makeMachO(
            fixupsBlob: makeFixupsBlob(
                segmentOffsets: [0, 0x10, 0],
                segmentRelativeOffset: 0x10,
                entries: [0]
            )
        )
        absentData.write(UInt32(3), at: 16)
        absentData.write(UInt32(72 * 3), at: 20)
        try withMachOFile(data: absentData) { machO in
            XCTAssertNil(machO.dyldChainedFixups)
            XCTAssertNoThrow(try machO.validateChainedFixups())
        }

        let readableData = makeMachO(
            fixupsBlob: makeFixupsBlob(
                segmentOffsets: [0, 0x10, 0],
                segmentRelativeOffset: 0x10,
                entries: [0]
            )
        )
        let mutations: [(inout Data) -> Void] = [
            { $0.write(UInt32(0x4000), at: 32 + 72 * 3 + 8) },
            { $0.write(UInt32(0), at: 32 + 72 * 3 + 12) },
        ]
        for mutate in mutations {
            var unreadableData = readableData
            mutate(&unreadableData)
            try withMachOFile(data: unreadableData) { machO in
                XCTAssertNil(machO.dyldChainedFixups)
                XCTAssertThrowsError(try machO.validateChainedFixups()) { error in
                    XCTAssertEqual((error as? DyldChainedFixupsReadError)?.location, .payload)
                }
            }
        }
    }

    func testPayloadBeforeLinkeditIsRejectedEvenWhenBytesAreValid() throws {
        let blob = makeFixupsBlob(
            segmentOffsets: [0, 0x10, 0],
            segmentRelativeOffset: 0x10,
            entries: [0]
        )
        var machOData = makeMachO(fixupsBlob: blob)
        let forgedDataOffset = 0x800
        machOData.replaceSubrange(
            forgedDataOffset ..< forgedDataOffset + blob.count,
            with: blob
        )
        machOData.write(UInt32(forgedDataOffset), at: 32 + 72 * 3 + 8)

        try withMachOFile(data: machOData) { machO in
            XCTAssertNil(machO.dyldChainedFixups)
            XCTAssertThrowsError(try machO.validateChainedFixups()) { error in
                XCTAssertEqual((error as? DyldChainedFixupsReadError)?.location, .payload)
            }
        }
    }

    func testValidatedHeaderRejectsInvalidTopLevelContracts() throws {
        let validBlob = makeFixupsBlob(
            segmentOffsets: [0, 0x10, 0],
            segmentRelativeOffset: 0x10,
            entries: [0]
        )
        let mutations: [(inout Data) -> Void] = [
            { $0.write(UInt32(1), at: 0x00) },
            {
                $0.write(UInt32(0), at: 0x08)
                $0.write(UInt32(1), at: 0x10)
            },
            { $0.write(UInt32(99), at: 0x14) },
            { $0.write(UInt32(1), at: 0x18) },
        ]

        for mutate in mutations {
            var blob = validBlob
            mutate(&blob)
            try withMachOFile(data: makeMachO(fixupsBlob: blob)) { machO in
                XCTAssertNotNil(machO.dyldChainedFixups?.header)
                XCTAssertThrowsError(try machO.validateChainedFixups()) { error in
                    XCTAssertEqual((error as? DyldChainedFixupsReadError)?.location, .header)
                }
            }
        }
    }

    func testUnsupportedSymbolCompressionDoesNotHideStructuralStarts() throws {
        var blob = makeFixupsBlob(
            segmentOffsets: [0, 0x10, 0],
            segmentRelativeOffset: 0x10,
            entries: [0]
        )
        blob.write(UInt32(1), at: 0x18)

        try withMachOFile(data: makeMachO(fixupsBlob: blob)) { machO in
            let fixups = try XCTUnwrap(machO.dyldChainedFixups)
            let starts = try XCTUnwrap(fixups.startsInImage)
            XCTAssertEqual(fixups.startsInSegments(of: starts).map(\.segmentIndex), [1])
            XCTAssertEqual(fixups.pointerReport(in: machO).pointers.map(\.offset), [0x1000])
            XCTAssertNil(fixups.symbolName(for: 0))
            XCTAssertThrowsError(try machO.validateChainedFixups())
        }

        var unknownImportsFormat = makeFixupsBlob(
            segmentOffsets: [0, 0x10, 0],
            segmentRelativeOffset: 0x10,
            entries: [0]
        )
        unknownImportsFormat.write(UInt32(99), at: 0x14)
        try withParser(for: unknownImportsFormat) { parser in
            XCTAssertNoThrow(try parser.startsInImage())
            XCTAssertThrowsError(try parser.imports())
        }
    }

    func testSegmentCountAndPageSizeMustMatchMachOContracts() throws {
        let wrongSegmentCount = makeFixupsBlob(
            segmentOffsets: [0, 0x14, 0, 0],
            segmentRelativeOffset: 0x14,
            entries: [0]
        )
        try withMachOFile(data: makeMachO(fixupsBlob: wrongSegmentCount)) { machO in
            XCTAssertThrowsError(try machO.validateChainedFixups())
        }

        let wrongPageSize = makeFixupsBlob(
            segmentOffsets: [0, 0x10, 0],
            segmentRelativeOffset: 0x10,
            pageSize: 0x2000,
            entries: [0]
        )
        try withMachOFile(data: makeMachO(fixupsBlob: wrongPageSize)) { machO in
            XCTAssertThrowsError(try machO.validateChainedFixups())
        }
    }

    func testFixupsMayOmitZeroSizedSegmentBeforeLinkedit() throws {
        let blob = makeFixupsBlob(
            segmentOffsets: [0, 0x10, 0],
            segmentRelativeOffset: 0x10,
            entries: [0]
        )
        var machOData = makeMachO(fixupsBlob: blob)
        insertSegmentBeforeLinkedit(
            virtualMemorySize: 0,
            fixupsBlobSize: blob.count,
            in: &machOData
        )

        try withMachOFile(data: machOData) { machO in
            try machO.validateChainedFixups()
            let fixups = try XCTUnwrap(machO.dyldChainedFixups)
            XCTAssertEqual(fixups.pointerReport(in: machO).pointers.map(\.offset), [0x1000])
        }
    }

    func testFixupsRejectOmittedNonemptySegmentBeforeLinkedit() throws {
        let blob = makeFixupsBlob(
            segmentOffsets: [0, 0x10, 0],
            segmentRelativeOffset: 0x10,
            entries: [0]
        )
        var machOData = makeMachO(fixupsBlob: blob)
        insertSegmentBeforeLinkedit(
            virtualMemorySize: 0x1000,
            fixupsBlobSize: blob.count,
            in: &machOData
        )

        try withMachOFile(data: machOData) { machO in
            XCTAssertThrowsError(try machO.validateChainedFixups())
        }
    }

    func testBindOrdinalMustExistInValidatedImports() throws {
        var blob = makeFixupsBlob(
            segmentOffsets: [0, 0x10, 0],
            segmentRelativeOffset: 0x10,
            entries: [0]
        )
        let importsOffset = blob.count
        blob.append(Data(count: 4))
        let symbolsOffset = blob.count
        blob.append(0)
        blob.write(UInt32(importsOffset), at: 0x08)
        blob.write(UInt32(symbolsOffset), at: 0x0C)
        blob.write(UInt32(1), at: 0x10)

        var machOData = makeMachO(fixupsBlob: blob)
        machOData.write(UInt64(0x8000_0000_0000_0001), at: 0x1000)
        try withMachOFile(data: machOData) { machO in
            XCTAssertNil(machO.resolveBind(at: 0x1000))
            XCTAssertEqual(machO.chainedFixupPointer(at: 0x1000)?.fixupInfo.bind?.ordinal, 1)
            XCTAssertThrowsError(try machO.validateChainedFixups()) { error in
                XCTAssertEqual((error as? DyldChainedFixupsReadError)?.location, .imports)
            }
        }
    }

    func testCachedRebaseExcludesChainLinkBits() throws {
        let blob = makeFixupsBlob(
            segmentOffsets: [0, 0x10, 0],
            segmentRelativeOffset: 0x10,
            entries: [0]
        )
        var data = makeMachO(fixupsBlob: blob, preferredLoadAddress: 0)
        data.write(UInt64(0x0020_0000_0007_6758), at: 0x1000)
        data.write(UInt8(1), at: 0x1008)
        data.write(UInt64(0x0000_0000_0007_6780), at: 0x1010)
        try withMachOFile(data: data) { machO in
            try machO.validateChainedFixups()
            XCTAssertEqual(machO.resolveRebase(at: 0x1000), 0x76758)
            XCTAssertEqual(machO.resolveOptionalRebase(at: 0x1000), 0x76758)
            XCTAssertEqual(machO.resolveOptionalRebase(at: 0x1010), 0x76780)
            machO.invalidateChainedFixupsCache()
            XCTAssertEqual(machO.resolveOptionalRebase(at: 0x1000), 0x76758)
        }
    }

    func testOptionalRebaseReadsOnlyThe32BitPointer() throws {
        let blob = makeFixupsBlob(
            segmentOffsets: [0, 0x10, 0],
            segmentRelativeOffset: 0x10,
            pointerFormat: UInt16(DYLD_CHAINED_PTR_32),
            entries: [0]
        )
        var data = makeMachO32(fixupsBlob: blob)
        // Keep the preferred load address inside the 26-bit target field.
        data.write(UInt32(0), at: 28 + 24)
        data.write(UInt32(0x4000), at: 28 + 56 + 24)
        data.write(UInt32(0x8000), at: 28 + 56 * 2 + 24)
        data.write(UInt32(0x1234), at: 0x1000)
        data.write(UInt8(1), at: 0x1004)
        try withMachOFile(data: data) { machO in
            try machO.validateChainedFixups()
            XCTAssertEqual(machO.resolveOptionalRebase(at: 0x1000), 0x1234)
        }
        data.write(UInt32(0), at: 0x1000)
        try withMachOFile(data: data) { machO in
            XCTAssertNil(machO.resolveOptionalRebase(at: 0x1000))
        }
    }

    func testLazyChainTraversesRebasesAndValidatesOnlyBindOrdinals() throws {
        let blob = makeFixupsBlob(
            segmentOffsets: [0, 0x10, 0],
            segmentRelativeOffset: 0x10,
            segmentOffset: 0x1000,
            entries: [0]
        )
        var data = makeMachO(fixupsBlob: blob, dataSegmentVMOffset: 0x1000)
        data.write(UInt64(2) << 51 | 0x1234, at: 0x1000)
        data.write(UInt64(1) << 63, at: 0x1008)
        data.write(UInt8(1), at: 0x1010)
        var layout = LazyLoadDylib.Layout()
        layout.pointerFormat = UInt16(DYLD_CHAINED_PTR_64_OFFSET)
        layout.chainStartImageOffset = 0x1000
        layout.flagImageOffset = 0x1100
        layout.symbolsCount = 1
        let lazy = LazyLoadDylib(layout: layout, dataOffset: 0x2000, dataSize: 28)
        for invalidOrdinal in [false, true] {
            if invalidOrdinal { data.write(UInt64(1) << 63 | 1, at: 0x1008) }
            try withMachOFile(data: data) { machO in
                let pointers = lazy.fixups(in: machO)
                if invalidOrdinal {
                    XCTAssertNil(pointers)
                } else {
                    XCTAssertEqual(pointers?.map(\.offset), [0x1000, 0x1008])
                    XCTAssertEqual(pointers?.last?.fixupInfo.bind?.ordinal, 0)
                }
            }
            data.withUnsafeBytes { bytes in
                let image = MachOImage(ptr: bytes.baseAddress!.assumingMemoryBound(to: mach_header.self))
                let pointers = lazy.fixups(in: image)
                if invalidOrdinal {
                    XCTAssertNil(pointers)
                } else {
                    XCTAssertEqual(pointers?.map(\.offset), [0x1000, 0x1008])
                    XCTAssertEqual(pointers?.last?.fixupInfo.bind?.ordinal, 0)
                }
            }
        }
    }

    func testSegmentRangesPreserveUnsignedKernelAddresses() {
        var layout = segment_command_64()
        layout.vmaddr = 0xfffffff007004000
        layout.vmsize = 0x4000
        layout.fileoff = 0x8000000000000000
        layout.filesize = 0x2000
        var segment = SegmentCommand64(layout, offset: 0)
        func check(_ segment: any SegmentCommandProtocol) {
            XCTAssertEqual(segment.virtualMemoryRange, 0xfffffff007004000..<0xfffffff007008000)
            XCTAssertEqual(segment.fileBackedVirtualMemoryRange, 0xfffffff007004000..<0xfffffff007006000)
            XCTAssertEqual(segment.fileRange, 0x8000000000000000..<0x8000000000002000)
            XCTAssertTrue(segment.contains(unslidAddress: 0xfffffff007007000))
        }
        check(segment)
        segment.layout.vmaddr = UInt64.max - 1
        segment.layout.fileoff = UInt64.max - 1
        XCTAssertNil(segment.virtualMemoryRange)
        XCTAssertNil(segment.fileBackedVirtualMemoryRange)
        XCTAssertNil(segment.fileRange)
    }

    func testGenericSymbolLookupRetainsDefaultArguments() throws {
        let blob = makeFixupsBlob(segmentOffsets: [0, 0x10, 0], segmentRelativeOffset: 0x10, entries: [0])
        var data = makeMachO(fixupsBlob: blob)
        data.write(UInt32(5), at: 16)
        data.write(UInt32(72 * 3 + 16 + 24), at: 20)
        let command = 32 + 72 * 3 + 16
        for (delta, value) in [(0, UInt32(LC_SYMTAB)), (4, 24), (8, 0x2100), (12, 2), (16, 0x2180), (20, 14)] {
            data.write(value, at: command + delta)
        }
        for (index, name, flags, value) in [(0, 1, N_SECT, UInt64(0x1_0000_0190)), (1, 7, N_SECT | N_EXT, UInt64(0x1_0000_0180))] {
            var symbol = nlist_64()
            symbol.n_un.n_strx = UInt32(name)
            symbol.n_type = UInt8(flags)
            symbol.n_sect = 1
            symbol.n_value = value
            data.write(symbol, at: 0x2100 + index * MemoryLayout<nlist_64>.size)
        }
        data.replaceSubrange(0x2180..<0x218e, with: Data("\0local\0global\0".utf8))
        func check<M: MachORepresentable>(_ machO: M) {
            XCTAssertEqual(machO.closestSymbol(at: 0x200)?.name, "local")
            XCTAssertEqual(machO.closestSymbol(at: 0x200, isGlobalOnly: true)?.name, "global")
            XCTAssertNil(machO.closestSymbol(at: 0x200, inSection: 2))
            XCTAssertEqual(machO.closestSymbols(at: 0x200).map(\.name), ["local"])
            XCTAssertEqual(machO.closestSymbols(at: 0x200, isGlobalOnly: true).map(\.name), ["global"])
            XCTAssertTrue(machO.closestSymbols(at: 0x200, inSection: 2).isEmpty)
        }
        try withMachOFile(data: data, check)
    }

    func testPointerIndexRejectsDuplicateFileOffsetsAtInsertionOwner() {
        let pointer = DyldChainedFixupPointer(
            offset: 0x1000,
            fixupInfo: ._64_offset(.init(rawValue: 0))
        )
        var index = DyldChainedFixupPointerIndex(
            pointersByFileOffset: [:],
            orderedPointers: [],
            failures: []
        )
        index.insert(pointer)
        index.insert(pointer)

        XCTAssertEqual(index.pointersByFileOffset.count, 1)
        XCTAssertEqual(index.orderedPointers.count, 1)
        XCTAssertEqual(index.failures.first?.location, .resolver)
    }

    func testFatSliceHeaderOffsetIsExcludedFromPointerCoordinate() throws {
        let blob = makeFixupsBlob(
            segmentOffsets: [0, 0x10, 0],
            segmentRelativeOffset: 0x10,
            entries: [0]
        )
        let prefixSize = 0x200
        var fatLikeData = Data(count: prefixSize)
        fatLikeData.append(makeMachO(fixupsBlob: blob))

        try withMachOFile(data: fatLikeData, headerStartOffset: prefixSize) { machO in
            try machO.validateChainedFixups()
            let fixups = try XCTUnwrap(machO.dyldChainedFixups)
            XCTAssertEqual(fixups.pointer(for: 0x1000, in: machO)?.offset, 0x1000)
            XCTAssertEqual(machO.resolveRebase(at: 0x1000), 0)
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
        headerStartOffset: Int = 0,
        _ body: (MachOFile) throws -> Void
    ) throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("MachOKit-ChainedFixups-\(UUID().uuidString)")
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        try body(MachOFile(url: url, headerStartOffset: headerStartOffset))
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

    func makeTwoSegmentFixupsBlob(
        secondPointerFormat: UInt16
    ) -> Data {
        let startsOffset = 0x20
        let importsOffset = 0x60
        var data = Data(count: importsOffset)

        data.write(UInt32(0), at: 0x00)
        data.write(UInt32(startsOffset), at: 0x04)
        data.write(UInt32(importsOffset), at: 0x08)
        data.write(UInt32(importsOffset), at: 0x0C)
        data.write(UInt32(0), at: 0x10)
        data.write(UInt32(DYLD_CHAINED_IMPORT), at: 0x14)
        data.write(UInt32(0), at: 0x18)

        data.write(UInt32(3), at: startsOffset)
        data.write(UInt32(0), at: startsOffset + 4)
        data.write(UInt32(0x10), at: startsOffset + 8)
        data.write(UInt32(0x28), at: startsOffset + 12)
        writeFixupsSegment(
            at: 0x30,
            pointerFormat: UInt16(DYLD_CHAINED_PTR_64_OFFSET),
            segmentOffset: 0x4000,
            pageStart: 0,
            in: &data
        )
        writeFixupsSegment(
            at: 0x48,
            pointerFormat: secondPointerFormat,
            segmentOffset: 0x8000,
            pageStart: 0x100,
            in: &data
        )
        return data
    }

    func writeFixupsSegment(
        at offset: Int,
        pointerFormat: UInt16,
        segmentOffset: UInt64,
        pageStart: UInt16,
        in data: inout Data
    ) {
        data.write(UInt32(24), at: offset)
        data.write(UInt16(0x1000), at: offset + 4)
        data.write(pointerFormat, at: offset + 6)
        data.write(segmentOffset, at: offset + 8)
        data.write(UInt32(0), at: offset + 16)
        data.write(UInt16(1), at: offset + 20)
        data.write(pageStart, at: offset + 22)
    }

    func makeMachO(
        fixupsBlob: Data,
        dataSegmentFileOffset: UInt64 = 0x1000,
        dataSegmentFileSize: UInt64 = 0x1000,
        dataSegmentVMOffset: UInt64 = 0x4000,
        preferredLoadAddress: UInt64 = 0x1_0000_0000
    ) -> Data {
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

    func makeMachO32(
        fixupsBlob: Data,
        dataSegmentFileOffset: UInt32 = 0x1000,
        dataSegmentFileSize: UInt32 = 0x1000,
        dataSegmentVMOffset: UInt32 = 0x4000
    ) -> Data {
        let preferredLoadAddress: UInt32 = 0x1000_0000
        let linkeditFileOffset: UInt32 = 0x2000
        var data = Data(count: 0x3000)

        data.write(UInt32(MH_MAGIC), at: 0)
        data.write(UInt32(bitPattern: CPU_TYPE_I386), at: 4)
        data.write(UInt32(0), at: 8)
        data.write(UInt32(MH_DYLIB), at: 12)
        data.write(UInt32(4), at: 16)
        data.write(UInt32(56 * 3 + 16), at: 20)
        data.write(UInt32(0), at: 24)

        writeSegment32(
            name: "__TEXT",
            vmAddress: preferredLoadAddress,
            vmSize: 0x1000,
            fileOffset: 0,
            fileSize: 0x1000,
            at: 28,
            in: &data
        )
        writeSegment32(
            name: "__DATA",
            vmAddress: preferredLoadAddress + dataSegmentVMOffset,
            vmSize: 0x1000,
            fileOffset: dataSegmentFileOffset,
            fileSize: dataSegmentFileSize,
            at: 28 + 56,
            in: &data
        )
        writeSegment32(
            name: "__LINKEDIT",
            vmAddress: preferredLoadAddress + 0x8000,
            vmSize: 0x1000,
            fileOffset: linkeditFileOffset,
            fileSize: 0x1000,
            at: 28 + 56 * 2,
            in: &data
        )

        let fixupsCommandOffset = 28 + 56 * 3
        data.write(UInt32(LC_DYLD_CHAINED_FIXUPS), at: fixupsCommandOffset)
        data.write(UInt32(16), at: fixupsCommandOffset + 4)
        data.write(linkeditFileOffset, at: fixupsCommandOffset + 8)
        data.write(UInt32(fixupsBlob.count), at: fixupsCommandOffset + 12)
        data.replaceSubrange(
            Int(linkeditFileOffset) ..< Int(linkeditFileOffset) + fixupsBlob.count,
            with: fixupsBlob
        )
        return data
    }

    func insertSegmentBeforeLinkedit(
        virtualMemorySize: UInt64,
        fixupsBlobSize: Int,
        in data: inout Data
    ) {
        data.write(UInt32(5), at: 16)
        data.write(UInt32(72 * 4 + 16), at: 20)
        writeSegment64(
            name: "__CTF",
            vmAddress: 0x1_0000_7000,
            vmSize: virtualMemorySize,
            fileOffset: 0,
            fileSize: 0,
            flags: UInt32(SG_NORELOC),
            at: 32 + 72 * 2,
            in: &data
        )
        writeSegment64(
            name: "__LINKEDIT",
            vmAddress: 0x1_0000_8000,
            vmSize: 0x1000,
            fileOffset: 0x2000,
            fileSize: 0x1000,
            at: 32 + 72 * 3,
            in: &data
        )
        let fixupsCommandOffset = 32 + 72 * 4
        data.write(UInt32(LC_DYLD_CHAINED_FIXUPS), at: fixupsCommandOffset)
        data.write(UInt32(16), at: fixupsCommandOffset + 4)
        data.write(UInt32(0x2000), at: fixupsCommandOffset + 8)
        data.write(UInt32(fixupsBlobSize), at: fixupsCommandOffset + 12)
    }

    func writeSegment64(
        name: String,
        vmAddress: UInt64,
        vmSize: UInt64,
        fileOffset: UInt64,
        fileSize: UInt64,
        flags: UInt32 = 0,
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
        data.write(flags, at: offset + 68)
    }

    func writeSegment32(
        name: String,
        vmAddress: UInt32,
        vmSize: UInt32,
        fileOffset: UInt32,
        fileSize: UInt32,
        at offset: Int,
        in data: inout Data
    ) {
        data.write(UInt32(LC_SEGMENT), at: offset)
        data.write(UInt32(56), at: offset + 4)
        let nameBytes = Array(name.utf8.prefix(16))
        data.replaceSubrange(offset + 8 ..< offset + 8 + nameBytes.count, with: nameBytes)
        data.write(vmAddress, at: offset + 24)
        data.write(vmSize, at: offset + 28)
        data.write(fileOffset, at: offset + 32)
        data.write(fileSize, at: offset + 36)
        data.write(UInt32(bitPattern: VM_PROT_READ | VM_PROT_WRITE), at: offset + 40)
        data.write(UInt32(bitPattern: VM_PROT_READ | VM_PROT_WRITE), at: offset + 44)
        data.write(UInt32(0), at: offset + 48)
        data.write(UInt32(0), at: offset + 52)
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
