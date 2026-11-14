package hub

import (
	"encoding/json"
	"strings"
	"testing"
)

// The relay forwards opaque frames. It must not copy their payload into its
// JSON logs while doing so: those logs go to the operator host and would turn
// a transport into a content store.
func TestFramePayloadDoesNotEnterRelayLogs(t *testing.T) {
	fixture, buffer := newHubLogFixture(t, Options{Limits: DefaultLimits()})
	owner := fixture.newTenant("opacity-mac")
	device := fixture.pairDevice(owner, "opacity-phone")
	_, agentSink := fixture.attachAgent(owner)
	link, _ := fixture.mustAttachDevice(device)
	waitFrame(t, agentSink, "deviceAttach", isKind("deviceAttach"))

	marker := "opaque-payload-marker-7f3c"
	fixture.hub.RouteFromDevice(link, scanWire(t, `{"t":"futureFrame","id":"f1","value":{"text":"`+marker+`"}}`))
	waitFrame(t, agentSink, "opaque frame", isKind("futureFrame"))

	for _, entry := range buffer.entries(t) {
		encoded, err := json.Marshal(entry)
		if err != nil {
			t.Fatalf("marshal log entry: %v", err)
		}
		if strings.Contains(string(encoded), marker) {
			t.Fatalf("relay log contains frame payload: %s", encoded)
		}
	}
}
