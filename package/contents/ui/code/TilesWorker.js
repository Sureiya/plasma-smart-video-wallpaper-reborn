/*
 * TilesWorker.js — WorkerScript that offloads the expensive masonry packing
 * (packLayout) to a separate thread, so the UI thread never stalls rebuilding a
 * choreography graph at the end of a cycle.
 *
 * Protocol (messages are plain JSON-serializable objects):
 *
 *   main -> worker  { type: "build", graphId, seed, screenW, screenH, videos,
 *                     mergeDurationMs, style, transformCountBeforeFull, choreographyMode }
 *   worker -> main  { type: "built", graphId, winnerIndex, totalSteps, totalPhases,
 *                     chunkSize, phases: [ ...first chunk... ] }
 *
 *   main -> worker  { type: "chunk", graphId }
 *   worker -> main  { type: "chunk", graphId, phases: [ ... ] }        // more phases
 *                   { type: "chunk", graphId, done: true }             // no more
 *
 * The worker keeps one in-flight plan per graphId. Deterministic by construction:
 * the same seed + inputs yield the same phases as the main-thread buildGraph, so
 * the offloaded result is byte-for-byte identical to the synchronous path.
 */
// Pull in the pure graph functions (mulberry32, packLayout, buildGraphPlan,
// materializePlanStep) at the top level. Qt.include evaluates the shared file in
// this worker's global scope, so the functions are directly callable by name.
Qt.include("TilesLayout.js");

const CHUNK_SIZE = 16;

// Live plans keyed by graphId: { plan, cursor, prevTiles }
const plans = {};

WorkerScript.onMessage = function (msg) {
  if (!msg || typeof msg.type !== "string") return;

  if (msg.type === "build") {
    if (msg.debug && typeof setProfilingEnabled === "function") {
      setProfilingEnabled(true);
    }
    const plan = buildGraphPlan(
      msg.seed, msg.screenW, msg.screenH, msg.videos,
      msg.mergeDurationMs, msg.style, msg.transformCountBeforeFull, msg.choreographyMode,
      msg.heroSecondaryMode, msg.mazeSize
    );
    plans[msg.graphId] = { plan, cursor: 0, prevTiles: null };

    // Materialize the first chunk.
    const phases = [];
    const end = Math.min(plan.totalSteps, CHUNK_SIZE);
    for (let si = 0; si < end; si++) {
      const step = materializePlanStep(plan, si, plans[msg.graphId].prevTiles);
      plans[msg.graphId].prevTiles = step.tiles;
      for (const p of step.phases) phases.push(p);
    }
    plans[msg.graphId].cursor = end;

    WorkerScript.sendMessage({
      type: "built",
      graphId: msg.graphId,
      winnerIndex: plan.winnerIndex,
      totalSteps: plan.totalSteps,
      totalPhases: plan.totalPhases,
      chunkSize: CHUNK_SIZE,
      phases: phases,
    });
    return;
  }

  if (msg.type === "chunk") {
    const rec = plans[msg.graphId];
    if (!rec) {
      WorkerScript.sendMessage({ type: "chunk", graphId: msg.graphId, done: true });
      return;
    }
    if (rec.cursor >= rec.plan.totalSteps) {
      // Cycle finished; release the plan to bound memory.
      delete plans[msg.graphId];
      WorkerScript.sendMessage({ type: "chunk", graphId: msg.graphId, done: true });
      return;
    }
    const phases = [];
    const end = Math.min(rec.plan.totalSteps, rec.cursor + CHUNK_SIZE);
    for (let si = rec.cursor; si < end; si++) {
      const step = materializePlanStep(rec.plan, si, rec.prevTiles);
      rec.prevTiles = step.tiles;
      for (const p of step.phases) phases.push(p);
    }
    rec.cursor = end;
    const finished = rec.cursor >= rec.plan.totalSteps;
    if (finished) delete plans[msg.graphId];
    WorkerScript.sendMessage({ type: "chunk", graphId: msg.graphId, phases: phases, done: finished });
    return;
  }
};
