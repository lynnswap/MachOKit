//
//  MachOImage+DyldChainedFixups..swift
//
//
//  Created by p-x9 on 2024/01/11.
//  
//

import Foundation

extension MachOImage {
    public struct DyldChainedFixups {
        public let basePointer: UnsafePointer<UInt8>
        public let dyldChainedFixupsSize: Int
    }
}

extension MachOImage.DyldChainedFixups {
    init?(
        dyldChainedFixups: linkedit_data_command,
        linkedit: SegmentCommand64,
        vmaddrSlide: Int
    ) {
        guard let linkeditStartPtr = linkedit.startPtr(
            vmaddrSlide: vmaddrSlide
        ) else {
            return nil
        }
        let dataOffset = UInt64(dyldChainedFixups.dataoff)
        let dataSize = UInt64(dyldChainedFixups.datasize)
        let linkeditOffset = linkedit.layout.fileoff
        let linkeditSize = linkedit.layout.filesize
        guard dataOffset >= linkeditOffset else { return nil }
        let relativeOffset = dataOffset - linkeditOffset
        guard relativeOffset <= linkeditSize,
              dataSize <= linkeditSize - relativeOffset,
              let relativeOffset = Int(exactly: relativeOffset),
              let size = Int(exactly: dataSize) else {
            return nil
        }
        let start = linkeditStartPtr
            .advanced(by: relativeOffset)
            .assumingMemoryBound(to: UInt8.self)

        self.init(
            basePointer: start,
            dyldChainedFixupsSize: size
        )
    }

    init?(
        dyldChainedFixups: linkedit_data_command,
        linkedit: SegmentCommand,
        vmaddrSlide: Int
    ) {
        guard let linkeditStartPtr = linkedit.startPtr(
            vmaddrSlide: vmaddrSlide
        ) else {
            return nil
        }
        let dataOffset = UInt64(dyldChainedFixups.dataoff)
        let dataSize = UInt64(dyldChainedFixups.datasize)
        let linkeditOffset = UInt64(linkedit.layout.fileoff)
        let linkeditSize = UInt64(linkedit.layout.filesize)
        guard dataOffset >= linkeditOffset else { return nil }
        let relativeOffset = dataOffset - linkeditOffset
        guard relativeOffset <= linkeditSize,
              dataSize <= linkeditSize - relativeOffset,
              let relativeOffset = Int(exactly: relativeOffset),
              let size = Int(exactly: dataSize) else {
            return nil
        }
        let start = linkeditStartPtr
            .advanced(by: relativeOffset)
            .assumingMemoryBound(to: UInt8.self)

        self.init(
            basePointer: start,
            dyldChainedFixupsSize: size
        )
    }
}

extension MachOImage.DyldChainedFixups: DyldChainedFixupsProtocol {
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

    public func pages(
        of startsInSegment: DyldChainedStartsInSegment?
    ) -> [DyldChainedPage] {
        guard let startsInSegment,
              let segment = try? parser.segment(matching: startsInSegment) else {
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

extension MachOImage.DyldChainedFixups {
    internal var parser: DyldChainedFixupsParser {
        .init(
            view: .init(
                bytes: .init(
                    start: basePointer,
                    count: dyldChainedFixupsSize
                )
            ),
            isSwapped: false
        )
    }
}
