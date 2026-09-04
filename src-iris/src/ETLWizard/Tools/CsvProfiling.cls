/// Read-only CSV inspection tools (spec §10.2). Files live in the dropzone
/// directory mounted into the container (spec §3.1 source #2).
Class ETLWizard.Tools.CsvProfiling Extends %AI.Tool [ DependsOn = ETLWizard.Tools.Util ]
{

Parameter DROPZONE = "/opt/irisbuild/dropzone";

/// Directory the CSV tools read. Defaults to the dropzone; the wizard can
/// point it at any readable path on the IRIS container so files do not have to
/// be copied into the dropzone first. Set it with SetDirectory() - the
/// traversal guard in OpenCsv() still applies, so only the FILE NAME comes
/// from the caller, never a path.
Property Directory As %String [ InitialExpression = {..#DROPZONE} ];

/// Point the tools at a directory; blank or missing falls back to the dropzone.
Method SetDirectory(dir As %String = "") As %Status
{
    Set dir = $ZStrip(dir, "<>W")
    Set ..Directory = $Select(dir = "": ..#DROPZONE, 1: dir)
    Return $$$OK
}

/// List the CSV files available in the dropzone directory.
Method ListCsvFiles() As %String
{
    Try {
        Set files = []
        Set rs = ##class(%ResultSet).%New("%File:FileSet")
        Set sc = rs.Execute(..Directory, "*.csv")
        If $$$ISERR(sc) {
            Return "ERROR: " _ $System.Status.GetErrorText(sc)
        }
        While rs.Next() {
            Do files.%Push({"name": (rs.Get("ItemName")), "size": (rs.Get("Size"))})
        }
        Return {"directory": (..Directory), "files": (files)}.%ToJSON()
    } Catch ex {
        Return "ERROR: " _ ex.DisplayString()
    }
}

/// Preview a CSV file: detects the delimiter, header presence, and returns
/// the first lines.
/// How many data rows InferCsvTypes reads before it commits to a type. Deep
/// enough that a value which only appears well into the file still widens the
/// column; capped so profiling a huge file cannot stall the wizard.
Parameter MAXSAMPLEROWS = 250000;

Method InspectCsv(fileName As %String, maxLines As %Integer = 5) As %String
{
    Try {
        Set err = ..OpenCsv(fileName, .stream)
        If err '= "" {
            Return err
        }
        If maxLines > 20 {
            Set maxLines = 20
        }
        Set lines = []
        Set first = ""
        Set count = 0
        While ('stream.AtEnd) && (count < maxLines) {
            Set line = stream.ReadLine()
            If count = 0 {
                Set first = line
            }
            Do lines.%Push(line)
            Set count = count + 1
        }
        // Delimiter: the candidate occurring most often in the first line
        Set best = ","
        Set bestCount = 0
        For d = ",", ";", "|", $Char(9) {
            Set c = $Length(first, d) - 1
            If c > bestCount {
                Set best = d
                Set bestCount = c
            }
        }
        // Header guess: first line has no field that is purely numeric
        Set hasHeader = 1
        For f = 1:1:$Length(first, best) {
            Set field = $ZStrip($Piece(first, best, f), "<>W")
            If (field '= "") && ($IsValidNum(field)) {
                Set hasHeader = 0
                Quit
            }
        }
        Return {"file": (fileName), "delimiter": ($Select(best = $Char(9): "tab", 1: best)),
                "hasHeader": (hasHeader), "columns": ($Length(first, best)),
                "preview": (lines)}.%ToJSON()
    } Catch ex {
        Return "ERROR: " _ ex.DisplayString()
    }
}

/// Infer IRIS SQL column types from a sample of the file and return a
/// ready-to-use column definition list for CreateForeignTableCsv.
Method InferCsvTypes(fileName As %String) As %String
{
    Try {
        Set err = ..OpenCsv(fileName, .stream)
        If err '= "" {
            Return err
        }
        Set header = stream.ReadLine()
        // strip a trailing CR (CRLF files) and a leading UTF-8 BOM, else the last
        // column keeps a \r and gets renamed colN — which then won't match the
        // file header LOAD DATA reads (SQLCODE -400 "not defined in header").
        Set header = $ZStrip(header, ">", $Char(13))
        If $Extract(header, 1, 3) = $Char(239, 187, 191) {
            Set header = $Extract(header, 4, *)
        }
        Set delim = ","
        Set bestCount = 0
        For d = ",", ";", "|", $Char(9) {
            Set c = $Length(header, d) - 1
            If c > bestCount {
                Set delim = d
                Set bestCount = c
            }
        }
        Set colCount = $Length(header, delim)
        // type codes per column: 1=INTEGER 2=NUMERIC 3=DATE 4=VARCHAR
        For c = 1:1:colCount {
            Set type(c) = 0
            Set maxLen(c) = 1
        }
        // SAMPLE DEPTH: this was 50 rows, and 50 rows is how a column gets the
        // wrong type. In online_retail.csv every InvoiceNo in the first 141 rows
        // is digits; the first cancellation ("C536379") is row 142. The column
        // was therefore typed INTEGER, 9,291 C-rows were bulk-loaded into it
        // without validation, and the failure only surfaced downstream when
        // staging re-validated them:
        //   SQLCODE -104: Field 'InvoiceNo' (value 'C536379') failed validation
        //
        // Type widening is one-way (a single text value makes the column
        // VARCHAR), so a deeper scan can only ever be more correct - it just
        // costs time. The cap bounds that cost on very large files: ~4s for
        // 250k rows of this shape. sampledRows is reported so the caller can
        // see whether the whole file was covered or the cap was hit.
        Set sampled = 0
        While ('stream.AtEnd) && (sampled < ..#MAXSAMPLEROWS) {
            Set line = $ZStrip(stream.ReadLine(), ">", $Char(13))
            If line = "" {
                Continue
            }
            Do ..SplitCsvLine(line, delim, .fld, colCount)
            For c = 1:1:colCount {
                Set v = $ZStrip($Get(fld(c)), "<>W")
                If $Length(v) > maxLen(c) {
                    Set maxLen(c) = $Length(v)
                }
                Set t = ..InferValueType(v)
                If t > type(c) {
                    Set type(c) = t
                }
            }
            Set sampled = sampled + 1
        }
        Set defs = ""
        Set report = []
        For c = 1:1:colCount {
            Set colName = $Translate($ZStrip($Piece(header, delim, c), "<>W"), " -", "__")
            If '##class(ETLWizard.Tools.Util).ValidIdent(colName) {
                Set colName = "col" _ c
            }
            Set sqlType = $Case(type(c),
                1: "INTEGER",
                2: "NUMERIC(18,4)",
                3: "DATE",
                : "VARCHAR(" _ $Select(maxLen(c) < 50: 50, 1: maxLen(c) * 2) _ ")")
            Set defs = defs _ $Select(defs = "": "", 1: ", ") _ colName _ " " _ sqlType
            Do report.%Push({"column": (colName), "type": (sqlType)})
        }
        Return {"file": (fileName), "sampledRows": (sampled), "columns": (report),
                "columnDefs": (defs)}.%ToJSON()
    } Catch ex {
        Return "ERROR: " _ ex.DisplayString()
    }
}

/// Shared open/validate. Returns "" and the stream by reference, or an error.
Method OpenCsv(fileName As %String, Output stream As %Stream.FileCharacter) As %String [ Internal, Private ]
{
    Set stream = ""
    If (fileName [ "/") || (fileName [ "\") || (fileName [ "..") {
        Return "ERROR: fileName must be a bare file name (no path)"
    }
    Set path = ..Directory _ "/" _ fileName
    If '##class(%File).Exists(path) {
        Return "ERROR: file not found: " _ fileName
    }
    Set stream = ##class(%Stream.FileCharacter).%New()
    Set sc = stream.LinkToFile(path)
    If $$$ISERR(sc) {
        Return "ERROR: " _ $System.Status.GetErrorText(sc)
    }
    Return ""
}

/// Split one CSV line into fld(1..n), honouring RFC-4180 quoting.
///
/// $Piece(line, ",", c) is not good enough: a quoted field containing the
/// delimiter ("AIRLINE LOUNGE,METAL SIGN") shifts every later column on that
/// line. In the online_retail sample that is 6,035 of 541,909 lines - enough
/// that a full-file scan with $Piece infers VARCHAR for EVERY column, because
/// the misaligned rows push text into the numeric ones.
///
/// Lines with no quote at all (98.9% here) take the cheap $Piece path, so the
/// character loop is only paid where it is actually needed.
ClassMethod SplitCsvLine(line As %String, delim As %String, Output fld, colCount As %Integer) [ Internal, Private ]
{
    Kill fld
    If line '[ """" {
        For c = 1:1:colCount {
            Set fld(c) = $Piece(line, delim, c)
        }
        Quit
    }
    Set col = 1, cur = "", inQuote = 0, len = $Length(line)
    For j = 1:1:len {
        Set ch = $Extract(line, j)
        If ch = """" {
            // "" inside a quoted field is one literal quote
            If inQuote && ($Extract(line, j + 1) = """") {
                Set cur = cur _ """"
                Set j = j + 1
            } Else {
                Set inQuote = 'inQuote
            }
        } ElseIf (ch = delim) && 'inQuote {
            Set fld(col) = cur
            Set col = col + 1
            Set cur = ""
        } Else {
            Set cur = cur _ ch
        }
    }
    Set fld(col) = cur
    Quit
}

/// 1=INTEGER 2=NUMERIC 3=DATE 4=VARCHAR (0 = empty/unknown)
ClassMethod InferValueType(v As %String) As %Integer [ Internal, Private ]
{
    If v = "" {
        Return 0
    }
    // optional leading minus: the cancellation rows carry Quantity -1, and
    // without it a column of negative whole numbers degrades to NUMERIC(18,4)
    If v ? .1"-"1.N {
        Return 1
    }
    If $IsValidNum(v) {
        Return 2
    }
    If (v ? 4N1"-"2N1"-"2N) || (v ? 2N1"/"2N1"/"4N) {
        Return 3
    }
    Return 4
}

}
