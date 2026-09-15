Include %occStatus

/// Knowledge Graph ingestion: target table -> chunks -> vectors -> LINK-KG graph
/// (mds/knowledge-graph-tab-plan.md §5).
///
/// Runs in batches and is re-entrant: every batch advances Corpus.lastRowId and
/// commits, so a cancel, a crash or a webgateway timeout costs one batch, never
/// the run. That is also the incremental-refresh mechanism (§6.2).
Class ETLWizard.KG.Ingest Extends %RegisteredObject
{

/// A VARCHAR has to be at least this wide to be a candidate for prose.
///
/// Only a cheap PRE-filter, and deliberately generous. Declared width is a weak
/// signal both ways: a transform-built table types every column VARCHAR(4000)
/// however short its values, while a bulk-ingested file is typed from its actual
/// content - which made a column of real 178-character feedback fail a 200
/// threshold and vanish from the picker. The honest measurement of "is this
/// prose?" is the average length Profile() reports once a column is chosen.
Parameter MINTEXTWIDTH = 60;

/// Rows read per batch. Also the embedding batch size - measured fastest per
/// row at 32 (31 ms/row vs 247 ms unbatched and 39 ms at 128).
Parameter BATCHROWS = 32;

/// Default characters per chunk. High on purpose: a product description or a
/// feedback comment is one chunk, and the splitter only earns its keep on logs
/// and long-form text.
Parameter CHUNKCHARS = 4000;

/// Text shorter than this is skipped, not embedded. A vector for "n/a" is noise
/// that surfaces in every search.
Parameter MINCHARS = 20;

/// Schemas holding text worth embedding: the outputs of an ETL, and the
/// sources ingested by a bulk load. Mounted FOREIGN tables are deliberately
/// excluded - they have no %ID, which is the cursor the batch loop pages on.
ClassMethod Schemas() As %List [ Internal ]
{
    Return $ListBuild("ETLW_TARGET", "ETLWIZARD")
}

/// Split a table reference into schema and name, defaulting to ETLW_TARGET for
/// a bare name so older callers keep working.
ClassMethod SplitTable(name As %String, Output schema As %String, Output bare As %String) As %Boolean [ Internal ]
{
    If name [ "." {
        Set schema = $ZConvert($Piece(name, ".", 1), "U")
        Set bare = $Piece(name, ".", 2, *)
    } Else {
        Set schema = "ETLW_TARGET"
        Set bare = name
    }
    If '$ListFind(..Schemas(), schema) {
        Return 0
    }
    Return ##class(ETLWizard.Tools.Util).ValidIdent(bare)
}

// ------------------------------------------------------------- discovery

/// ETLW_TARGET tables with at least one column wide enough to hold prose.
ClassMethod ListCandidates() As %DynamicArray
{
    Set out = []
    Try {
        Set stmt = ##class(%SQL.Statement).%New()
        // A mounted foreign table has no %ID to page on, so only base tables
        // qualify - which is exactly the bulk-ingested ext_* ones.
        Set sc = stmt.%Prepare("SELECT c.TABLE_SCHEMA, c.TABLE_NAME, c.COLUMN_NAME, c.DATA_TYPE, " _
            "c.CHARACTER_MAXIMUM_LENGTH FROM INFORMATION_SCHEMA.COLUMNS c " _
            "WHERE c.TABLE_SCHEMA IN ('ETLW_TARGET','ETLWIZARD') " _
            "AND c.TABLE_NAME NOT IN (SELECT f.TABLE_NAME FROM INFORMATION_SCHEMA.FOREIGN_TABLES f " _
            "WHERE f.TABLE_SCHEMA = c.TABLE_SCHEMA) " _
            "ORDER BY c.TABLE_SCHEMA, c.TABLE_NAME, c.ORDINAL_POSITION")
        If $$$ISERR(sc) {
            Return out
        }
        Set rs = stmt.%Execute()
        Kill tables
        While rs.%Next() {
            Set table = rs.%GetData(1) _ "." _ rs.%GetData(2), col = rs.%GetData(3)
            Set type = $ZConvert(rs.%GetData(4), "L"), width = +rs.%GetData(5)
            Set tables(table, "all", col) = type
            If (type [ "char") && (width >= ..#MINTEXTWIDTH) {
                Set tables(table, "text", col) = width
            }
        }
        Set table = ""
        For {
            Set table = $Order(tables(table))
            If table = "" {
                Quit
            }
            If '$Data(tables(table, "text")) {
                Continue
            }
            Set textCols = [], labelCols = []
            Set c = ""
            For {
                Set c = $Order(tables(table, "text", c))
                If c = "" {
                    Quit
                }
                Do textCols.%Push({"name": (c), "width": (tables(table, "text", c))})
            }
            Set c = ""
            For {
                Set c = $Order(tables(table, "all", c))
                If c = "" {
                    Quit
                }
                Do labelCols.%Push(c)
            }
            Set rows = ##class(ETLWizard.Tools.Util).ScalarQuery("SELECT COUNT(*) FROM " _ table)
            If $Extract(rows, 1, 5) = "ERROR" {
                Set rows = ""
            }
            Do out.%Push({"name": (table), "full": (table),
                          "rows": (rows), "textColumns": (textCols), "columns": (labelCols)})
        }
    } Catch ex {
    }
    Return out
}

/// Measure one table+column before committing to it: how much text there is,
/// and what it will cost. The embedding cost is MEASURED here, not assumed -
/// every estimate the UI shows is downstream of this one number.
ClassMethod Profile(table As %String, column As %String) As %DynamicObject
{
    Try {
        If '..SplitTable(table, .schema, .bare) || '##class(ETLWizard.Tools.Util).ValidIdent(column) {
            Return {"error": "invalid table or column name"}
        }
        Set full = schema _ "." _ bare
        Set rows = +##class(ETLWizard.Tools.Util).ScalarQuery("SELECT COUNT(*) FROM " _ full)
        Set nonEmpty = +##class(ETLWizard.Tools.Util).ScalarQuery(
            "SELECT COUNT(*) FROM " _ full _ " WHERE " _ column _ " IS NOT NULL AND LENGTH(" _ column _ ") >= " _ ..#MINCHARS)
        Set avgLen = ##class(ETLWizard.Tools.Util).ScalarQuery(
            "SELECT AVG(LENGTH(" _ column _ ")) FROM " _ full _ " WHERE " _ column _ " IS NOT NULL")
        Set maxLen = ##class(ETLWizard.Tools.Util).ScalarQuery(
            "SELECT MAX(LENGTH(" _ column _ ")) FROM " _ full _ " WHERE " _ column _ " IS NOT NULL")

        // measured, not assumed: one real batch against the live endpoint
        Set sample = []
        Set stmt = ##class(%SQL.Statement).%New()
        Set msPerRow = ""
        If $$$ISOK(stmt.%Prepare("SELECT TOP 8 " _ column _ " FROM " _ full _ " WHERE " _ column _ " IS NOT NULL")) {
            Set rs = stmt.%Execute()
            While rs.%Next() {
                Do sample.%Push($Extract(rs.%GetData(1), 1, 2000))
            }
            If sample.%Size() > 0 {
                Set start = $ZHorolog
                Set err = ##class(ETLWizard.KG.Embedder).Embed(sample, .vectors)
                If err = "" {
                    Set msPerRow = ##class(ETLWizard.KG.Setup).Round((($ZHorolog - start) * 1000) / sample.%Size(), 0)
                }
            }
        }
        Return {"table": (full), "column": (column), "rows": (rows),
                "embeddableRows": (nonEmpty),
                "avgChars": (##class(ETLWizard.KG.Setup).Round(+avgLen, 0)), "maxChars": (+maxLen),
                "msPerRow": (msPerRow), "batchSize": (..#BATCHROWS)}
    } Catch ex {
        Return {"error": (ex.DisplayString())}
    }
}

// --------------------------------------------------------------- lifecycle

/// Create a corpus. Does not embed anything - RunBatch does the work, so the
/// caller returns immediately and the UI can poll.
ClassMethod Start(spec As %DynamicObject) As %DynamicObject
{
    Try {
        If '..SplitTable(spec.%Get("table", ""), .schema, .bare) {
            Return {"error": "pick a table in ETLW_TARGET or ETLWIZARD"}
        }
        Set textCol = $ZStrip(spec.%Get("textColumn", ""), "<>W")
        Set labelCol = $ZStrip(spec.%Get("labelColumn", ""), "<>W")
        Set keyCols = $ZStrip(spec.%Get("keyColumns", ""), "<>W")
        If '##class(ETLWizard.Tools.Util).ValidIdent(textCol) {
            Return {"error": "pick the column holding the text"}
        }
        If (labelCol '= "") && '##class(ETLWizard.Tools.Util).ValidIdent(labelCol) {
            Return {"error": "invalid label column"}
        }
        Set err = ..ValidateKeyColumns(schema, bare, keyCols)
        If err '= "" {
            Return {"error": (err)}
        }

        Set full = schema _ "." _ bare
        Set name = $ZStrip(spec.%Get("name", ""), "<>W")
        If name = "" {
            Set name = bare _ "." _ textCol
        }
        Set res = ##class(ETLWizard.Tools.Util).RunDML(
            "INSERT INTO ETLW_KG.Corpus (name, sourceTable, textColumn, labelColumn, keyColumns, " _
            "rowsRequested, rowsIngested, chunksIngested, chunkChars, batchSize, extractGraph, " _
            "embedModel, chatModel, status, statusDetail, autoRefresh, refreshCap, keyMode, " _
            "startedAt, lastRowId, lastSeenAt) " _
            "VALUES (?,?,?,?,?,?,0,0,?,?,?,?,?,'queued','waiting to start',?,?,?,?,0,'')",
            name, full, textCol, labelCol, keyCols,
            +spec.%Get("rowLimit", 500), +spec.%Get("chunkChars", ..#CHUNKCHARS), ..#BATCHROWS,
            ''spec.%Get("extractGraph", 0),
            ##class(ETLWizard.KG.Setup).#EMBEDMODEL, ##class(ETLWizard.KG.Setup).GetExtractModel(),
            ''spec.%Get("autoRefresh", 0), +spec.%Get("refreshCap", 500),
            $Select(keyCols = "": "rowid", 1: "key"), $ZDateTime($Horolog, 3))
        If $Extract(res, 1, 5) = "ERROR" {
            Return {"error": (res)}
        }
        Set id = ##class(ETLWizard.Tools.Util).ScalarQuery(
            "SELECT TOP 1 %ID FROM ETLW_KG.Corpus ORDER BY %ID DESC")
        Return ..Status(id)
    } Catch ex {
        Return {"error": (ex.DisplayString())}
    }
}

