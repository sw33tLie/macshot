import Foundation

enum XLSXWriterError: LocalizedError {
    case workbookTooLarge

    var errorDescription: String? {
        L("The recognized table is too large to create an Excel file.")
    }
}

enum XLSXWriter {

    static func data(for table: RecognizedTable) throws -> Data {
        let entries = [
            ZipEntry(path: "[Content_Types].xml", data: xmlData(contentTypesXML)),
            ZipEntry(path: "_rels/.rels", data: xmlData(rootRelationshipsXML)),
            ZipEntry(path: "xl/workbook.xml", data: xmlData(workbookXML)),
            ZipEntry(path: "xl/_rels/workbook.xml.rels", data: xmlData(workbookRelationshipsXML)),
            ZipEntry(path: "xl/worksheets/sheet1.xml", data: xmlData(worksheetXML(for: table))),
        ]
        return try makeZip(entries: entries)
    }

    private static let contentTypesXML = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
      <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
      <Default Extension="xml" ContentType="application/xml"/>
      <Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>
      <Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>
    </Types>
    """

    private static let rootRelationshipsXML = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
      <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>
    </Relationships>
    """

    private static let workbookXML = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
      <sheets><sheet name="Sheet1" sheetId="1" r:id="rId1"/></sheets>
    </workbook>
    """

    private static let workbookRelationshipsXML = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
      <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/>
    </Relationships>
    """

    private static func worksheetXML(for table: RecognizedTable) -> String {
        let rowXML = table.rows.enumerated().map { rowIndex, row in
            let cells = row.enumerated().compactMap { columnIndex, value -> String? in
                guard !value.isEmpty else { return nil }
                let reference = "\(columnName(columnIndex))\(rowIndex + 1)"
                return "<c r=\"\(reference)\" t=\"inlineStr\"><is><t xml:space=\"preserve\">\(escapedXML(value))</t></is></c>"
            }.joined()
            return "<row r=\"\(rowIndex + 1)\">\(cells)</row>"
        }.joined()

        let endCell = "\(columnName(max(table.columnCount - 1, 0)))\(max(table.rows.count, 1))"
        return """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
          <dimension ref="A1:\(endCell)"/>
          <sheetData>\(rowXML)</sheetData>
        </worksheet>
        """
    }

    private static func columnName(_ zeroBasedIndex: Int) -> String {
        var index = zeroBasedIndex + 1
        var result = ""
        while index > 0 {
            index -= 1
            result = String(UnicodeScalar(65 + index % 26)!) + result
            index /= 26
        }
        return result
    }

    private static func escapedXML(_ value: String) -> String {
        let validScalars = value.unicodeScalars.filter { scalar in
            scalar.value == 0x9 || scalar.value == 0xA || scalar.value == 0xD
                || scalar.value >= 0x20
        }
        return String(String.UnicodeScalarView(validScalars))
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    private static func xmlData(_ string: String) -> Data {
        Data(string.utf8)
    }

    private struct ZipEntry {
        let path: String
        let data: Data
    }

    private struct CentralDirectoryEntry {
        let pathData: Data
        let crc32: UInt32
        let size: UInt32
        let localHeaderOffset: UInt32
    }

    private static func makeZip(entries: [ZipEntry]) throws -> Data {
        var archive = Data()
        var centralEntries: [CentralDirectoryEntry] = []

        for entry in entries {
            let pathData = Data(entry.path.utf8)
            guard entry.data.count <= Int(UInt32.max),
                  archive.count <= Int(UInt32.max),
                  pathData.count <= Int(UInt16.max) else {
                throw XLSXWriterError.workbookTooLarge
            }

            let size = UInt32(entry.data.count)
            let crc = crc32(entry.data)
            let offset = UInt32(archive.count)

            archive.appendUInt32(0x04034b50)
            archive.appendUInt16(20)
            archive.appendUInt16(0)
            archive.appendUInt16(0)
            archive.appendUInt16(0)
            archive.appendUInt16(0)
            archive.appendUInt32(crc)
            archive.appendUInt32(size)
            archive.appendUInt32(size)
            archive.appendUInt16(UInt16(pathData.count))
            archive.appendUInt16(0)
            archive.append(pathData)
            archive.append(entry.data)

            centralEntries.append(CentralDirectoryEntry(
                pathData: pathData,
                crc32: crc,
                size: size,
                localHeaderOffset: offset
            ))
        }

        guard archive.count <= Int(UInt32.max), centralEntries.count <= Int(UInt16.max) else {
            throw XLSXWriterError.workbookTooLarge
        }
        let centralDirectoryOffset = UInt32(archive.count)

        for entry in centralEntries {
            archive.appendUInt32(0x02014b50)
            archive.appendUInt16(20)
            archive.appendUInt16(20)
            archive.appendUInt16(0)
            archive.appendUInt16(0)
            archive.appendUInt16(0)
            archive.appendUInt16(0)
            archive.appendUInt32(entry.crc32)
            archive.appendUInt32(entry.size)
            archive.appendUInt32(entry.size)
            archive.appendUInt16(UInt16(entry.pathData.count))
            archive.appendUInt16(0)
            archive.appendUInt16(0)
            archive.appendUInt16(0)
            archive.appendUInt16(0)
            archive.appendUInt32(0)
            archive.appendUInt32(entry.localHeaderOffset)
            archive.append(entry.pathData)
        }

        guard archive.count <= Int(UInt32.max) else {
            throw XLSXWriterError.workbookTooLarge
        }
        let centralDirectorySize = UInt32(archive.count) - centralDirectoryOffset
        let entryCount = UInt16(centralEntries.count)

        archive.appendUInt32(0x06054b50)
        archive.appendUInt16(0)
        archive.appendUInt16(0)
        archive.appendUInt16(entryCount)
        archive.appendUInt16(entryCount)
        archive.appendUInt32(centralDirectorySize)
        archive.appendUInt32(centralDirectoryOffset)
        archive.appendUInt16(0)
        return archive
    }

    private static func crc32(_ data: Data) -> UInt32 {
        var crc = UInt32.max
        for byte in data {
            let tableIndex = Int((crc ^ UInt32(byte)) & 0xff)
            crc = crcTable[tableIndex] ^ (crc >> 8)
        }
        return crc ^ UInt32.max
    }

    private static let crcTable: [UInt32] = (0..<256).map { value in
        var crc = UInt32(value)
        for _ in 0..<8 {
            crc = (crc & 1) == 1 ? 0xedb88320 ^ (crc >> 1) : crc >> 1
        }
        return crc
    }
}

private extension Data {
    mutating func appendUInt16(_ value: UInt16) {
        append(contentsOf: [UInt8(value & 0xff), UInt8((value >> 8) & 0xff)])
    }

    mutating func appendUInt32(_ value: UInt32) {
        append(contentsOf: [
            UInt8(value & 0xff),
            UInt8((value >> 8) & 0xff),
            UInt8((value >> 16) & 0xff),
            UInt8((value >> 24) & 0xff),
        ])
    }
}
