Include %occStatus

/// Grounded question-answering over an embedded corpus
/// (mds/knowledge-graph-tab-plan.md §9).
///
/// Asynchronous by necessity, the same way SqlGen is: the chat model answers in
/// tens of seconds and the webgateway gives up at ~60. Ask() writes a row and
/// JOBs the work; the UI polls. That also gives the chat its live status line
/// ("searching" -> "answering") for free, because the status IS the row.
///
/// Retrieval is deliberately simpler than wikigraph's: vector search over the
/// corpus, plus any entity whose name literally appears in the question, plus a
/// one-hop relationship expansion. wikigraph's entity-scoped narrowing
/// (scopeMargin/scopeFloor) is NOT ported, because its thresholds were tuned on
/// article paragraphs and the scores here bunch into 0.45-0.63 - a nonsense
/// question scores as high as a good one, so an absolute floor would cut real
/// answers and admit nonsense equally.
Class ETLWizard.KG.Chat Extends %RegisteredObject
{

/// Chunks handed to the model as context.
Parameter MAXCHUNKS = 10;

/// Relationship facts appended to the context.
Parameter MAXFACTS = 20;

/// Queue a question. Returns {"id": n, "status": "pending"} immediately.
ClassMethod Ask(corpusId As %String, question As %String) As %DynamicObject
{
    Try {
        Set question = $ZStrip(question, "<>W")
        If question = "" {
            Return {"error": "ask something"}
        }
        If corpusId = "" {
            Return {"error": "pick which embedded data to ask about"}
        }
        Set res = ##class(ETLWizard.Tools.Util).RunDML(
            "INSERT INTO ETLW_KG.Ask (corpusRef, question, status, statusDetail, createdAt) " _
            "VALUES (?,?,'pending','queued',?)",
            corpusId, $Extract(question, 1, 2000), $ZDateTime($Horolog, 3))
        If $Extract(res, 1, 5) = "ERROR" {
            Return {"error": (res)}
        }
        Set id = ##class(ETLWizard.Tools.Util).ScalarQuery("SELECT TOP 1 %ID FROM ETLW_KG.Ask ORDER BY %ID DESC")
        Job ##class(ETLWizard.KG.Chat).Run(id)::5
        If '$Test {
            Do ..Mark(id, "error", "could not start the answering job")
        }
        Return ..Poll(id)
    } Catch ex {
        Return {"error": (ex.DisplayString())}
    }
}

/// Job entry point. Never throws out: a failure has to land in the row, or the
/// UI polls a "searching" status forever.
ClassMethod Run(askId As %String)
{
    Try {
        Set row = ..Row(askId)
        If row.%Get("error", "") '= "" {
            Quit
        }
        Do ..Mark(askId, "searching", "finding the relevant records")
        Set ctx = ..Retrieve(row.corpusRef, row.question, .ctxErr)
        If ctxErr '= "" {
            Do ..Mark(askId, "error", ctxErr)
            Quit
        }
        If ctx.chunks.%Size() = 0 {
            Do ..Finish(askId, "There is nothing embedded in this knowledge base yet, so I have nothing to answer from.", ctx)
            Quit
        }
        Do ..Mark(askId, "answering", "writing the answer")
        Set answer = ..Generate(row.question, ctx, .genErr)
        If genErr '= "" {
            Do ..Mark(askId, "error", genErr)
            Quit
        }
        Do ..Finish(askId, answer, ctx)
    } Catch ex {
        Do ..Mark(askId, "error", ex.DisplayString())
    }
    Quit
}