/// A key is mandatory unless the caller accepts row-id mode, which is only safe
/// on an append-only table: a full reload TRUNCATEs, and TRUNCATE RESETS THE ID
/// COUNTER (verified), so every %ID would then point at a different row.
ClassMethod ValidateKeyColumns(schema As %String, bare As %String, keyCols As %String) As %String [ Internal ]
{
    If keyCols = "" {
        Return ""
    }
    For i = 1:1:$Length(keyCols, ",") {
        Set c = $ZStrip($Piece(keyCols, ",", i), "<>W")
        If '##class(ETLWizard.Tools.Util).ValidIdent(c) {
            Return "'" _ c _ "' is not a valid column name"
        }
        Set exists = +##class(ETLWizard.Tools.Util).ScalarQuery(
            "SELECT COUNT(*) FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_SCHEMA = ? " _
            "AND TABLE_NAME = ? AND COLUMN_NAME = ?", schema, bare, c)
        If 'exists {
            Return "column '" _ c _ "' is not on " _ schema _ "." _ bare
        }
    }
    Return ""
}

/// One batch of work. Returns the corpus status. Call until `done` is true.
ClassMethod RunBatch(corpusId As %String) As %DynamicObject
{
    // One batch at a time per corpus: an auto-refresh firing on a 5-minute poll
    // must not start a second pass over the first. Mirrors the per-base
    // ^ETLWizard.LoadLock the ETL side already uses.
    Lock +^ETLWizard.KGLock(corpusId):5
    If '$Test {
        Return {"error": "this corpus is already being ingested"}
    }
    Try {
        Set c = ..Corpus(corpusId)
        If '$IsObject(c) || (c.%Get("error", "") '= "") {
            Lock -^ETLWizard.KGLock(corpusId)
            Return {"error": ("no such corpus: " _ corpusId)}
        }
        If c.status = "cancelled" {
            Lock -^ETLWizard.KGLock(corpusId)
            Return ..Status(corpusId)
        }

        Set remaining = c.rowsRequested - c.rowsIngested
        If remaining <= 0 {
            Do ..Finish(corpusId, "complete", "ingested " _ c.rowsIngested _ " rows")
            Lock -^ETLWizard.KGLock(corpusId)
            Return ..Status(corpusId)
        }
        Set take = $Select(remaining < ..#BATCHROWS: remaining, 1: ..#BATCHROWS)

        Do ..Mark(corpusId, "running", "reading rows")
        Set rows = ..ReadRows(c, take, .readErr)
        If readErr '= "" {
            Do ..Finish(corpusId, "failed", readErr)
            Lock -^ETLWizard.KGLock(corpusId)
            Return ..Status(corpusId)
        }
        If rows.%Size() = 0 {
            Do ..Finish(corpusId, "complete", "no more rows with text to embed")
            Lock -^ETLWizard.KGLock(corpusId)
            Return ..Status(corpusId)
        }

        Set err = ..EmbedAndStore(corpusId, c, rows)
        // The corpus can be deleted between batches (Clear all, or the presenter
        // control). Writing the rest of this batch into it would resurrect rows
        // under an id nothing points at any more.
        If '..Exists(corpusId) {
            Lock -^ETLWizard.KGLock(corpusId)
            Return {"id": (corpusId), "status": "cancelled", "done": 1,
                    "statusDetail": "the knowledge base was deleted while it was being built"}
        }
        Lock -^ETLWizard.KGLock(corpusId)
        If err '= "" {
            Do ..Finish(corpusId, "failed", err)
        }
        Return ..Status(corpusId)
    } Catch ex {
        Lock -^ETLWizard.KGLock(corpusId)
        Do ..Finish(corpusId, "failed", ex.DisplayString())
        Return ..Status(corpusId)
    }
}

