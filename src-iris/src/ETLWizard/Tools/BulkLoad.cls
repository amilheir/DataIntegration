/// File bulk-load source (spec add-on): load a CSV — or an auto-converted .xlsx —
/// straight into a target table with IRIS LOAD DATA / LOAD BULK DATA, bypassing
/// the foreign-table + transform path. Files live in the dropzone on the IRIS
/// server filesystem (LOAD [BULK] DATA reads server-side files by path).
Class ETLWizard.Tools.BulkLoad Extends %RegisteredObject
{

Parameter DROPZONE = "/opt/irisbuild/dropzone";

/// Bare column names from a "col TYPE, col TYPE" list (commas inside type parens
/// like NUMERIC(18,4) must not split).
ClassMethod ColNames(columnDefs As %String) As %String [ Internal ]
{
    Set cleaned = "", depth = 0
    For j = 1:1:$Length(columnDefs) {
        Set ch = $Extract(columnDefs, j)
        If ch = "(" { Set depth = depth + 1 }
        If ch = ")" { Set depth = depth - 1 }
        Set cleaned = cleaned _ $Select((ch = ",") && (depth > 0): $Char(1), 1: ch)
    }
    Set out = ""
    For i = 1:1:$Length(cleaned, ",") {
        Set nm = $Piece($ZStrip($Piece(cleaned, ",", i), "<>W"), " ", 1)
        If nm '= "" {
            Set out = out _ $Select(out = "": "", 1: ", ") _ nm
        }
    }
    Return out
}

/// Convert an .xlsx (active sheet) to a sibling .csv via openpyxl. Streaming
/// read_only so large books do not blow memory. Returns "" on success.
ClassMethod PyXlsxToCsv(src As %String, dst As %String) As %String [ Internal, Language = python ]
{
    import openpyxl, csv
    try:
        wb = openpyxl.load_workbook(src, read_only=True, data_only=True)
        ws = wb.active
        with open(dst, 'w', newline='', encoding='utf-8') as f:
            w = csv.writer(f, lineterminator='\n')
            for row in ws.iter_rows(values_only=True):
                w.writerow(['' if v is None else v for v in row])
        wb.close()
        return ''
    except Exception as e:
        return 'ERROR: ' + str(e)
}

/// Convert dropzone/<xlsx> to dropzone/<same>.csv. Returns the bare csv file
/// name, or an ERROR string.
ClassMethod XlsxToCsv(fileName As %String) As %String
{
    Try {
        If (fileName [ "/") || (fileName [ "\") || (fileName [ "..") {
            Return "ERROR: fileName must be a bare file name in the dropzone"
        }
        Set src = ..#DROPZONE _ "/" _ fileName
        If '##class(%File).Exists(src) {
            Return "ERROR: file not found: " _ fileName
        }
        Set csvName = $Piece(fileName, ".", 1, $Length(fileName, ".") - 1) _ ".csv"
        Set dst = ..#DROPZONE _ "/" _ csvName
        Set rc = ..PyXlsxToCsv(src, dst)
        If rc '= "" {
            Return rc
        }
        Return csvName
    } Catch ex {
        Return "ERROR: " _ ex.DisplayString()
    }
}

/// Infer column DDL from a dropzone CSV (reuses the CSV profiler). Returns the
/// InferCsvTypes JSON: {columnDefs, columns, sampledRows}.
ClassMethod InferColumns(fileName As %String) As %String
{
    Set csv = ##class(ETLWizard.Tools.CsvProfiling).%New()
    Return csv.InferCsvTypes(fileName)
}

/// The USING separator char: accept a literal char, or "\t" for TAB.
ClassMethod SepChar(separator As %String) As %String [ Internal ]
{
    If separator = "\t" { Return $Char(9) }
    If separator = "" { Return "," }
    Return $Extract(separator, 1)
}

/// Build the LOAD [BULK] DATA statement.
ClassMethod BuildLoadSql(target As %String, colList As %String, path As %String, bulk As %Boolean, header As %Boolean, separator As %String) As %String
{
    Set using = {"from": {"file": {"header": ($Select(header: 1, 1: 0)), "columnseparator": (..SepChar(separator))}}}
    Return "LOAD " _ $Select(bulk: "BULK ", 1: "") _ "DATA FROM FILE '" _ path _ "' INTO " _ target _
        " (" _ colList _ ") USING " _ using.%ToJSON()
}

/// Pre-flight validation: file present + readable, header column count matches
/// the target columns, and the LOAD statement prepares cleanly. Returns "" or an
/// ERROR string — called before any table/production is created.
ClassMethod Validate(fileName As %String, columnDefs As %String, header As %Boolean, separator As %String, Output colList As %String) As %String
{
    Set colList = ""
    If '##class(ETLWizard.Tools.Util).ValidColumnDefs(columnDefs) {
        Return "ERROR: invalid column definition list"
    }
    If (fileName [ "/") || (fileName [ "\") || (fileName [ "..") {
        Return "ERROR: fileName must be a bare file name in the dropzone"
    }
    Set path = ..#DROPZONE _ "/" _ fileName
    If '##class(%File).Exists(path) {
        Return "ERROR: file not found in dropzone: " _ fileName
    }
    Set colList = ..ColNames(columnDefs)
    Set nCols = $Length(colList, ",")
    // header column count == target column count
    Set stream = ##class(%Stream.FileCharacter).%New()
    If $$$ISOK(stream.LinkToFile(path)) && ('stream.AtEnd) {
        Set first = stream.ReadLine()
        Set nFile = $Length(first, ..SepChar(separator))
        If nFile '= nCols {
            Return "ERROR: the file's first row has " _ nFile _ " column(s) but the target expects " _
                nCols _ " (" _ colList _ ") — check the delimiter and header setting"
        }
    }
    Return ""
}

