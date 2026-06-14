// Entry point: mount a React tree onto the wasmcraft DOM using a custom
// react-reconciler host config. We deliberately do NOT use react-dom — the
// engine exposes a small DOM (createElement/createTextNode/appendChild/
// insertBefore/removeChild/setAttribute/textContent/style), and this host config
// maps React's host operations straight onto it. That keeps React itself
// unchanged ("real React") while targeting a surface the size of a CC monitor.
import React from "react";
import Reconciler from "react-reconciler";
import { Counter } from "./Counter.jsx";

function applyProps(el, props) {
  for (const k in props) {
    if (k === "children") continue;                 // handled via text/host children
    if (k === "style" && props[k]) {
      for (const s in props[k]) el.style[s] = props[k][s];
    } else if (k === "className") {
      el.setAttribute("class", String(props[k]));
    } else if (k.slice(0, 2) === "on") {
      // event props are accepted now; wired to CC events in a later stage
    } else if (props[k] != null) {
      el.setAttribute(k, String(props[k]));
    }
  }
  // a single string/number child is set as text (see shouldSetTextContent)
  const c = props.children;
  if (typeof c === "string" || typeof c === "number") el.textContent = String(c);
}

const hostConfig = {
  supportsMutation: true,
  isPrimaryRenderer: true,
  noTimeout: -1,
  now: Date.now,
  getRootHostContext: () => ({}),
  getChildHostContext: () => ({}),
  prepareForCommit: () => null,
  resetAfterCommit: () => {},
  shouldSetTextContent: (type, props) =>
    typeof props.children === "string" || typeof props.children === "number",
  createInstance(type, props) {
    const el = document.createElement(type);
    applyProps(el, props);
    return el;
  },
  createTextInstance(text) {
    return document.createTextNode(text);
  },
  appendInitialChild: (parent, child) => parent.appendChild(child),
  appendChild: (parent, child) => parent.appendChild(child),
  appendChildToContainer: (container, child) => container.appendChild(child),
  insertBefore: (parent, child, before) => parent.insertBefore(child, before),
  insertInContainerBefore: (container, child, before) => container.insertBefore(child, before),
  removeChild: (parent, child) => parent.removeChild(child),
  removeChildFromContainer: (container, child) => container.removeChild(child),
  finalizeInitialChildren: () => false,
  prepareUpdate: () => true,
  commitUpdate: (instance, _payload, _type, _old, props) => applyProps(instance, props),
  commitTextUpdate: (textInstance, _old, text) => {
    textInstance.nodeValue = text;
  },
  clearContainer: () => {},
  getPublicInstance: (i) => i,
  preparePortalMount: () => {},
  detachDeletedInstance: () => {},
  scheduleTimeout: (fn) => fn(),
  cancelTimeout: () => {},
  // react-reconciler 0.29 calls these during commit; provide inert defaults
  getCurrentEventPriority: () => 0b0000000000000000000000000010000, // DefaultEventPriority
  getInstanceFromNode: () => null,
  beforeActiveInstanceBlur: () => {},
  afterActiveInstanceBlur: () => {},
  prepareScopeUpdate: () => {},
  getInstanceFromScope: () => null,
};

const reconciler = Reconciler(hostConfig);
const root = document.getElementById("root");
const container = reconciler.createContainer(
  root, 0, null, false, null, "", (e) => console.log("recoverable", e + ""), null
);
reconciler.updateContainer(React.createElement(Counter), container, null, null);