/// Read the next slice of source rows. %ID drives the cursor within a run
/// (monotonic while the table is untouched); the KEY is what identifies the row
/// across reloads.
ClassMethod ReadRows(c As %DynamicObject, take As %Integer, Output err As %String) As %DynamicArray [ Internal ]
{
    Set err = "", out = []
    Try {
        Set table = c.sourceTable, textCol = c.textColumn
        Set labelCol = c.labelColumn, keyCols = c.keyColumns
        Set select = "SELECT TOP " _ take _ " %ID, " _ textCol
        If labelCol '= "" {
            Set select = select _ ", " _ labelCol
        }
        If keyCols '= "" {
            For i = 1:1:$Length(keyCols, ",") {
                Set select = select _ ", " _ $ZStrip($Piece(keyCols, ",", i), "<>W")
            }
        }
        Set select = select _ " FROM " _ table _
            " WHERE %ID > ? AND " _ textCol _ " IS NOT NULL ORDER BY %ID"
        Set stmt = ##class(%SQL.Statement).%New()
        // ODBC mode: a %TimeStamp or similar read logically comes back as
        // 1154710044621846976, which would be embedded as that literal text.
        Set stmt.%SelectMode = 1
        Set sc = stmt.%Prepare(select)
        If $$$ISERR(sc) {
            Set err = "could not read " _ table _ ": " _ $System.Status.GetErrorText(sc)
            Return out
        }
        Set rs = stmt.%Execute(+c.lastRowId)
        While rs.%Next() {
            Set rowId = rs.%GetData(1)
            Set text = rs.%GetData(2)
            Set col = 2
            Set label = ""
            If labelCol '= "" {
                Set col = col + 1, label = rs.%GetData(col)
            }
            Set key = ""
            If keyCols '= "" {
                For i = 1:1:$Length(keyCols, ",") {
                    Set col = col + 1
                    Set key = key _ $Select(key = "": "", 1: "|") _ rs.%GetData(col)
                }
            } Else {
                Set key = "rowid:" _ rowId
            }
            Do out.%Push({"rowId": (rowId), "key": (key), "label": (label), "text": (text)})
        }
    } Catch ex {
        Set err = ex.DisplayString()
    }
    Return out
}