/// Build target, validate, and first-load the file. strategy: full | append.
/// Returns stats JSON {rowsLoaded, target, ...} or an ERROR string.
ClassMethod Deploy(runId As %String, baseName As %String, fileName As %String, columnDefs As %String, strategy As %String = "full", bulk As %Boolean = 1, header As %Boolean = 1, separator As %String = ",") As %String
{
    Try {
        Set util = "ETLWizard.Tools.Util"
        If '$ClassMethod(util, "ValidIdent", baseName) {
            Return "ERROR: invalid baseName"
        }
        Set err = ..Validate(fileName, columnDefs, header, separator, .colList)
        If err '= "" {
            Return err
        }
        Set target = "ETLW_TARGET." _ baseName
        Set path = ..#DROPZONE _ "/" _ fileName

        // fresh target shaped exactly to the file's columns (no audit cols, so the
        // LOAD column list matches 1:1)
        Do $ClassMethod(util, "RunDDL", "DROP TABLE " _ target)
        Set err = $ClassMethod(util, "RunDDL", "CREATE TABLE " _ target _ " (" _ columnDefs _ ")")
        If err '= "" {
            Return err
        }

        // VALIDATION LAYER: prepare the exact LOAD statement before executing
        Set loadSql = ..BuildLoadSql(target, colList, path, bulk, header, separator)
        Set stmt = ##class(%SQL.Statement).%New()
        Set sc = stmt.%Prepare(loadSql)
        If $$$ISERR(sc) {
            Return "ERROR: the file does not form a valid load statement: " _ $System.Status.GetErrorText(sc)
        }
        Set rs = stmt.%Execute()
        If rs.%SQLCODE < 0 {
            Return "ERROR loading file (SQLCODE " _ rs.%SQLCODE _ "): " _ rs.%Message
        }
        Set rows = ..CountRows(target)

        // graph: source(file) -> bulk_load -> target
        Set srcName = "file: " _ fileName
        Set cfg = {"file": (fileName), "strategy": (strategy), "bulk": (bulk),
                   "header": (header), "separator": (separator)}
        Do $ClassMethod(util, "CatalogNode", runId, "source", srcName, "", cfg.%ToJSON())
        Do $ClassMethod(util, "CatalogNode", runId, "bulk_load", baseName _ "_bulk", loadSql, cfg.%ToJSON())
        Do $ClassMethod(util, "CatalogNode", runId, "target", target, "", "")
        Set cat = ##class(ETLWizard.Tools.Catalog).%New()
        Do cat.CatalogLink(runId, srcName, baseName _ "_bulk", $Select(bulk: "LOAD BULK DATA", 1: "LOAD DATA"))
        Do cat.CatalogLink(runId, baseName _ "_bulk", target, $Select(strategy = "append": "Append", 1: "Full reload"))

        Return {"strategy": ("bulk"), "rowsLoaded": (rows), "target": (target),
                "bulk": (bulk), "file": (fileName)}.%ToJSON()
    } Catch ex {
        Return "ERROR: " _ ex.DisplayString()
    }
}

/// Re-run entry (executor / production). Reads file + options from the pipeline
/// metadata. Full = TRUNCATE then LOAD; Append = LOAD onto existing rows.
ClassMethod RunBulkLoad(runId As %String, baseName As %String) As %String
{
    Try {
        Set util = "ETLWizard.Tools.Util"
        Set run = ##class(ETLWizard.Model.Run).%OpenId(runId)
        If '$IsObject(run) {
            Return "ERROR: run not found: " _ runId
        }
        Set meta = ##class(%DynamicObject).%FromJSON(run.Pipeline.MetadataJson)
        If '$IsObject(meta.source) {
            Return "ERROR: pipeline metadata has no source"
        }
        Set fileName = meta.source.%Get("file", "")
        Set columnDefs = meta.source.%Get("columnDefs", "")
        Set strategy = meta.source.%Get("strategy", "full")
        Set bulk = meta.source.%Get("bulk", 1)
        Set header = meta.source.%Get("header", 1)
        Set separator = meta.source.%Get("separator", ",")
        Set target = "ETLW_TARGET." _ baseName

        Set err = ..Validate(fileName, columnDefs, header, separator, .colList)
        If err '= "" {
            Return err
        }
        If strategy '= "append" {
            Do $ClassMethod(util, "RunDML", "TRUNCATE TABLE " _ target)
        }
        Set loadSql = ..BuildLoadSql(target, colList, ..#DROPZONE _ "/" _ fileName, bulk, header, separator)
        Set stmt = ##class(%SQL.Statement).%New()
        Set sc = stmt.%Prepare(loadSql)
        If $$$ISERR(sc) {
            Return "ERROR: " _ $System.Status.GetErrorText(sc)
        }
        Set rs = stmt.%Execute()
        If rs.%SQLCODE < 0 {
            Return "ERROR loading file (SQLCODE " _ rs.%SQLCODE _ "): " _ rs.%Message
        }
        Return {"strategy": ("bulk"), "rowsLoaded": (..CountRows(target)), "target": (target)}.%ToJSON()
    } Catch ex {
        Return "ERROR: " _ ex.DisplayString()
    }
}

/// Row count of a target table.
ClassMethod CountRows(target As %String) As %Integer [ Internal ]
{
    Set n = 0
    Try {
        Set stmt = ##class(%SQL.Statement).%New()
        If $$$ISOK(stmt.%Prepare("SELECT COUNT(*) c FROM " _ target)) {
            Set rs = stmt.%Execute()
            If rs.%Next() { Set n = rs.%Get("c") }
        }
    } Catch {
    }
    Return n
}

}
