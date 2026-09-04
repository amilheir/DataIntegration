Include %cspInclude

/// WebSocket event fan-out per run (spec §5, §14.1).
/// Protocol: on connect the client sends {"runId":"...","lastSeq":0}; the hub
/// replays persisted events with Seq > lastSeq, then switches to live push.
/// The canvas is a pure projection of the persisted ETLWizard.Model.Event log,
/// so a reconnecting client is always consistent (spec §23.3).
///
/// P0 note: live push is poll-based over the event table (the persisted log IS
/// the bus). Interprocess signalling can replace the poll later without any
/// protocol change.
Class ETLWizard.WS.Hub Extends %CSP.WebSocket
{

/// Run this socket is subscribed to
Property RunId As %String;

/// Replay/live cursor — last Seq pushed to this client
Property LastSeq As %Integer [ InitialExpression = 0 ];

Method OnPreServer() As %Status
{
    Set ..SharedConnection = 0
    Return $$$OK
}

Method Server() As %Status
{
    Set sc = $$$OK
    Try {
        // First frame: subscription {"runId":"...","lastSeq":n}
        Set data = ..Read(.size, .sc, 30)
        If $$$ISERR(sc) {
            Do ..EndServer()
            Return $$$OK
        }
        Set sub = {}
        Try {
            Set sub = ##class(%DynamicObject).%FromJSON(data)
        } Catch {
            Do ..Write({"type":"error","error":"invalid subscription JSON"}.%ToJSON())
            Do ..EndServer()
            Return $$$OK
        }
        Set ..RunId = sub.runId
        Set ..LastSeq = +sub.lastSeq

        Set run = ##class(ETLWizard.Model.Run).%OpenId(..RunId)
        If '$IsObject(run) {
            Do ..Write({"type":"error","error":("run not found: " _ ..RunId)}.%ToJSON())
            Do ..EndServer()
            Return $$$OK
        }

        Do ..Write({"type":"subscribed","runId":(..RunId),"lastSeq":(..LastSeq)}.%ToJSON())

        // Replay + live loop: push anything newer than the cursor, then use a
        // short Read timeout as the poll tick. Client frames are optional
        // ({"type":"ack"} keep-alives are ignored).
        For {
            Do ..PushPending()
            Set data = ..Read(.size, .sc, 1)
            If $$$ISERR(sc) {
                If $$$GETERRORCODE(sc) = $$$CSPWebSocketClosed {
                    Quit
                }
                If $$$GETERRORCODE(sc) '= $$$CSPWebSocketTimeout {
                    Quit
                }
                // timeout: normal poll tick
            }
        }
        Do ..EndServer()
    } Catch ex {
        Set sc = ex.AsStatus()
        Try {
            Do ..EndServer()
        } Catch {
        }
    }
    Return $$$OK
}

/// Push all persisted events for RunId with Seq > LastSeq, in order.
Method PushPending() As %Status
{
    Set sc = $$$OK
    Try {
        Set stmt = ##class(%SQL.Statement).%New()
        Set sc = stmt.%Prepare("SELECT ID FROM ETLWizard_Model.Event WHERE Run = ? AND Seq > ? ORDER BY Seq")
        If $$$ISERR(sc) {
            Return sc
        }
        Set rs = stmt.%Execute(..RunId, ..LastSeq)
        If rs.%SQLCODE < 0 {
            Return $$$ERROR($$$GeneralError, "event query failed: SQLCODE " _ rs.%SQLCODE)
        }
        While rs.%Next() {
            Set ev = ##class(ETLWizard.Model.Event).%OpenId(rs.ID)
            If '$IsObject(ev) {
                Continue
            }
            Do ..Write(ev.ToJSON().%ToJSON())
            Set ..LastSeq = ev.Seq
        }
    } Catch ex {
        Set sc = ex.AsStatus()
    }
    Return sc
}

}