/// Chunk, embed as one batch, write chunks, then optionally extract the graph.
ClassMethod EmbedAndStore(corpusId As %String, c As %DynamicObject, rows As %DynamicArray) As %String [ Internal ]
{
    Set chunkChars = +c.chunkChars
    If chunkChars < 200 {
        Set chunkChars = ..#CHUNKCHARS
    }
    // Flatten rows into chunks first: the embedding call is per TEXT, not per
    // row, and a long row contributing three chunks must still ride in the batch.
    Set texts = [], meta = []
    Set lastRowId = +c.lastRowId
    Set iter = rows.%GetIterator()
    Set skipped = 0
    While iter.%GetNext(, .row) {
        If row.rowId > lastRowId {
            Set lastRowId = row.rowId
        }
        Set text = $ZStrip(row.text, "<>W")
        If $Length(text) < ..#MINCHARS {
            Set skipped = skipped + 1
            Continue
        }
        // Chunk RETURNS the count and fills `pieces` by reference - assigning
        // its return over the array was what wiped it.
        Kill pieces
        Set pieceCount = ..Chunk(text, chunkChars, .pieces)
        For p = 1:1:pieceCount {
            Set body = pieces(p)
            // The label prefixes the EMBEDDED text only: it separates senses in
            // vector space (wikigraph prefixes the article title for the same
            // reason) while chunkText stays clean for display.
            Set embedText = $Select(row.label = "": body, 1: row.label _ " - " _ body)
            Do texts.%Push($Extract(embedText, 1, 30900))
            Do meta.%Push({"key": (row.key), "rowId": (row.rowId), "label": (row.label),
                           "chunkIndex": (p - 1), "text": ($Extract(body, 1, 29000))})
        }
    }
    If texts.%Size() = 0 {
        Do ..Advance(corpusId, lastRowId, rows.%Size(), 0)
        Return ""
    }

    Do ..Mark(corpusId, "running", "embedding " _ texts.%Size() _ " chunks")
    Set err = ##class(ETLWizard.KG.Embedder).Embed(texts, .vectors)
    If err '= "" {
        Return err
    }

    // Write docs and chunks
    Set chunkIds = [], docIds = []
    Set mIter = meta.%GetIterator()
    Set i = -1
    Kill docCache
    While mIter.%GetNext(, .m) {
        Set i = i + 1
        Set docId = ..UpsertDoc(corpusId, m.key, m.rowId, m.label, .docCache)
        If docId = "" {
            Continue
        }
        Set res = ##class(ETLWizard.Tools.Util).RunDML(
            "INSERT INTO ETLW_KG.Chunk (corpusRef, docRef, chunkIndex, chunkText, embedText, chunkVector) " _
            "VALUES (?,?,?,?,?,TO_VECTOR(?, " _ ##class(ETLWizard.KG.Setup).#EMBEDTYPE _ ", " _
            ##class(ETLWizard.KG.Setup).#EMBEDDIMS _ "))",
            corpusId, docId, m.chunkIndex, m.text, $Extract(texts.%Get(i), 1, 31000), vectors.%Get(i))
        If $Extract(res, 1, 5) = "ERROR" {
            Return res
        }
        Set chunkId = ##class(ETLWizard.Tools.Util).ScalarQuery("SELECT TOP 1 %ID FROM ETLW_KG.Chunk ORDER BY %ID DESC")
        Do chunkIds.%Push({"id": (chunkId), "text": (m.text), "label": (m.label)})
    }

    Do ..Advance(corpusId, lastRowId, rows.%Size(), chunkIds.%Size())

    If ''c.extractGraph {
        Set err = ..ExtractInto(corpusId, chunkIds)
        If err '= "" {
            // Extraction failing must not lose the embeddings just written: they
            // are the expensive part and they are valid on their own.
            Do ..Mark(corpusId, "running", "embedded, but extraction failed: " _ $Extract(err, 1, 300))
        }
    }
    Return ""
}

/// Paragraph-aware split. Returns pieces(1..n) by reference, count as the value.
ClassMethod Chunk(text As %String, maxChars As %Integer, Output pieces As %String) As %Integer [ Internal ]
{
    Kill pieces
    Set n = 0
    If $Length(text) <= maxChars {
        Set n = 1, pieces(1) = text
        Return 1
    }
    Set nl = $Char(10)
    Set current = ""
    For p = 1:1:$Length(text, nl) {
        Set para = $Piece(text, nl, p)
        If ($Length(current) + $Length(para) + 1) > maxChars {
            If current '= "" {
                Set n = n + 1, pieces(n) = current
                Set current = ""
            }
            // a single paragraph longer than the limit is cut on length
            While $Length(para) > maxChars {
                Set n = n + 1, pieces(n) = $Extract(para, 1, maxChars)
                Set para = $Extract(para, maxChars + 1, *)
            }
        }
        Set current = current _ $Select(current = "": "", 1: nl) _ para
    }
    If $ZStrip(current, "<>W") '= "" {
        Set n = n + 1, pieces(n) = current
    }
    Return n
}