/// Chunks by vector similarity, entities named in the question, and one hop of
/// relationships out from those entities.
ClassMethod Retrieve(corpusId As %String, question As %String, Output err As %String) As %DynamicObject [ Internal ]
{
    Set err = ""
    Set out = {"chunks": [], "entities": [], "facts": []}
    Try {
        Set err = ##class(ETLWizard.KG.Embedder).EmbedOne(question, .vector)
        If err '= "" {
            Return out
        }
        Set type = ##class(ETLWizard.KG.Setup).#EMBEDTYPE
        Set dims = ##class(ETLWizard.KG.Setup).#EMBEDDIMS

        Set stmt = ##class(%SQL.Statement).%New()
        // ODBC mode - VECTOR_COSINE is a DOUBLE and reads back as its raw
        // internal form in the default logical mode.
        Set stmt.%SelectMode = 1
        Set sc = stmt.%Prepare("SELECT TOP " _ ..#MAXCHUNKS _ " c.chunkText, d.label, " _
            "VECTOR_COSINE(c.chunkVector, TO_VECTOR(?, " _ type _ ", " _ dims _ ")) AS score " _
            "FROM ETLW_KG.Chunk c JOIN ETLW_KG.Doc d ON c.docRef = d.%ID " _
            "WHERE c.corpusRef = ? ORDER BY score DESC")
        If $$$ISERR(sc) {
            Set err = $System.Status.GetErrorText(sc)
            Return out
        }
        Set rs = stmt.%Execute(vector, corpusId)
        Set seen = ","
        While rs.%Next() {
            Set text = rs.%GetData(1)
            // The source table can hold the same row twice; two identical
            // chunks in a ten-chunk context waste a slot and tell the model
            // nothing new.
            If seen [ ("," _ $ZConvert(text, "U") _ ",") {
                Continue
            }
            Set seen = seen _ $ZConvert(text, "U") _ ","
            Do out.chunks.%Push({"text": (text), "label": (rs.%GetData(2)),
                                 "score": (##class(ETLWizard.KG.Setup).Round(rs.%GetData(3), 4))})
        }

        // Entities named outright in the question. Cheap, and it rescues the
        // case where a name embeds weakly but is stated word for word.
        Set upperQ = $ZConvert(question, "U")
        Set stmt2 = ##class(%SQL.Statement).%New()
        Set sc2 = stmt2.%Prepare("SELECT %ID, entityName, entityType, description FROM ETLW_KG.Entity WHERE corpusRef = ?")
        If $$$ISOK(sc2) {
            Set rs2 = stmt2.%Execute(corpusId)
            Set hitIds = ","
            While rs2.%Next() {
                Set name = rs2.%GetData(2)
                If (name = "") || (upperQ '[ $ZConvert(name, "U")) {
                    Continue
                }
                Set hitIds = hitIds _ rs2.%GetData(1) _ ","
                Do out.entities.%Push({"name": (name), "type": (rs2.%GetData(3)),
                                       "description": (rs2.%GetData(4))})
            }
            If hitIds '= "," {
                Do ..AddFacts(corpusId, hitIds, out)
            }
        }
    } Catch ex {
        Set err = ex.DisplayString()
    }
    Return out
}

/// One hop out: relationships touching any matched entity, as readable triples.
ClassMethod AddFacts(corpusId As %String, hitIds As %String, ctx As %DynamicObject) [ Internal ]
{
    Set stmt = ##class(%SQL.Statement).%New()
    Set sc = stmt.%Prepare("SELECT TOP " _ ..#MAXFACTS _ " s.entityName, r.predicate, t.entityName " _
        "FROM ETLW_KG.Relationship r " _
        "JOIN ETLW_KG.Entity s ON r.sourceEntityRef = s.%ID " _
        "JOIN ETLW_KG.Entity t ON r.targetEntityRef = t.%ID " _
        "WHERE r.corpusRef = ?")
    If $$$ISERR(sc) {
        Quit
    }
    Set rs = stmt.%Execute(corpusId)
    While rs.%Next() {
        Do ctx.facts.%Push(rs.%GetData(1) _ " " _ rs.%GetData(2) _ " " _ rs.%GetData(3))
    }
    Quit
}

/// Ask the chat model, grounded in the retrieved context.
ClassMethod Generate(question As %String, ctx As %DynamicObject, Output err As %String) As %String [ Internal ]
{
    Set err = ""
    Try {
        Set sc = ##class(ETLWizard.Agent.ProviderFactory).GetProviderForConfig("ETLWizard", .provider, .model)
        If $$$ISERR(sc) {
            Set err = "no LLM profile (AI.LLM.ETLWizard): " _ $System.Status.GetErrorText(sc)
            Return ""
        }
        Set agent = ##class(%AI.Agent).%New(provider)
        // The CHAT model, not the extraction model - they are separate roles
        // and cannot be GPU-resident together.
        Set model = ##class(ETLWizard.KG.Setup).GetChatModel()
        If model '= "" {
            Set agent.Model = model
        }
        Set nl = $Char(10)
        Set p = "Answer the question using ONLY the records below." _ nl _
            "If they do not contain the answer, say so plainly - do not guess." _ nl _
            "Be brief. Refer to the records by their label where it helps." _ nl _ nl _ "RECORDS" _ nl
        Set iter = ctx.chunks.%GetIterator()
        While iter.%GetNext(, .c) {
            Set p = p _ "- " _ $Select(c.label = "": "", 1: "[" _ c.label _ "] ") _ c.text _ nl
        }
        If ctx.facts.%Size() > 0 {
            Set p = p _ nl _ "KNOWN FACTS" _ nl
            Set fIter = ctx.facts.%GetIterator()
            While fIter.%GetNext(, .f) {
                Set p = p _ "- " _ f _ nl
            }
        }
        Set p = p _ nl _ "QUESTION: " _ question _ nl
        Set session = agent.CreateSession()
        Set response = agent.Chat(session, p)
        Set answer = $Select($IsObject(response): response.Content, 1: "")
        If $ZStrip(answer, "<>W") = "" {
            Set err = "the model returned an empty answer"
            Return ""
        }
        // some small models emit a hidden reasoning preamble
        If answer [ "</think>" {
            Set answer = $Piece(answer, "</think>", 2, *)
        }
        Return $ZStrip(answer, "<>W")
    } Catch ex {
        Set err = ex.DisplayString()
        Return ""
    }
}

// ------------------------------------------------------------------ state

ClassMethod Mark(askId As %String, status As %String, detail As %String) [ Internal ]
{
    Do ##class(ETLWizard.Tools.Util).RunDML(
        "UPDATE ETLW_KG.Ask SET status = ?, statusDetail = ?, updatedAt = ? WHERE %ID = ?",
        status, $Extract(detail, 1, 1000), $ZDateTime($Horolog, 3), askId)
}

ClassMethod Finish(askId As %String, answer As %String, ctx As %DynamicObject) [ Internal ]
{
    Do ##class(ETLWizard.Tools.Util).RunDML(
        "UPDATE ETLW_KG.Ask SET status = 'done', statusDetail = 'answered', answer = ?, hits = ?, updatedAt = ? WHERE %ID = ?",
        $Extract(answer, 1, 30000), $Extract(ctx.%ToJSON(), 1, 30000), $ZDateTime($Horolog, 3), askId)
}

