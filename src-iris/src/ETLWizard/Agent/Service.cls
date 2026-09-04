/// Bridge between the REST layer and the agent: one wizard chat turn.
/// Keeps all %AI.* calls out of ETLWizard.API (spec §4.1 EAP caveat).
Class ETLWizard.Agent.Service Extends %RegisteredObject
{

/// Run one chat turn for a wizard run. The user text and the agent reply are
/// appended to the event log, so the canvas/chat panel render them from the
/// same replayable stream as everything else.
/// P0 NOTE: a fresh session per turn. Persisted %AI.Agent.Session reload
/// (Load(sessionId, provider)) + per-step checkpoints land in P1 (spec §4.1).
ClassMethod ChatTurn(runId As %String, text As %String) As %Status
{
    Set sc = $$$OK
    Try {
        Do ##class(ETLWizard.Model.Event).Append(runId, "agent.note", "",
            {"role": "user", "text": (text)})

        Set agent = ##class(ETLWizard.Agent.Architect).%New()
        Set sc = agent.%Init()
        If $$$ISERR(sc) {
            Do ##class(ETLWizard.Model.Event).Append(runId, "run.error", "",
                {"error": ("agent init failed: " _ $System.Status.GetErrorText(sc)),
                 "hint": "Run ##class(ETLWizard.Setup).ConfigureLocalProfile() or ConfigureCloudProfile() first"})
            Return sc
        }

        Set session = agent.CreateSession()
        // Tools need the runId; the INSTRUCTIONS tell the model to pass it through.
        Set response = agent.Chat(session, "[runId=" _ runId _ "] " _ text)

        Do ##class(ETLWizard.Model.Event).Append(runId, "agent.note", "",
            {"role": "assistant", "text": (response.Content)})
    } Catch ex {
        Set sc = ex.AsStatus()
        Do ##class(ETLWizard.Model.Event).Append(runId, "run.error", "",
            {"error": ($System.Status.GetErrorText(sc))})
    }
    Return sc
}

}