/// Find or create the Doc for a source key. `cache` avoids re-querying within a
/// batch when several chunks belong to one row.
ClassMethod UpsertDoc(corpusId As %String, key As %String, rowId As %String, label As %String, ByRef cache) As %String [ Internal ]
{
    If $Data(cache(key)) {
        Return cache(key)
    }
    Set id = ##class(ETLWizard.Tools.Util).ScalarQuery(
        "SELECT TOP 1 %ID FROM ETLW_KG.Doc WHERE corpusRef = ? AND sourceKey = ?", corpusId, key)
    If ($Extract(id, 1, 5) '= "ERROR") && (id '= "") {
        Set cache(key) = id
        Return id
    }
    Set res = ##class(ETLWizard.Tools.Util).RunDML(
        "INSERT INTO ETLW_KG.Doc (corpusRef, sourceKey, sourceRowId, label, ingestedAt) VALUES (?,?,?,?,?)",
        corpusId, key, rowId, $Extract(label, 1, 1000), $ZDateTime($Horolog, 3))
    If $Extract(res, 1, 5) = "ERROR" {
        Return ""
    }
    Set id = ##class(ETLWizard.Tools.Util).ScalarQuery("SELECT TOP 1 %ID FROM ETLW_KG.Doc ORDER BY %ID DESC")
    Set cache(key) = id
    Return id
}

// ------------------------------------------------------------------- graph

/// LINK-KG extraction over the chunks just written.
ClassMethod ExtractInto(corpusId As %String, chunks As %DynamicArray) As %String [ Internal ]
{
    Try {
        Set known = ..KnownEntities(corpusId)
        Set iter = chunks.%GetIterator()
        Set n = 0
        While iter.%GetNext(, .chunk) {
            Set n = n + 1
            Do ..Mark(corpusId, "running", "extracting graph from chunk " _ n _ " of " _ chunks.%Size())
            Set result = ##class(ETLWizard.Agent.GraphExtract).Extract(chunk.text, chunk.label, known)
            If result.%Get("error", "") '= "" {
                Return result.error
            }
            Set err = ..StoreGraph(corpusId, chunk.id, result, .known)
            If err '= "" {
                Return err
            }
        }
        Return ""
    } Catch ex {
        Return ex.DisplayString()
    }
}

/// Canonical entity names already in this corpus - the LINK-KG registry.
ClassMethod KnownEntities(corpusId As %String) As %DynamicArray [ Internal ]
{
    Set out = []
    Set stmt = ##class(%SQL.Statement).%New()
    If $$$ISERR(stmt.%Prepare("SELECT TOP 50 entityName FROM ETLW_KG.Entity WHERE corpusRef = ? ORDER BY mentionCount DESC")) {
        Return out
    }
    Set rs = stmt.%Execute(corpusId)
    While rs.%Next() {
        Do out.%Push(rs.%GetData(1))
    }
    Return out
}

/// Persist one extraction result and update the registry.
ClassMethod StoreGraph(corpusId As %String, chunkId As %String, result As %DynamicObject, ByRef known As %DynamicArray) As %String [ Internal ]
{
    Try {
        Kill ids
        Set names = ","
        Set iter = result.entities.%GetIterator()
        While iter.%GetNext(, .e) {
            Set names = names _ $ZConvert(e.name, "U") _ ","
        }
        Set iter = result.entities.%GetIterator()
        While iter.%GetNext(, .e) {
            // An alias that is ANOTHER entity's canonical name would merge two
            // real things into one node. Drop it (wikigraph's guard).
            Set aliases = []
            Set aIter = e.aliases.%GetIterator()
            While aIter.%GetNext(, .a) {
                If names [ ("," _ $ZConvert(a, "U") _ ",") {
                    Continue
                }
                Do aliases.%Push(a)
            }
            Set entityId = ..UpsertEntity(corpusId, e.name, e.type, e.description, aliases)
            If entityId = "" {
                Continue
            }
            Set ids($ZConvert(e.name, "U")) = entityId
            Do ##class(ETLWizard.Tools.Util).RunDML(
                "INSERT INTO ETLW_KG.Mention (corpusRef, entityRef, chunkRef) VALUES (?,?,?)",
                corpusId, entityId, chunkId)
            Do ##class(ETLWizard.Tools.Util).RunDML(
                "UPDATE ETLW_KG.Entity SET mentionCount = COALESCE(mentionCount,0) + 1 WHERE %ID = ?", entityId)
            If known.%Size() < 50 {
                Do known.%Push(e.name)
            }
        }
        Set rIter = result.relationships.%GetIterator()
        While rIter.%GetNext(, .r) {
            // Models routinely name a target that is not one of the entities
            // they listed ("refund"). An edge to a node that does not exist is
            // not a fact, it is a dangling pointer - drop it.
            Set src = $Get(ids($ZConvert(r.source, "U")))
            Set tgt = $Get(ids($ZConvert(r.target, "U")))
            If (src = "") || (tgt = "") {
                Continue
            }
            Do ##class(ETLWizard.Tools.Util).RunDML(
                "INSERT INTO ETLW_KG.Relationship (corpusRef, sourceEntityRef, targetEntityRef, predicate, description, chunkRef) " _
                "VALUES (?,?,?,?,?,?)",
                corpusId, src, tgt, r.predicate, r.description, chunkId)
        }
        Return ""
    } Catch ex {
        Return ex.DisplayString()
    }
}

