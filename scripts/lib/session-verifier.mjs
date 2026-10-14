// Verifies a governed run as OpenBox stored it: event order, Started/Completed pairing by
// activity_id, span started/completed pairing by span_id, span classification and attributes.
// Works on the rows returned by the platform's chronological session log.

const WORKFLOW_TERMINALS = new Set(['WorkflowCompleted', 'WorkflowFailed']);

function spansOf(row) {
  return Array.isArray(row.spans) ? row.spans : [];
}

function spanField(span, key) {
  return span[key] ?? span.data?.[key];
}

/**
 * @param rows chronological session log rows
 * @param options.expectOpen true when the run is legitimately waiting for an approval
 * @param options.expectHalt true when the run was halted (Core accepts nothing after a halt)
 * @returns {{ ok: boolean, problems: string[], summary: object }}
 */
const VERDICTS = ['allow', 'constrain', 'require_approval', 'block', 'halt'];

/** Verdict as a word: Core stores it as a name or as its index (0 allow ... 4 halt). */
export function verdictName(verdict) {
  if (verdict === null || verdict === undefined || verdict === '') return '';
  const index = Number(verdict);
  return Number.isInteger(index) && VERDICTS[index] ? VERDICTS[index] : String(verdict).toLowerCase();
}

export function verifySession(rows, { expectOpen = false, expectHalt = false } = {}) {
  const problems = [];
  const events = rows.map((row) => row.event_type);

  const workflowStarts = rows.filter((row) => row.event_type === 'WorkflowStarted');
  const terminals = rows.filter((row) => WORKFLOW_TERMINALS.has(row.event_type));
  if (workflowStarts.length !== 1) problems.push(`expected exactly 1 WorkflowStarted, found ${workflowStarts.length}`);
  if (rows[0]?.event_type !== 'WorkflowStarted')
    problems.push(`first event is ${rows[0]?.event_type}, not WorkflowStarted`);
  if (expectOpen) {
    if (terminals.length !== 0) problems.push('a run awaiting approval must not be closed');
  } else if (expectHalt) {
    // Core closes a halted session and does not record the terminal event the client still sends.
    if (terminals.length > 1) problems.push(`expected at most 1 terminal workflow event, found ${terminals.length}`);
    const haltAt = rows.findIndex((row) => verdictName(row.verdict ?? row.action) === 'halt');
    const after = rows.slice(haltAt + 1).filter((row) => !WORKFLOW_TERMINALS.has(row.event_type));
    if (haltAt < 0) problems.push('no event carries the halt verdict');
    else if (after.length) problems.push(`${after.length} event(s) recorded after the halt`);
  } else if (terminals.length !== 1) {
    problems.push(`expected exactly 1 terminal workflow event, found ${terminals.length}`);
  } else if (rows[rows.length - 1] !== terminals[0]) {
    problems.push('the terminal workflow event is not the last event');
  }

  const started = new Map();
  const completed = new Map();
  for (const row of rows) {
    if (row.event_type === 'ActivityStarted') started.set(row.activity_id, (started.get(row.activity_id) ?? 0) + 1);
    if (row.event_type === 'ActivityCompleted')
      completed.set(row.activity_id, (completed.get(row.activity_id) ?? 0) + 1);
  }
  for (const [activityId, count] of started) {
    if (count !== 1) problems.push(`activity ${activityId} has ${count} ActivityStarted rows`);
    const closes = completed.get(activityId) ?? 0;
    const tolerated = expectOpen || expectHalt;
    if (closes === 0 && !tolerated) problems.push(`activity ${activityId} was never completed`);
    if (closes > 1) problems.push(`activity ${activityId} completed ${closes} times`);
  }
  for (const activityId of completed.keys()) {
    if (!started.has(activityId)) problems.push(`ActivityCompleted ${activityId} has no ActivityStarted`);
  }

  const spanStages = new Map();
  const spanList = [];
  for (const row of rows) {
    for (const span of spansOf(row)) {
      const spanId = spanField(span, 'span_id');
      const stage = spanField(span, 'stage');
      spanList.push({ row, span, spanId, stage });
      if (!spanStages.has(spanId)) spanStages.set(spanId, []);
      spanStages.get(spanId).push(stage);
    }
  }
  for (const [spanId, stages] of spanStages) {
    const pairedInOrder = stages.length === 2 && stages[0] === 'started' && stages[1] === 'completed';
    if (!pairedInOrder && !expectHalt)
      problems.push(`span ${spanId} stages ${JSON.stringify(stages)} (want ["started","completed"])`);
  }
  for (const { span, spanId } of spanList) {
    const name = spanField(span, 'name') ?? '';
    const semantic = span.span_type ?? spanField(span, 'semantic_type');
    const verb = name.split(' ')[0];
    const expected = { SELECT: 'database_select', UPDATE: 'database_update' }[verb];
    if (expected && semantic && semantic !== expected)
      problems.push(`span ${spanId} "${name}" classified ${semantic}, want ${expected}`);
    const attributes = span.attributes ?? spanField(span, 'attributes') ?? {};
    if (!attributes['db.system']) problems.push(`span ${spanId} lacks attribute db.system`);
    if (!attributes['db.statement']) problems.push(`span ${spanId} lacks attribute db.statement`);
  }

  return {
    ok: problems.length === 0,
    problems,
    summary: {
      events,
      activities: started.size,
      spans: spanStages.size,
      spanRows: spanList.length,
      verdicts: rows.map((row) => `${row.event_type}:${row.verdict ?? row.action ?? ''}`),
    },
  };
}

/** Human-readable tree of a session log. */
export function renderSession(rows) {
  const lines = [];
  for (const row of rows) {
    const verdict = verdictName(row.verdict ?? row.action);
    lines.push(
      `${row.event_type.padEnd(18)} ${String(row.activity_type ?? '').padEnd(28)} verdict=${verdict} id=${String(row.activity_id ?? '').slice(0, 13)}`,
    );
    for (const span of spansOf(row)) {
      const semantic = span.span_type ?? spanField(span, 'semantic_type') ?? '?';
      const status = spanField(span, 'status')?.code ?? (span.error ? 'ERROR' : '');
      lines.push(
        `    span ${String(spanField(span, 'name')).padEnd(22)} ${String(spanField(span, 'stage')).padEnd(9)} ${semantic.padEnd(16)} ${status.padEnd(5)} span_id=${spanField(span, 'span_id')} verdict=${span.verdict ?? ''}`,
      );
    }
  }
  return lines.join('\n');
}
