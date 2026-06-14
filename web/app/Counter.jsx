// A small React component — function component + hook + JSX — rendered onto a
// ComputerCraft monitor by the wasmcraft web engine. This is ordinary React
// code; the build step (tools/build-web) bundles it with React into app.js,
// which the engine runs through QuickJS-in-wasm.
import React, { useState } from "react";

export function Counter() {
  const [n] = useState(3);
  return (
    <div>
      <h1 style={{ color: "lime", textAlign: "center" }}>React on ComputerCraft</h1>
      <p>
        Count is <strong style={{ color: "cyan" }}>{n}</strong>.
      </p>
      <ul>
        <li>function components</li>
        <li>hooks (useState)</li>
        <li>JSX</li>
      </ul>
      <p style={{ color: "gray" }}>
        Rendered by React + a custom reconciler, inside QuickJS, inside wasm.
      </p>
    </div>
  );
}