/// Entity identity is the canonical NAME within a corpus - never the model's
/// free-text type, which varies between chunks for the same thing.
ClassMethod UpsertEntity(corpusId As %String, name As %String, type As %String, description As %String, aliases As %DynamicArray) As %String [ Internal ]
{
    Set existing = ##class(ETLWizard.Tools.Util).ScalarQuery(
        "SELECT TOP 1 %ID FROM ETLW_KG.Entity WHERE corpusRef = ? AND entityName = ?", corpusId, name)
    If ($Extract(existing, 1, 5) '= "ERROR") && (existing '= "") {
        If aliases.%Size() > 0 {
            Do ##class(ETLWizard.Tools.Util).RunDML(
                "UPDATE ETLW_KG.Entity SET aliases = ? WHERE %ID = ?", aliases.%ToJSON(), existing)
        }
        Return existing
    }
    // The description is what entity-scoped retrieval matches a question
    // against, so it is embedded like a chunk. An entity with no description
    // gets its name embedded instead - a null vector would never match.
    Set toEmbed = $Select($ZStrip(description, "<>W") = "": name, 1: name _ " - " _ description)
    Set err = ##class(ETLWizard.KG.Embedder).EmbedOne(toEmbed, .vector)
    If err '= "" {
        Return ""
    }
    Set res = ##class(ETLWizard.Tools.Util).RunDML(
        "INSERT INTO ETLW_KG.Entity (corpusRef, entityName, entityType, description, aliases, mentionCount, descVector) " _
        "VALUES (?,?,?,?,?,0,TO_VECTOR(?, " _ ##class(ETLWizard.KG.Setup).#EMBEDTYPE _ ", " _
        ##class(ETLWizard.KG.Setup).#EMBEDDIMS _ "))",
        corpusId, name, type, description, $Select(aliases.%Size() > 0: aliases.%ToJSON(), 1: ""), vector)
    If $Extract(res, 1, 5) = "ERROR" {
        Return ""
    }
    Return ##class(ETLWizard.Tools.Util).ScalarQuery("SELECT TOP 1 %ID FROM ETLW_KG.Entity ORDER BY %ID DESC")
}

// ------------------------------------------------------------------ status

ClassMethod Mark(corpusId As %String, status As %String, detail As %String) [ Internal ]
{
    Do ##class(ETLWizard.Tools.Util).RunDML(
        "UPDATE ETLW_KG.Corpus SET status = ?, statusDetail = ? WHERE %ID = ?",
        status, $Extract(detail, 1, 1000), corpusId)
}

ClassMethod Finish(corpusId As %String, status As %String, detail As %String) [ Internal ]
{
    Do ##class(ETLWizard.Tools.Util).RunDML(
        "UPDATE ETLW_KG.Corpus SET status = ?, statusDetail = ?, finishedAt = ? WHERE %ID = ?",
        status, $Extract(detail, 1, 1000), $ZDateTime($Horolog, 3), corpusId)
}

ClassMethod Advance(corpusId As %String, lastRowId As %String, rowsDone As %Integer, chunksDone As %Integer) [ Internal ]
{
    Do ##class(ETLWizard.Tools.Util).RunDML(
        "UPDATE ETLW_KG.Corpus SET lastRowId = ?, rowsIngested = COALESCE(rowsIngested,0) + ?, " _
        "chunksIngested = COALESCE(chunksIngested,0) + ? WHERE %ID = ?",
        lastRowId, rowsDone, chunksDone, corpusId)
}

ClassMethod Cancel(corpusId As %String) As %DynamicObject
{
    Do ..Finish(corpusId, "cancelled", "stopped by the user")
    Return ..Status(corpusId)
}

ClassMethod Exists(corpusId As %String) As %Boolean [ Internal ]
{
    Return +##class(ETLWizard.Tools.Util).ScalarQuery("SELECT COUNT(*) FROM ETLW_KG.Corpus WHERE %ID = ?", corpusId) > 0
}