ClassMethod Row(askId As %String) As %DynamicObject [ Internal ]
{
    Set stmt = ##class(%SQL.Statement).%New()
    Set stmt.%SelectMode = 1
    Set sc = stmt.%Prepare("SELECT %ID, corpusRef, question, status, statusDetail, answer, hits FROM ETLW_KG.Ask WHERE %ID = ?")
    If $$$ISERR(sc) {
        Return {"error": ($System.Status.GetErrorText(sc))}
    }
    Set rs = stmt.%Execute(askId)
    If 'rs.%Next() {
        Return {"error": "not found"}
    }
    Return {"id": (rs.%GetData(1)), "corpusRef": (rs.%GetData(2)), "question": (rs.%GetData(3)),
            "status": (rs.%GetData(4)), "statusDetail": (rs.%GetData(5)),
            "answer": (rs.%GetData(6)), "hitsJson": (rs.%GetData(7))}
}

/// What the UI polls.
ClassMethod Poll(askId As %String) As %DynamicObject
{
    Set row = ..Row(askId)
    If row.%Get("error", "") '= "" {
        Return row
    }
    Set row.done = ''((row.status = "done") || (row.status = "error"))
    Try {
        If row.hitsJson '= "" {
            Set row.hits = ##class(%DynamicAbstractObject).%FromJSON(row.hitsJson)
        }
    } Catch {
    }
    Do row.%Remove("hitsJson")
    Return row
}

}
