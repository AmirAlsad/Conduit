import { ConsoleTemplate, ThemeProvider } from "@pipecat-ai/voice-ui-kit";
import { useState } from "react";

/**
 * Standalone web harness for the Conduit engine.
 *
 * Paste the JSON payload returned by `POST /connect` or `POST /credentials`,
 * then connect. The Voice UI Kit Console shows the RTVI speaking-state glow,
 * transcripts, and an event log — the dev's verification harness before iOS.
 *
 * Daily only: there is no official Pipecat JS LiveKit client transport yet, so
 * LiveKit payloads can't be driven here. For LiveKit, use meet.livekit.io or the
 * LiveKit Agents Playground with the url + token from the payload.
 */

interface Payload {
  transport: "daily" | "livekit";
  connection: {
    room_url?: string;
    token?: string;
    url?: string;
    room_name?: string;
  };
  agent_id: string;
}

export default function App() {
  const [payload, setPayload] = useState<Payload | null>(null);
  const [raw, setRaw] = useState("");
  const [error, setError] = useState("");

  if (payload && payload.transport === "daily") {
    return (
      <ThemeProvider>
        <ConsoleTemplate
          transportType="daily"
          connectParams={{
            dailyUrl: payload.connection.room_url!,
            token: payload.connection.token!,
          }}
          noUserVideo
          titleText={`Conduit — ${payload.agent_id}`}
        />
      </ThemeProvider>
    );
  }

  if (payload && payload.transport !== "daily") {
    return (
      <div style={panel}>
        <p>
          This web client supports Daily only. For a LiveKit payload, connect with{" "}
          <a href="https://meet.livekit.io" target="_blank" rel="noreferrer">
            meet.livekit.io
          </a>{" "}
          or the LiveKit Agents Playground using <code>url</code> +{" "}
          <code>token</code> from the payload.
        </p>
        <button onClick={() => setPayload(null)}>Back</button>
      </div>
    );
  }

  return (
    <div style={panel}>
      <h2>Conduit web test client</h2>
      <p>
        Paste the JSON from <code>POST /connect</code> or{" "}
        <code>POST /credentials</code>:
      </p>
      <textarea
        value={raw}
        onChange={(e) => setRaw(e.target.value)}
        rows={10}
        style={{ width: "100%", fontFamily: "monospace" }}
        placeholder='{"transport":"daily","connection":{"room_url":"...","token":"..."},"agent_id":"loopback","expires_at":null}'
      />
      {error && <p style={{ color: "crimson" }}>{error}</p>}
      <button
        onClick={() => {
          try {
            setPayload(JSON.parse(raw) as Payload);
            setError("");
          } catch (e) {
            setError(`Invalid JSON: ${(e as Error).message}`);
          }
        }}
      >
        Connect
      </button>
    </div>
  );
}

const panel: React.CSSProperties = {
  maxWidth: 640,
  margin: "60px auto",
  padding: 24,
  fontFamily: "system-ui, sans-serif",
};