/// The corpus row as an object, or {"error"}.
ClassMethod Corpus(corpusId As %String) As %DynamicObject [ Internal ]
{
    Set stmt = ##class(%SQL.Statement).%New()
    Set stmt.%SelectMode = 1
    Set sc = stmt.%Prepare("SELECT %ID, name, sourceTable, textColumn, labelColumn, keyColumns, " _
        "rowsRequested, rowsIngested, chunksIngested, chunkChars, extractGraph, status, statusDetail, " _
        "autoRefresh, refreshCap, keyMode, lastRowId, lastSeenAt, chatModel, startedAt, finishedAt " _
        "FROM ETLW_KG.Corpus WHERE %ID = ?")
    If $$$ISERR(sc) {
        Return {"error": ($System.Status.GetErrorText(sc))}
    }
    Set rs = stmt.%Execute(corpusId)
    If 'rs.%Next() {
        Return {"error": "not found"}
    }
    Return {"id": (rs.%GetData(1)), "name": (rs.%GetData(2)), "sourceTable": (rs.%GetData(3)),
            "textColumn": (rs.%GetData(4)), "labelColumn": (rs.%GetData(5)), "keyColumns": (rs.%GetData(6)),
            "rowsRequested": (+rs.%GetData(7)), "rowsIngested": (+rs.%GetData(8)),
            "chunksIngested": (+rs.%GetData(9)), "chunkChars": (+rs.%GetData(10)),
            "extractGraph": (+rs.%GetData(11)), "status": (rs.%GetData(12)), "statusDetail": (rs.%GetData(13)),
            "autoRefresh": (+rs.%GetData(14)), "refreshCap": (+rs.%GetData(15)), "keyMode": (rs.%GetData(16)),
            "lastRowId": (+rs.%GetData(17)), "lastSeenAt": (rs.%GetData(18)), "extractModel": (rs.%GetData(19)),
            "startedAt": (rs.%GetData(20)), "finishedAt": (rs.%GetData(21))}
}

/// Corpus plus live graph counts - what the tab polls.
ClassMethod Status(corpusId As %String) As %DynamicObject
{
    Set c = ..Corpus(corpusId)
    If c.%Get("error", "") '= "" {
        Return c
    }
    Set c.entities = +##class(ETLWizard.Tools.Util).ScalarQuery(
        "SELECT COUNT(*) FROM ETLW_KG.Entity WHERE corpusRef = ?", corpusId)
    Set c.relationships = +##class(ETLWizard.Tools.Util).ScalarQuery(
        "SELECT COUNT(*) FROM ETLW_KG.Relationship WHERE corpusRef = ?", corpusId)
    Set c.docs = +##class(ETLWizard.Tools.Util).ScalarQuery(
        "SELECT COUNT(*) FROM ETLW_KG.Doc WHERE corpusRef = ?", corpusId)
    Set c.done = ''((c.status = "complete") || (c.status = "failed") || (c.status = "cancelled"))
    Return c
}

ClassMethod List() As %DynamicArray
{
    Set out = []
    Set stmt = ##class(%SQL.Statement).%New()
    If $$$ISERR(stmt.%Prepare("SELECT %ID FROM ETLW_KG.Corpus ORDER BY %ID DESC")) {
        Return out
    }
    Set rs = stmt.%Execute()
    While rs.%Next() {
        Do out.%Push(..Status(rs.%GetData(1)))
    }
    Return out
}

