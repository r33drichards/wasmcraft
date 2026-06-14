// An INTERACTIVE React component rendered on a ComputerCraft monitor. Tapping a
// button fires a real DOM click event (routed from CC's monitor_touch through
// the engine), React updates state, and the page re-renders — all inside
// QuickJS-in-wasm. Ordinary React: function component, hook, JSX, onClick.
import React, { useState } from "react";

export function Counter() {
  const [n, setN] = useState(0);
  return (
    <div>
      <h1 style={{ color: "lime", textAlign: "center" }}>React Counter</h1>
      <p>
        Count: <strong style={{ color: "cyan" }}>{n}</strong>
      </p>
      <button onClick={() => setN(n + 1)} style={{ background: "green", color: "white" }}>
        [ + increment ]
      </button>
      <button onClick={() => setN(n - 1)} style={{ background: "red", color: "white" }}>
        [ - decrement ]
      </button>
      <p style={{ color: "gray" }}>Tap a button on the monitor.</p>
    </div>
  );
}
