/**
 * dsh-gui-control — Windows desktop control for DeepSeek Harness.
 *
 * The heavy lifting lives in a long-lived PowerShell daemon shipped under lib/scripts.
 * It compiles the Win32/UIA helpers once and then serves operations over loopback TCP,
 * so a click costs ~10 ms instead of the ~700 ms of starting PowerShell and recompiling.
 *
 * This module only exposes three model-facing tools and keeps the surface small on
 * purpose: read, act, or run a declarative task.
 */
import { execFileSync } from 'node:child_process';
import { existsSync } from 'node:fs';
import net from 'node:net';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { defineTool } from '@deepseek-ai/dsh-tools';

const HERE = dirname(fileURLToPath(import.meta.url));
const SCRIPTS = join(HERE, 'scripts');
const PORT = 38471;
const HOST = '127.0.0.1';

const isWindows = process.platform === 'win32';

/** Resolve PowerShell explicitly: the host process PATH is not guaranteed to include it. */
const POWERSHELL = (() => {
	const systemRoot = process.env.SystemRoot ?? process.env.windir ?? 'C:\\Windows';
	const full = join(systemRoot, 'System32', 'WindowsPowerShell', 'v1.0', 'powershell.exe');
	return existsSync(full) ? full : 'powershell.exe';
})();

let launchPromise = null;

function text(value) {
	return [{ type: 'text', text: typeof value === 'string' ? value : JSON.stringify(value) }];
}

function assertWindows() {
	if (!isWindows) {
		throw new Error('dsh-gui-control only works on Windows; the native helpers are Win32 and UI Automation based.');
	}
}

function pingDaemon(timeoutMs = 400) {
	return new Promise((resolve) => {
		const socket = net.createConnection({ host: HOST, port: PORT });
		const done = (ok) => {
			socket.removeAllListeners();
			socket.destroy();
			resolve(ok);
		};
		socket.setTimeout(timeoutMs);
		socket.once('connect', () => done(true));
		socket.once('timeout', () => done(false));
		socket.once('error', () => done(false));
	});
}