/// Vector search over one corpus. The query shape is deliberate: TOP N with
/// ORDER BY score DESC is what activates the HNSW index - without the ORDER BY
/// the optimizer full-scans and computes a cosine for every row. Correct
/// answers, wrong performance, no error anywhere.
ClassMethod Search(corpusId As %String, question As %String, topN As %Integer = 8) As %DynamicObject
{
    Try {
        If $ZStrip(question, "<>W") = "" {
            Return {"error": "ask something"}
        }
        If (topN < 1) || (topN > 50) {
            Set topN = 8
        }
        Set err = ##class(ETLWizard.KG.Embedder).EmbedOne(question, .vector)
        If err '= "" {
            Return {"error": (err)}
        }
        Set type = ##class(ETLWizard.KG.Setup).#EMBEDTYPE
        Set dims = ##class(ETLWizard.KG.Setup).#EMBEDDIMS
        Set stmt = ##class(%SQL.Statement).%New()
        // ODBC mode. VECTOR_COSINE returns a DOUBLE, and in the default LOGICAL
        // mode that arrives as its raw internal form - a cosine of 0.5569 reads
        // back as 55686169862747193344. Same class of trap as the %TimeStamp
        // watermark this project was bitten by.
        Set stmt.%SelectMode = 1
        Set sc = stmt.%Prepare("SELECT TOP " _ topN _ " c.chunkText, d.label, d.sourceKey, " _
            "VECTOR_COSINE(c.chunkVector, TO_VECTOR(?, " _ type _ ", " _ dims _ ")) AS score " _
            "FROM ETLW_KG.Chunk c JOIN ETLW_KG.Doc d ON c.docRef = d.%ID " _
            "WHERE c.corpusRef = ? ORDER BY score DESC")
        If $$$ISERR(sc) {
            Return {"error": ($System.Status.GetErrorText(sc))}
        }
        Set rs = stmt.%Execute(vector, corpusId)
        Set hits = []
        While rs.%Next() {
            Do hits.%Push({"text": (rs.%GetData(1)), "label": (rs.%GetData(2)),
                           "key": (rs.%GetData(3)), "score": (##class(ETLWizard.KG.Setup).Round(rs.%GetData(4), 4))})
        }
        Return {"question": (question), "corpusId": (corpusId), "hits": (hits)}
    } Catch ex {
        Return {"error": (ex.DisplayString())}
    }
}

/// The constellation: entities as nodes, relationships as edges, capped.
/// wikigraph returns everything, which is fine for one article and is not fine
/// for a table - so the cap is real and the caller is told what was trimmed.
ClassMethod Graph(corpusId As %String, limit As %Integer = 200) As %DynamicObject
{
    Try {
        If (limit < 1) || (limit > 1000) {
            Set limit = 200
        }
        Set total = +##class(ETLWizard.Tools.Util).ScalarQuery(
            "SELECT COUNT(*) FROM ETLW_KG.Entity WHERE corpusRef = ?", corpusId)
        Set nodes = [], keep = ","
        Set stmt = ##class(%SQL.Statement).%New()
        Set sc = stmt.%Prepare("SELECT TOP " _ limit _ " %ID, entityName, entityType, description, " _
            "COALESCE(mentionCount,0) FROM ETLW_KG.Entity WHERE corpusRef = ? ORDER BY mentionCount DESC")
        If $$$ISERR(sc) {
            Return {"error": ($System.Status.GetErrorText(sc))}
        }
        Set rs = stmt.%Execute(corpusId)
        While rs.%Next() {
            Set id = rs.%GetData(1)
            Set keep = keep _ id _ ","
            Do nodes.%Push({"id": (+id), "name": (rs.%GetData(2)), "type": (rs.%GetData(3)),
                            "description": (rs.%GetData(4)), "mentions": (+rs.%GetData(5))})
        }
        // ONE line per pair of entities. The extractor happily emits several
        // relationships between the same two things ("has", "has quality",
        // "provides"), and drawn together they are coincident lines with their
        // predicate labels stacked on top of each other - unreadable, and the
        // second label tells the reader nothing the first did not. The first is
        // kept, the rest are counted so the pane can say they exist.
        Set links = [], seenPair = "", hidden = 0
        Set stmt2 = ##class(%SQL.Statement).%New()
        // The macro argument must not span lines - the preprocessor rejects it
        // with "Macro referenced without correct principal".
        Set sc2 = stmt2.%Prepare("SELECT sourceEntityRef, targetEntityRef, predicate FROM ETLW_KG.Relationship " _
            "WHERE corpusRef = ? AND sourceEntityRef IS NOT NULL AND targetEntityRef IS NOT NULL")
        If $$$ISOK(sc2) {
            Set rs2 = stmt2.%Execute(corpusId)
            While rs2.%Next() {
                Set src = rs2.%GetData(1), tgt = rs2.%GetData(2)
                // an edge to a trimmed node would render as a node that is not
                // there; drop it rather than let the renderer invent one
                If (keep '[ ("," _ src _ ",")) || (keep '[ ("," _ tgt _ ",")) {
                    Continue
                }
                // unordered: A->B and B->A occupy the same line on screen
                Set pair = $Select(+src < +tgt: src _ "-" _ tgt, 1: tgt _ "-" _ src)
                If seenPair [ ("," _ pair _ ",") {
                    Set hidden = hidden + 1
                    Continue
                }
                Set seenPair = seenPair _ "," _ pair _ ","
                Do links.%Push({"source": (+src), "target": (+tgt), "predicate": (rs2.%GetData(3))})
            }
        }
        Return {"nodes": (nodes), "links": (links), "total": (total),
                "shown": (nodes.%Size()), "trimmed": (total - nodes.%Size()),
                "linksHidden": (hidden)}
    } Catch ex {
        Return {"error": (ex.DisplayString())}
    }
}

/// Delete every knowledge base. Called by Clear all: a button that says it
/// deletes every table the wizard built must not leave vectors and a graph
/// behind, pointing at tables that no longer exist. Those would keep answering
/// questions from data that has been deleted.
ClassMethod DropAll() As %Integer
{
    // Take the PARENT of the per-corpus locks: in IRIS an exclusive lock on
    // ^ETLWizard.KGLock conflicts with ^ETLWizard.KGLock(id), so this waits for
    // any batch in flight and blocks the next one.
    //
    // Without it the delete races an extraction still running in a JOB, which
    // then writes entities into a corpus that no longer exists. Observed: the
    // entity count went 1 -> 5 AFTER a clear, all for the deleted corpus.
    Lock +^ETLWizard.KGLock:10
    If '$Test {
        Return -1
    }
    Set n = +##class(ETLWizard.Tools.Util).ScalarQuery("SELECT COUNT(*) FROM ETLW_KG.Corpus")
    For table = "Ask", "Mention", "Relationship", "Entity", "Chunk", "Doc", "Corpus" {
        Do ##class(ETLWizard.Tools.Util).RunDML("DELETE FROM ETLW_KG." _ table)
    }
    Lock -^ETLWizard.KGLock
    Return n
}

/// Delete a corpus and everything under it.
ClassMethod Drop(corpusId As %String) As %DynamicObject
{
    // Same reasoning as DropAll: a batch mid-flight would re-populate what this
    // deletes, and the UI would show a knowledge base it had just removed.
    Lock +^ETLWizard.KGLock(corpusId):10
    If '$Test {
        Return {"error": "this knowledge base is being ingested right now - stop it first"}
    }
    Try {
        For table = "Ask", "Mention", "Relationship", "Entity", "Chunk", "Doc" {
            Do ##class(ETLWizard.Tools.Util).RunDML("DELETE FROM ETLW_KG." _ table _ " WHERE corpusRef = ?", corpusId)
        }
        Do ##class(ETLWizard.Tools.Util).RunDML("DELETE FROM ETLW_KG.Corpus WHERE %ID = ?", corpusId)
        Lock -^ETLWizard.KGLock(corpusId)
        Return {"dropped": (corpusId)}
    } Catch ex {
        Lock -^ETLWizard.KGLock(corpusId)
        Return {"error": (ex.DisplayString())}
    }
}

}