/** Start the daemon once per process; concurrent callers share one launch. */
function ensureDaemon() {
	if (launchPromise !== null) return launchPromise;
	launchPromise = (async () => {
		if (await pingDaemon()) return;
		// Launch through Start-Process: a bare detached spawn of PowerShell can exit
		// immediately on Windows depending on console inheritance from the host.
		const daemon = join(SCRIPTS, 'gui-daemon.ps1');
		const quote = (value) => `'${String(value).replace(/'/g, "''")}'`;
		const args = ['-NoProfile', '-STA', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', daemon, '-Port', String(PORT)];
		const command = `Start-Process -FilePath ${quote(POWERSHELL)} -ArgumentList @(${args.map(quote).join(',')}) -WindowStyle Hidden`;
		try {
			execFileSync(POWERSHELL, ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command', command], { stdio: 'ignore', timeout: 15000, windowsHide: true });
		} catch (error) {
			launchPromise = null;
			throw new Error(`Could not launch the GUI daemon: ${error.message}`);
		}
		for (let i = 0; i < 120; i += 1) {
			await new Promise((r) => setTimeout(r, 100));
			if (await pingDaemon()) return;
		}
		launchPromise = null;
		throw new Error('The GUI daemon did not start. Check that PowerShell 5.1 is available and see lib/scripts/gui-daemon.log.');
	})();
	return launchPromise;
}

/** One request, one response line. Resolves with the daemon envelope. */
function callDaemon(op, timeoutMs = 20000) {
	return new Promise((resolve, reject) => {
		const socket = net.createConnection({ host: HOST, port: PORT });
		let buffer = '';
		let settled = false;
		const finish = (fn, value) => {
			if (settled) return;
			settled = true;
			socket.destroy();
			fn(value);
		};
		socket.setEncoding('utf8');
		socket.setTimeout(timeoutMs);
		socket.once('connect', () => socket.write(`${JSON.stringify(op)}\n`));
		socket.on('data', (chunk) => {
			buffer += chunk;
			const nl = buffer.indexOf('\n');
			if (nl === -1) return;
			const line = buffer.slice(0, nl);
			try {
				finish(resolve, JSON.parse(line));
			} catch (error) {
				finish(reject, new Error(`Bad daemon response: ${line.slice(0, 200)}`));
			}
		});
		socket.once('timeout', () => finish(reject, new Error(`GUI operation timed out after ${timeoutMs} ms (${op.op}).`)));
		socket.once('error', (error) => finish(reject, error));
	});
}

/** Call, and if the daemon died since the last call, relaunch it once and retry. */
async function callResilient(op, timeoutMs) {
	await ensureDaemon();
	try {
		return await callDaemon(op, timeoutMs);
	} catch (error) {
		const code = error?.code;
		if (code !== 'ECONNREFUSED' && code !== 'EPIPE' && code !== 'ECONNRESET') throw error;
		launchPromise = null;
		await ensureDaemon();
		return callDaemon(op, timeoutMs);
	}
}

async function run(op, timeoutMs) {
	const envelope = await callResilient(op, timeoutMs);
	if (envelope.ok !== true) {
		const parts = [String(envelope.error ?? 'operation failed')];
		if (envelope.delivery !== undefined) parts.push(`delivery=${envelope.delivery}`);
		if (envelope.retry !== undefined) parts.push(`retry=${envelope.retry}`);
		throw new Error(parts.join('  '));
	}
	return envelope.result;
}

/** Compact tree read: one line per control, deduped, no rectangles. */
function formatTree(lines) {
	if (!Array.isArray(lines) || lines.length === 0) return '(no controls)';
	return lines.join('\n');
}

function actOp(args) {
	const action = String(args.action ?? '').toLowerCase();
	const base = {};
	if (typeof args.window === 'string' && args.window.length > 0) base.win = args.window;
	if (Number.isFinite(args.x) && Number.isFinite(args.y)) {
		base.x = Math.round(args.x);
		base.y = Math.round(args.y);
	}
	switch (action) {
		case 'click':
		case 'double_click':
		case 'right_click': {
			const out = { op: 'click', ...base };
			if (action === 'double_click') out.count = 2;
			if (action === 'right_click') out.button = 'right';
			return out;
		}
		case 'type':
			return { op: 'type', ...base, text: String(args.text ?? '') };
		case 'key':
			return { op: 'key', ...base, key: String(args.key ?? '') };
		case 'hotkey':
			return { op: 'hotkey', ...base, key: String(args.key ?? '') };
		case 'scroll':
			return { op: 'scroll', ...base, amount: Number(args.amount ?? -3) };
		case 'focus':
			return { op: 'activate', win: String(args.window ?? '') };
		case 'click_text': {
			// Semantic click: locate the control by name instead of by coordinate.
			return { op: 'uia-click', win: String(args.window ?? ''), text: String(args.text ?? ''), type: args.controlType };
		}
		default:
			throw new Error(`Unknown action "${action}". Use click, double_click, right_click, type, key, hotkey, scroll, focus, or click_text.`);
	}
}

const SNAPSHOT = {
	name: 'gui_snapshot',
	description: [
		'Read a Windows window as text: its accessibility tree (control names, roles, bounds-free) or a cropped screenshot with a coordinate ruler.',
		'Use the tree first — it is exact, cheap, and position independent. Fall back to a screenshot only when the window publishes no tree (a canvas, a game, or a self-drawn list).',
		'Always snapshot before acting, and again afterwards to confirm what changed.',
		'A screenshot is returned as a file path; read that file with the image reader. The ruler labels are screen coordinates, so you can pass them straight back to gui_act.',
	].join(' '),
	parameters: {
		window: { type: 'string', description: 'Window title or process-name substring, case-insensitive (for example "Notepad" or "计算器").' },
		mode: { type: 'string', enum: ['tree', 'shot'], description: 'tree (default): control names as text. shot: PNG with a screen-coordinate ruler.' },
		lines: { type: 'number', description: 'Maximum control lines to return (default 40, tree mode only).' },
		chars: { type: 'number', description: 'Truncate each control name to this many characters (default 60, tree mode only).' },
		region: { type: 'string', description: "Screenshot crop in screen pixels as 'x,y,width,height' (shot mode). Defaults to the whole window." },
	},
	output: {
		schema: { type: 'string' },
		render: (_args, value) => text(value),
	},
	isConcurrencySafe: () => true,
	async execute(args) {
		assertWindows();
		const window = typeof args.window === 'string' ? args.window : '';
		if (window.length === 0) throw new Error('gui_snapshot needs a window (title or process substring).');
		const mode = args.mode === 'shot' ? 'shot' : 'tree';
		if (mode === 'tree') {
			const lines = await run({ op: 'uia-mini', win: window, lines: args.lines ?? 40, chars: args.chars ?? 60 });
			return formatTree(lines);
		}
		const op = { op: 'shot', win: window, rulers: true, path: join(tmpdir(), `gui-shot-${Date.now()}.png`) };
		if (typeof args.region === 'string' && args.region.length > 0) {
			const nums = args.region.split(',').map((v) => Number(v.trim()));
			if (nums.length === 4 && nums.every((n) => Number.isFinite(n))) {
				[op.x, op.y, op.w, op.h] = nums;
			}
		}
		const shot = await run(op);
		return `shot ${shot.w}x${shot.h} at ${shot.x},${shot.y} scale ${shot.scale}\n${shot.path}\nRead the file to see it. Ruler labels are screen coordinates.`;
	},
	presentCall(args) {
		return { card: 'generic', title: `Snapshot ${args.window ?? 'window'}`, kind: 'read' };
	},
};

const ACT = {
	name: 'gui_act',
	description: [
		'Perform ONE desktop action and optionally verify its effect.',
		'Prefer click_text over click with coordinates: it addresses the control by name, so the mouse does not move and a window layout change cannot make it hit the wrong thing.',
		'Every action reports a delivery verdict. "not_delivered" means nothing was sent and a retry is safe; "delivered_unverified" means the input may have landed, so repeating it risks a duplicate — verify first, never blind-retry.',
		'For more than two steps use gui_task instead: one call, conditions, and a single failure report.',
	].join(' '),
	parameters: {
		action: {
			type: 'string',
			enum: ['click', 'double_click', 'right_click', 'type', 'key', 'hotkey', 'scroll', 'focus', 'click_text'],
			description: 'click_text = click the control whose name matches text (recommended). key/hotkey take a key name such as enter or ctrl+s. focus brings a window to the front.',
		},
		window: { type: 'string', description: 'Target window (title or process substring). Required for click_text, focus, click, type, and key.' },
		text: { type: 'string', description: 'Text to type, or the control name for click_text.' },
		x: { type: 'number', description: 'Screen x for click/double_click/right_click (use only when no control name exists).' },
		y: { type: 'number', description: 'Screen y for click/double_click/right_click.' },
		key: { type: 'string', description: "Key or chord: 'enter', 'tab', 'esc', 'f5', 'ctrl+s', 'alt+tab'." },
		amount: { type: 'number', description: 'Scroll notches; negative scrolls down (default -3).' },
		controlType: { type: 'string', description: 'Optional control type filter for click_text, for example Button or TabItem.' },
		verifyText: { type: 'string', description: 'After acting, poll until this text appears in the window (proves the action landed).' },
		verifyTimeout: { type: 'number', description: 'Seconds to poll for verifyText (default 4).' },
	},
	output: {
		schema: { type: 'string' },
		render: (_args, value) => text(value),
	},
	isConcurrencySafe: () => false,
	async execute(args) {
		assertWindows();
		const op = actOp(args);
		const envelope = await callResilient(op);
		if (envelope.ok !== true) {
			const parts = [String(envelope.error ?? 'action failed')];
			if (envelope.delivery !== undefined) parts.push(`delivery=${envelope.delivery}`);
			if (envelope.retry !== undefined) parts.push(`retry=${envelope.retry}`);
			throw new Error(parts.join('  '));
		}
		let verified = 'unverified';
		if (typeof args.verifyText === 'string' && args.verifyText.length > 0) {
			verified = await verifyText(args.window, args.verifyText, (args.verifyTimeout ?? 4) * 1000);
		}
		const how = envelope.result?.how !== undefined ? ` via ${envelope.result.how}` : '';
		return `${op.op} ok${how}${verified === 'ok' ? ' | verified: text appeared' : ''}${verified === 'timeout' ? ' | delivery=delivered_unverified: text never appeared, do NOT blind-retry' : ''}`;
	},
	presentCall(args) {
		return { card: 'generic', title: `${args.action ?? 'act'} ${args.window ?? ''}`.trim(), kind: 'execute' };
	},
};

async function verifyText(window, needle, timeoutMs) {
	const deadline = Date.now() + timeoutMs;
	while (Date.now() < deadline) {
		try {
			const envelope = await callResilient({ op: 'uia-get', win: String(window ?? ''), text: needle }, 5000);
			if (envelope.ok === true) return 'ok';
		} catch {
			// keep polling
		}
		await new Promise((r) => setTimeout(r, 200));
	}
	return 'timeout';
}

const TASK = {
	name: 'gui_task',
	description: [
		'Run a declarative task file: an ordered list of desktop steps executed inside the daemon, with no model in the loop.',
		'Each step names an operation plus its parameters and may add "until" (a condition polled until it holds), "untilTimeout", "retry", and "risk".',
		'A task returns per-step timing and a delivery verdict, so one call replaces a long back-and-forth of single actions.',
		'Pass dryRun to see the plan without touching the desktop. Steps marked risk "high" are refused unless confirm is true.',
		'Example step: { "do": "uia-click", "win": "Calculator", "text": "7", "until": { "op": "uia-get", "win": "Calculator", "text": "Display is 7" } }',
	].join(' '),
	parameters: {
		file: { type: 'string', description: 'Absolute path to the task JSON file.' },
		dryRun: { type: 'boolean', description: 'Return the step plan without executing anything.' },
		confirm: { type: 'boolean', description: 'Allow steps marked risk high (otherwise they are refused before dispatch).' },
	},
	output: {
		schema: { type: 'string' },
		render: (_args, value) => text(value),
	},
	isConcurrencySafe: () => false,
	async execute(args) {
		assertWindows();
		const file = typeof args.file === 'string' ? args.file : '';
		if (file.length === 0) throw new Error('gui_task needs file (absolute path to a task JSON).');
		const op = { op: 'task', file, dryRun: args.dryRun === true, confirm: args.confirm === true };
		const envelope = await callResilient(op, 600000);
		const result = envelope.result ?? {};
		if (result.dryRun === true) {
			const plan = (result.steps ?? []).map((step) => `${String(step.n).padStart(2)}. ${String(step.do).padEnd(10)} risk=${step.risk ?? 'low'}`);
			return [`task ${result.name ?? ''} plan (dry run, nothing executed)`, ...plan].join('\n');
		}
		const lines = [];
		for (const step of result.steps ?? []) {
			const flag = step.ok ? 'ok  ' : 'FAIL';
			const extra = step.note ? ` ${step.note}` : '';
			lines.push(`${String(step.n).padStart(2)}. ${flag} ${String(step.do).padEnd(10)} ${String(step.ms).padStart(6)} ms  ${step.delivery ?? ''}${extra}`.trimEnd());
		}
		const head = envelope.ok === true
			? `task ${result.name ?? ''} ok in ${result.total ?? '?'} ms`
			: `task failed: ${envelope.error}${envelope.delivery ? `  delivery=${envelope.delivery}` : ''}${envelope.retry ? `  retry=${envelope.retry}` : ''}`;
		return [head, ...lines].join('\n');
	},
	presentCall(args) {
		return { card: 'generic', title: `Run task ${String(args.file ?? '').split(/[\\/]/).pop() ?? ''}`, kind: 'execute' };
	},
};

export const inject = ['tools'];

export function apply(ctx) {
	ctx.effect(() => ctx.tools.register(defineTool(SNAPSHOT)));
	ctx.effect(() => ctx.tools.register(defineTool(ACT)));
	ctx.effect(() => ctx.tools.register(defineTool(TASK)));
}
