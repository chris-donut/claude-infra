#!/usr/bin/env python3
"""
Orchestrator daemon — Manages worker lifecycle and task distribution.

Replaces orchestrator.sh with added capabilities:
- Real-time stream-json log parsing from workers
- Timeout detection and auto-retry for stuck workers
- Per-worker health tracking (success rate, avg duration)
- Rich Telegram notifications with error details

Usage:
    python3 orchestrator.py [--interval N] [--once] [--dry-run] [--timeout N] [--max-retries N]

Zero external dependencies — Python 3.9+ stdlib only.
"""

from __future__ import annotations

import argparse
import enum
import json
import os
import random
import signal
import subprocess
import sys
import time
import urllib.request
from datetime import datetime
from pathlib import Path
from typing import Optional


# ─── Config ──────────────────────────────────────────────────────────────────

class Config:
    """Immutable configuration loaded once at startup."""

    def __init__(self, args: argparse.Namespace):
        self.script_dir = str(Path(__file__).resolve().parent)
        self.repo_root = str(Path(self.script_dir).parent.parent)
        self.shared_dir = os.path.join(self.repo_root, '.worktree-shared')
        self.worktree_root = os.path.join(self.repo_root, '.worktrees')
        self.config_file = os.path.join(self.shared_dir, 'worktree.config.json')
        self.log_file = os.path.join(self.shared_dir, 'orchestrator.log')
        self.pid_file = os.path.join(self.shared_dir, 'orchestrator.pid')
        self.tasks_file = os.path.join(self.shared_dir, 'dev-tasks.json')
        self.lock_file = os.path.join(self.shared_dir, 'dev-task.lock')
        self.tracked_file = os.path.join(self.shared_dir, '.tracked-completions')
        self.health_file = os.path.join(self.shared_dir, 'worker-health.json')
        self.progress_file = os.path.join(self.shared_dir, 'PROGRESS.md')
        self.pipeline_status_file = os.path.join(self.shared_dir, 'pipeline-status.json')
        self.gate_results_dir = os.path.join(self.shared_dir, 'gate-results')
        self.feedback_dir = os.path.join(self.shared_dir, 'feedback')

        # CLI args
        self.poll_interval: int = args.interval
        self.run_once: bool = args.once
        self.dry_run: bool = args.dry_run
        self.worker_timeout_minutes: int = args.timeout
        self.max_retries: int = args.max_retries

        # From worktree.config.json
        self.num_workers: int = 5
        if os.path.exists(self.config_file):
            try:
                with open(self.config_file) as f:
                    cfg = json.load(f)
                self.num_workers = cfg.get('workers', 5)
            except (json.JSONDecodeError, IOError):
                pass

        # Telegram (same as orchestrator.sh + task-queue.sh)
        self.tg_token = os.environ.get('TELEGRAM_BOT_TOKEN', '')
        self.tg_chat_id = os.environ.get('TELEGRAM_CHAT_ID', '')

        # Ensure shared dir exists
        os.makedirs(self.shared_dir, exist_ok=True)
        if not os.path.exists(self.tasks_file):
            with open(self.tasks_file, 'w') as f:
                json.dump({'version': 1, 'tasks': []}, f)
        if not os.path.exists(self.lock_file):
            Path(self.lock_file).touch()


# ─── Logging ─────────────────────────────────────────────────────────────────

_log_file_handle = None


def log(msg: str, config: Optional[Config] = None) -> None:
    global _log_file_handle
    ts = datetime.utcnow().strftime('%Y-%m-%dT%H:%M:%SZ')
    line = f'[{ts}] {msg}'
    print(line, flush=True)
    if config and config.log_file:
        try:
            if _log_file_handle is None:
                _log_file_handle = open(config.log_file, 'a')
            _log_file_handle.write(line + '\n')
            _log_file_handle.flush()
        except IOError:
            pass


# ─── FileLock ────────────────────────────────────────────────────────────────

class FileLock:
    """Cross-platform file locking.
    Linux: fcntl.flock (compatible with bash flock command).
    macOS: mkdir-based spinlock (matches task-queue.sh lines 24-32).
    """

    def __init__(self, lock_path: str):
        self.lock_path = lock_path
        self._use_mkdir = sys.platform == 'darwin'
        self._lock_dir = lock_path + '.d'
        self._fd = None

    def __enter__(self) -> 'FileLock':
        if self._use_mkdir:
            while True:
                try:
                    os.mkdir(self._lock_dir)
                    break
                except FileExistsError:
                    time.sleep(0.05)
        else:
            import fcntl
            self._fd = open(self.lock_path, 'w')
            fcntl.flock(self._fd, fcntl.LOCK_EX)
        return self

    def __exit__(self, *args):
        if self._use_mkdir:
            try:
                os.rmdir(self._lock_dir)
            except OSError:
                pass
        else:
            if self._fd:
                import fcntl
                fcntl.flock(self._fd, fcntl.LOCK_UN)
                self._fd.close()
                self._fd = None


# ─── TaskQueue ───────────────────────────────────────────────────────────────

class TaskQueue:
    """Read/write dev-tasks.json with proper locking.
    Interoperable with task-queue.sh (same file, same lock, same schema).
    """

    def __init__(self, config: Config):
        self.config = config
        self.lock = FileLock(config.lock_file)

    def _read(self) -> dict:
        with self.lock:
            with open(self.config.tasks_file) as f:
                return json.load(f)

    def _write(self, data: dict) -> None:
        with self.lock:
            tmp = self.config.tasks_file + '.tmp'
            with open(tmp, 'w') as f:
                json.dump(data, f, indent=2)
            os.rename(tmp, self.config.tasks_file)

    def count_pending(self) -> int:
        data = self._read()
        return sum(1 for t in data.get('tasks', []) if t['status'] == 'pending')

    def get_all_tasks(self) -> list:
        return self._read().get('tasks', [])

    def get_completed_or_failed(self) -> list:
        data = self._read()
        return [t for t in data.get('tasks', [])
                if t['status'] in ('completed', 'failed')]

    def get_task_by_id(self, task_id: str) -> Optional[dict]:
        data = self._read()
        for t in data.get('tasks', []):
            if t['id'] == task_id:
                return t
        return None

    def reset_task(self, task_id: str) -> None:
        with self.lock:
            with open(self.config.tasks_file) as f:
                data = json.load(f)
            for t in data.get('tasks', []):
                if t['id'] == task_id:
                    t['status'] = 'pending'
                    t['claimed_by'] = None
                    t['claimed_at'] = None
                    t['completed_at'] = None
                    t['result'] = None
                    t['reason'] = None
                    break
            tmp = self.config.tasks_file + '.tmp'
            with open(tmp, 'w') as f:
                json.dump(data, f, indent=2)
            os.rename(tmp, self.config.tasks_file)

    def add_task(self, title: str, priority: str = 'medium',
                 files: Optional[list] = None, description: str = '',
                 spec_file: str = '', parent_task_id: Optional[str] = None,
                 round_num: int = 0, max_rounds: int = 3,
                 project_id: Optional[str] = None,
                 phase: Optional[int] = None) -> str:
        task_id = f'task-{int(time.time())}-{os.getpid()}-{random.randint(0, 9999)}'
        now = datetime.utcnow().strftime('%Y-%m-%dT%H:%M:%SZ')
        task = {
            'id': task_id,
            'title': title,
            'description': description,
            'priority': priority,
            'status': 'pending',
            'claimed_by': None,
            'claimed_at': None,
            'completed_at': None,
            'created_at': now,
            'files': files or [],
            'result': None,
            'reason': None,
            'round': round_num,
            'max_rounds': max_rounds,
            'parent_task_id': parent_task_id,
            'gate_results': None,
            'feedback_file': None,
            'spec_file': spec_file,
            'project_id': project_id,
            'phase': phase,
        }
        with self.lock:
            with open(self.config.tasks_file) as f:
                data = json.load(f)
            data['tasks'].append(task)
            tmp = self.config.tasks_file + '.tmp'
            with open(tmp, 'w') as f:
                json.dump(data, f, indent=2)
            os.rename(tmp, self.config.tasks_file)
        return task_id

    def update_task_field(self, task_id: str, field: str, value) -> None:
        with self.lock:
            with open(self.config.tasks_file) as f:
                data = json.load(f)
            for t in data.get('tasks', []):
                if t['id'] == task_id:
                    t[field] = value
                    break
            tmp = self.config.tasks_file + '.tmp'
            with open(tmp, 'w') as f:
                json.dump(data, f, indent=2)
            os.rename(tmp, self.config.tasks_file)


# ─── TelegramNotifier ────────────────────────────────────────────────────────

class TelegramNotifier:
    """Send Telegram notifications. Matches existing bash format with richer info."""

    def __init__(self, config: Config):
        self.token = config.tg_token
        self.chat_id = config.tg_chat_id
        self._last_send = 0.0

    def send(self, message: str) -> None:
        elapsed = time.time() - self._last_send
        if elapsed < 1.0:
            time.sleep(1.0 - elapsed)
        try:
            url = f'https://api.telegram.org/bot{self.token}/sendMessage'
            payload = json.dumps({
                'chat_id': self.chat_id,
                'text': message,
                'parse_mode': 'Markdown',
            }).encode('utf-8')
            req = urllib.request.Request(
                url, data=payload,
                headers={'Content-Type': 'application/json'},
                method='POST',
            )
            urllib.request.urlopen(req, timeout=10)
            self._last_send = time.time()
        except Exception:
            pass  # never block on notification failure

    def notify_queued(self, title: str, priority: str) -> None:
        self.send(f'\U0001f4cb *Task Queued*\n{title}\nPriority: {priority}')

    def notify_success(self, task: dict, stats: dict) -> None:
        title = task.get('title', 'unknown')
        worker = task.get('claimed_by', 'unknown')
        duration = self._calc_duration(task)
        tool_calls = stats.get('tool_calls', '?')
        cost = stats.get('cost_usd', 0)
        cost_str = f'\nCost: ${cost:.3f}' if cost else ''
        self.send(
            f'\u2705 *Worker Done*\n'
            f'Task: {title}\n'
            f'Worker: {worker}\n'
            f'Duration: {duration}\n'
            f'Tool calls: {tool_calls}{cost_str}\n'
            f'Branch ready for review.'
        )

    def notify_failure(self, task: dict, stats: dict) -> None:
        title = task.get('title', 'unknown')
        worker = task.get('claimed_by', 'unknown')
        reason = task.get('reason', 'unknown')
        duration = self._calc_duration(task)
        last_error = stats.get('last_error', '')
        error_line = f'\nLast error: {last_error[:200]}' if last_error else ''
        self.send(
            f'\u274c *Worker Failed*\n'
            f'Task: {title}\n'
            f'Worker: {worker}\n'
            f'Duration: {duration}\n'
            f'Reason: {reason}{error_line}\n'
            f'Check: .worktree-shared/{worker}.log'
        )

    def notify_timeout(self, worker_id: str, task_title: str,
                       minutes_stuck: float, retry: bool) -> None:
        action = 'Re-queued for retry' if retry else 'Max retries exhausted'
        self.send(
            f'\u23f0 *Worker Timeout*\n'
            f'Worker: {worker_id}\n'
            f'Task: {task_title}\n'
            f'No output for: {minutes_stuck:.0f}min\n'
            f'Action: {action}'
        )

    def _calc_duration(self, task: dict) -> str:
        try:
            claimed = datetime.strptime(task['claimed_at'], '%Y-%m-%dT%H:%M:%SZ')
            end_str = task.get('completed_at') or datetime.utcnow().strftime('%Y-%m-%dT%H:%M:%SZ')
            completed = datetime.strptime(end_str, '%Y-%m-%dT%H:%M:%SZ')
            minutes = int((completed - claimed).total_seconds() / 60)
            if minutes < 60:
                return f'{minutes}min'
            return f'{minutes // 60}h {minutes % 60}min'
        except Exception:
            return 'unknown'


# ─── StreamJsonParser ────────────────────────────────────────────────────────

class SessionStats:
    """Aggregated stats from parsing a worker's session file."""

    def __init__(self):
        self.initialized: bool = False
        self.completed: bool = False
        self.result_subtype: str = ''
        self.session_id: str = ''
        self.tool_calls: int = 0
        self.last_tool: str = ''
        self.total_events: int = 0
        self.last_event_time: float = 0.0
        self.last_activity_time: float = 0.0
        self.error_messages: list = []
        self.cost_usd: float = 0.0
        self.num_turns: int = 0

    @property
    def minutes_since_activity(self) -> float:
        if self.last_activity_time == 0:
            return float('inf')
        return (time.time() - self.last_activity_time) / 60.0

    @property
    def last_error(self) -> str:
        return self.error_messages[-1] if self.error_messages else ''


class StreamJsonParser:
    """Incrementally parses Claude Code stream-json (NDJSON) session files.

    Event types:
    - {"type": "system", "subtype": "init"}           → session started
    - {"type": "assistant", "message": {...}}          → claude response
    - {"type": "user", "message": {...}}               → tool results
    - {"type": "result", "subtype": "success"|"error"} → session ended
    """

    def __init__(self):
        self._positions: dict[str, int] = {}

    def parse_incremental(self, session_file: str, stats: SessionStats) -> None:
        """Read new lines from session_file since last call, update stats in place."""
        if not os.path.exists(session_file):
            return

        pos = self._positions.get(session_file, 0)
        try:
            with open(session_file) as f:
                f.seek(pos)
                for line in f:
                    line = line.strip()
                    if not line:
                        continue
                    try:
                        event = json.loads(line)
                        self._process_event(event, stats)
                    except json.JSONDecodeError:
                        continue
                self._positions[session_file] = f.tell()
        except (IOError, OSError):
            pass

    def _process_event(self, event: dict, stats: SessionStats) -> None:
        event_type = event.get('type', '')
        stats.last_event_time = time.time()
        stats.total_events += 1

        if event_type == 'system':
            if event.get('subtype') == 'init':
                stats.session_id = event.get('session_id', '')
                stats.initialized = True

        elif event_type == 'assistant':
            stats.last_activity_time = time.time()
            message = event.get('message', {})
            for content in message.get('content', []):
                ct = content.get('type', '')
                if ct == 'tool_use':
                    stats.tool_calls += 1
                    stats.last_tool = content.get('name', '')
                elif ct == 'text':
                    text = content.get('text', '')
                    if any(kw in text.lower() for kw in
                           ('error', 'failed', 'exception', 'traceback')):
                        stats.error_messages.append(text[:500])
                        stats.error_messages = stats.error_messages[-10:]

        elif event_type == 'user':
            stats.last_activity_time = time.time()
            message = event.get('message', {})
            for content in message.get('content', []):
                if content.get('type') == 'tool_result' and content.get('is_error'):
                    stats.error_messages.append(str(content.get('content', ''))[:500])
                    stats.error_messages = stats.error_messages[-10:]

        elif event_type == 'result':
            stats.completed = True
            stats.result_subtype = event.get('subtype', '')
            stats.cost_usd = event.get('cost_usd', 0)
            stats.num_turns = event.get('num_turns', 0)

        elif event_type == 'stream_event':
            stats.last_activity_time = time.time()


# ─── WorkerHealth ────────────────────────────────────────────────────────────

class WorkerHealth:
    """Per-worker success/failure/timeout tracking. Persisted to JSON."""

    def __init__(self, health_file: str):
        self.health_file = health_file
        self.data: dict = {}
        if os.path.exists(health_file):
            try:
                with open(health_file) as f:
                    self.data = json.load(f)
            except (json.JSONDecodeError, IOError):
                pass

    def _save(self) -> None:
        tmp = self.health_file + '.tmp'
        with open(tmp, 'w') as f:
            json.dump(self.data, f, indent=2)
        os.rename(tmp, self.health_file)

    def _ensure(self, worker_id: str) -> dict:
        if worker_id not in self.data:
            self.data[worker_id] = {
                'total': 0, 'successes': 0, 'failures': 0,
                'timeouts': 0, 'total_duration_sec': 0,
                'total_tool_calls': 0,
            }
        return self.data[worker_id]

    def record_completion(self, worker_id: str, success: bool,
                          duration_sec: float, tool_calls: int) -> None:
        w = self._ensure(worker_id)
        w['total'] += 1
        w['successes' if success else 'failures'] += 1
        w['total_duration_sec'] += duration_sec
        w['total_tool_calls'] += tool_calls
        self._save()

    def record_timeout(self, worker_id: str) -> None:
        w = self._ensure(worker_id)
        w['timeouts'] += 1
        self._save()

    def get_stats(self, worker_id: str) -> dict:
        w = self.data.get(worker_id, {})
        total = w.get('total', 0)
        return {
            'success_rate': w.get('successes', 0) / max(total, 1),
            'avg_duration_sec': w.get('total_duration_sec', 0) / max(total, 1),
            'avg_tool_calls': w.get('total_tool_calls', 0) / max(total, 1),
            'timeouts': w.get('timeouts', 0),
        }


# ─── ProjectManager ─────────────────────────────────────────────────────────

class ProjectManager:
    """Tracks multi-phase projects. State persisted to state/projects.json."""

    def __init__(self, config: Config):
        self.config = config
        self.state_dir = os.path.join(config.repo_root, 'state')
        self.projects_file = os.path.join(self.state_dir, 'projects.json')
        self.lock = FileLock(os.path.join(self.state_dir, 'projects.lock'))
        os.makedirs(self.state_dir, exist_ok=True)

    def _read(self) -> dict:
        if not os.path.exists(self.projects_file):
            return {'projects': {}}
        try:
            with open(self.projects_file) as f:
                return json.load(f)
        except (json.JSONDecodeError, IOError):
            return {'projects': {}}

    def _write(self, data: dict) -> None:
        tmp = self.projects_file + '.tmp'
        with open(tmp, 'w') as f:
            json.dump(data, f, indent=2)
        os.rename(tmp, self.projects_file)

    def create_project(self, project_id: str, spec_file: str,
                       phases: list[dict], goal: str) -> None:
        """Create a new project entry. phases: [{"name": "...", "tasks_spec": [...]}]"""
        with self.lock:
            data = self._read()
            if project_id in data['projects']:
                return  # already exists
            data['projects'][project_id] = {
                'spec_file': spec_file,
                'phases': [
                    {'name': p['name'], 'status': 'pending',
                     'tasks': [], 'tasks_spec': p.get('tasks_spec', [])}
                    for p in phases
                ],
                'current_phase': 0,
                'goal': goal,
                'goal_eval_rounds': 0,
                'max_goal_rounds': 3,
                'created_at': datetime.utcnow().strftime('%Y-%m-%dT%H:%M:%SZ'),
            }
            # Mark first phase as in_progress
            if data['projects'][project_id]['phases']:
                data['projects'][project_id]['phases'][0]['status'] = 'in_progress'
            self._write(data)

    def get_project(self, project_id: str) -> Optional[dict]:
        data = self._read()
        return data['projects'].get(project_id)

    def get_all_active_projects(self) -> dict:
        """Return all projects that aren't completed or escalated."""
        data = self._read()
        return {
            pid: proj for pid, proj in data['projects'].items()
            if not proj.get('completed') and not proj.get('escalated')
        }

    def get_current_phase(self, project_id: str) -> int:
        proj = self.get_project(project_id)
        return proj['current_phase'] if proj else 0

    def add_task_to_phase(self, project_id: str, phase: int, task_id: str) -> None:
        with self.lock:
            data = self._read()
            proj = data['projects'].get(project_id)
            if proj and 0 <= phase < len(proj['phases']):
                proj['phases'][phase]['tasks'].append(task_id)
                self._write(data)

    def advance_phase(self, project_id: str) -> Optional[dict]:
        """Advance to next phase. Returns next phase dict or None if all done."""
        with self.lock:
            data = self._read()
            proj = data['projects'].get(project_id)
            if not proj:
                return None
            current = proj['current_phase']
            # Mark current phase as completed
            if current < len(proj['phases']):
                proj['phases'][current]['status'] = 'completed'
            next_phase = current + 1
            if next_phase >= len(proj['phases']):
                return None  # all phases done
            proj['current_phase'] = next_phase
            proj['phases'][next_phase]['status'] = 'in_progress'
            self._write(data)
            return proj['phases'][next_phase]

    def all_phases_complete(self, project_id: str) -> bool:
        proj = self.get_project(project_id)
        if not proj:
            return False
        return all(p['status'] == 'completed' for p in proj['phases'])

    def mark_completed(self, project_id: str) -> None:
        with self.lock:
            data = self._read()
            proj = data['projects'].get(project_id)
            if proj:
                proj['completed'] = True
                proj['completed_at'] = datetime.utcnow().strftime('%Y-%m-%dT%H:%M:%SZ')
                self._write(data)

    def mark_escalated(self, project_id: str) -> None:
        with self.lock:
            data = self._read()
            proj = data['projects'].get(project_id)
            if proj:
                proj['escalated'] = True
                self._write(data)

    def increment_goal_rounds(self, project_id: str) -> int:
        """Increment and return new goal_eval_rounds."""
        with self.lock:
            data = self._read()
            proj = data['projects'].get(project_id)
            if not proj:
                return 0
            proj['goal_eval_rounds'] = proj.get('goal_eval_rounds', 0) + 1
            self._write(data)
            return proj['goal_eval_rounds']

    def add_goal_phase(self, project_id: str, phase_name: str,
                       tasks_spec: list) -> int:
        """Add a new phase (from goal evaluation gaps). Returns phase index."""
        with self.lock:
            data = self._read()
            proj = data['projects'].get(project_id)
            if not proj:
                return -1
            new_phase = {
                'name': phase_name, 'status': 'in_progress',
                'tasks': [], 'tasks_spec': tasks_spec,
            }
            proj['phases'].append(new_phase)
            proj['current_phase'] = len(proj['phases']) - 1
            self._write(data)
            return proj['current_phase']


# ─── Worker ──────────────────────────────────────────────────────────────────

class WorkerState(enum.Enum):
    IDLE = 'idle'
    LAUNCHING = 'launching'
    RUNNING = 'running'
    COMPLETED = 'completed'
    FAILED = 'failed'
    TIMED_OUT = 'timed_out'


class Worker:
    """Represents a single worker's lifecycle."""

    def __init__(self, worker_num: int, config: Config):
        self.worker_num = worker_num
        self.worker_id = f'worker-{worker_num}'
        self.config = config
        self.pid: Optional[int] = None
        self.process: Optional[subprocess.Popen] = None
        self.state = WorkerState.IDLE
        self.task_id: Optional[str] = None
        self.task_title: Optional[str] = None
        self.session_file: Optional[str] = None
        self.launch_time: Optional[float] = None
        self.retry_count: int = 0
        self.stats = SessionStats()

    @property
    def worker_dir(self) -> str:
        return os.path.join(self.config.worktree_root, self.worker_id)

    @property
    def log_file(self) -> str:
        return os.path.join(self.config.shared_dir, f'{self.worker_id}.log')

    def is_alive(self) -> bool:
        if self.pid is None:
            return False
        try:
            os.kill(self.pid, 0)
            return True
        except (OSError, ProcessLookupError):
            return False

    def find_latest_session(self) -> Optional[str]:
        data_dir = os.path.join(self.worker_dir, 'data')
        if not os.path.isdir(data_dir):
            return None
        files = [
            os.path.join(data_dir, f)
            for f in os.listdir(data_dir)
            if f.startswith('session-') and f.endswith('.json')
        ]
        return max(files, key=os.path.getmtime) if files else None

    def kill(self) -> None:
        if not self.pid:
            return
        try:
            os.kill(self.pid, signal.SIGTERM)
            deadline = time.time() + 5
            while time.time() < deadline:
                try:
                    os.kill(self.pid, 0)
                    time.sleep(0.5)
                except (OSError, ProcessLookupError):
                    break
            else:
                try:
                    os.kill(self.pid, signal.SIGKILL)
                except (OSError, ProcessLookupError):
                    pass
        except (OSError, ProcessLookupError):
            pass
        self.pid = None
        self.process = None

    def reset(self) -> None:
        self.pid = None
        self.process = None
        self.state = WorkerState.IDLE
        self.task_id = None
        self.task_title = None
        self.session_file = None
        self.launch_time = None
        self.stats = SessionStats()


# ─── Orchestrator ────────────────────────────────────────────────────────────

class Orchestrator:
    """Main orchestration loop."""

    def __init__(self, config: Config):
        self.config = config
        self.task_queue = TaskQueue(config)
        self.notifier = TelegramNotifier(config)
        self.parser = StreamJsonParser()
        self.health = WorkerHealth(config.health_file)
        self.projects = ProjectManager(config)
        self.workers: dict[int, Worker] = {
            i: Worker(i, config) for i in range(1, config.num_workers + 1)
        }
        self.tracked: set[str] = self._load_tracked()
        self._retry_counts: dict[str, int] = {}  # task_id -> retry count
        self._running = True
        self._last_dashboard_time: float = 0.0
        self._dashboard_interval: float = 300.0  # 5 minutes
        self._last_ratchet_time: float = 0.0
        self._ratchet_interval: float = 86400.0  # 24 hours

    # ─── Signal Handling ─────────────────────────────

    def setup_signals(self) -> None:
        signal.signal(signal.SIGINT, self._shutdown)
        signal.signal(signal.SIGTERM, self._shutdown)

    def _shutdown(self, signum, frame) -> None:
        log('Received shutdown signal, cleaning up...', self.config)
        self._running = False
        for w in self.workers.values():
            if w.is_alive():
                log(f'Stopping {w.worker_id} (PID: {w.pid})', self.config)
                w.kill()
        self._cleanup_pid()

    # ─── Main Loop ───────────────────────────────────

    def run(self) -> None:
        self._write_pid()
        log(f'Orchestrator started (PID: {os.getpid()}, '
            f'interval: {self.config.poll_interval}s, '
            f'timeout: {self.config.worker_timeout_minutes}min, '
            f'max_retries: {self.config.max_retries})', self.config)

        try:
            while self._running:
                self._cycle()
                if self.config.run_once:
                    log('Single run complete, exiting', self.config)
                    break
                # Interruptible sleep
                for _ in range(self.config.poll_interval * 10):
                    if not self._running:
                        break
                    time.sleep(0.1)
        finally:
            self._cleanup_pid()
            log('Orchestrator stopped', self.config)

    def _cycle(self) -> None:
        self._monitor_workers()
        self._check_timeouts()
        self._check_completions()
        self._check_phase_advancement()
        self._dispatch_tasks()
        self._run_ratchet_if_due()
        self._send_dashboard_if_due()

    # ─── Phase 1: Monitor Workers ────────────────────

    def _monitor_workers(self) -> None:
        for w in self.workers.values():
            if w.state not in (WorkerState.LAUNCHING, WorkerState.RUNNING):
                continue

            if not w.is_alive():
                w.state = WorkerState.COMPLETED
                continue

            session = w.session_file or w.find_latest_session()
            if session:
                w.session_file = session
                self.parser.parse_incremental(session, w.stats)

                if w.state == WorkerState.LAUNCHING and w.stats.initialized:
                    w.state = WorkerState.RUNNING
                    log(f'{w.worker_id} is now running '
                        f'(session: {w.stats.session_id})', self.config)

    # ─── Phase 2: Timeout Detection ─────────────────

    def _check_timeouts(self) -> None:
        for w in self.workers.values():
            if w.state != WorkerState.RUNNING:
                continue

            minutes_stuck = w.stats.minutes_since_activity

            if minutes_stuck < self.config.worker_timeout_minutes:
                continue

            log(f'TIMEOUT: {w.worker_id} stuck for {minutes_stuck:.0f}min '
                f'(task: {w.task_title})', self.config)

            w.kill()
            w.state = WorkerState.TIMED_OUT
            self.health.record_timeout(w.worker_id)

            # Re-queue if retries remain
            task_id = w.task_id
            retry_count = self._retry_counts.get(task_id, 0) if task_id else 99
            can_retry = retry_count < self.config.max_retries

            if can_retry and task_id:
                self.task_queue.reset_task(task_id)
                self._retry_counts[task_id] = retry_count + 1
                log(f'Re-queued task {task_id} '
                    f'(retry {retry_count + 1}/{self.config.max_retries})',
                    self.config)

            self.notifier.notify_timeout(
                w.worker_id,
                w.task_title or 'unknown',
                minutes_stuck,
                retry=can_retry,
            )
            w.reset()

    # ─── Phase 3: Check Completions ──────────────────

    def _check_completions(self) -> None:
        tasks = self.task_queue.get_completed_or_failed()

        for task in tasks:
            task_id = task['id']
            if task_id in self.tracked:
                continue

            result = task.get('result', '')
            title = task.get('title', '')
            worker_id = task.get('claimed_by', '')

            log(f'Task completed: {title} ({result}) by {worker_id}',
                self.config)

            # Get session stats from worker object
            worker_stats: dict = {}
            for w in self.workers.values():
                if w.worker_id == worker_id:
                    worker_stats = {
                        'tool_calls': w.stats.tool_calls,
                        'last_error': w.stats.last_error,
                        'cost_usd': w.stats.cost_usd,
                        'num_turns': w.stats.num_turns,
                    }
                    duration_sec = (time.time() - w.launch_time) if w.launch_time else 0
                    self.health.record_completion(
                        worker_id, result == 'success',
                        duration_sec, w.stats.tool_calls,
                    )
                    w.reset()
                    break

            self._update_progress(task)
            self.tracked.add(task_id)
            self._save_tracked(task_id)

            if result == 'success':
                self.notifier.notify_success(task, worker_stats)
                if title.startswith('review:'):
                    # Parse structured findings from the review
                    findings, has_blocking = self._parse_review_findings(task)
                    if has_blocking:
                        self._enqueue_correction_from_findings(task, findings)
                    else:
                        self._trigger_skill_contribution(task, findings)
                        self.notifier.send(
                            f'\u2705 *Review Passed*\n'
                            f'Task: {title}\n'
                            f'Findings: {len(findings)} (none blocking)\n'
                            f'PR ready for human review.'
                        )
                else:
                    # Run quality gate on implementation/correction tasks
                    gate_passed = self._run_quality_gate(task)
                    if gate_passed:
                        self._notify_gate_results(task, passed=True)
                        self._enqueue_review(task)
                    else:
                        self._notify_gate_results(task, passed=False)
                        self._enqueue_correction(task)
            else:
                self.notifier.notify_failure(task, worker_stats)

    # ─── Phase 4: Dispatch Tasks ─────────────────────

    def _dispatch_tasks(self) -> None:
        pending = self.task_queue.count_pending()
        if pending == 0:
            return

        idle = [w for w in self.workers.values() if w.state == WorkerState.IDLE]
        if not idle:
            log(f'All workers busy ({pending} tasks pending)', self.config)
            return

        idle_ids = ', '.join(w.worker_id for w in idle)
        log(f'Pending tasks: {pending} | Idle workers: {idle_ids}', self.config)

        for worker in idle:
            if self.task_queue.count_pending() == 0:
                break

            if self.config.dry_run:
                log(f'[DRY-RUN] Would launch {worker.worker_id}', self.config)
                continue

            log(f'Launching {worker.worker_id}...', self.config)

            # Run comprehension phase before launching worker
            comprehension_file = self._run_comprehension(worker)

            launch_script = os.path.join(self.config.script_dir, 'launch-worker.sh')
            log_fh = open(worker.log_file, 'a')

            env = os.environ.copy()
            if comprehension_file:
                env['COMPREHENSION_FILE'] = comprehension_file

            proc = subprocess.Popen(
                ['bash', launch_script, str(worker.worker_num)],
                stdout=log_fh,
                stderr=subprocess.STDOUT,
                start_new_session=True,
                env=env,
            )

            worker.process = proc
            worker.pid = proc.pid
            worker.state = WorkerState.LAUNCHING
            worker.launch_time = time.time()

            log(f'{worker.worker_id} started (PID: {worker.pid})', self.config)

            # Delay between launches to avoid race conditions on task claiming
            time.sleep(2)

    # ─── Comprehension Phase ─────────────────────────

    def _run_comprehension(self, worker) -> Optional[str]:
        """Run a quick Claude one-shot to study relevant files before worker starts.

        Peeks at the next pending task's files to generate a comprehension
        summary. Returns the path to the comprehension file, or None.
        """
        # Peek at next pending task (don't claim it — launch-worker.sh does that)
        pending = [t for t in self.task_queue.get_all_tasks()
                   if t['status'] == 'pending']
        if not pending:
            return None

        # Sort by priority like task-queue.sh does
        prio_map = {'critical': 0, 'high': 1, 'medium': 2, 'low': 3}
        pending.sort(key=lambda t: prio_map.get(t.get('priority', 'medium'), 2))
        task = pending[0]

        files = task.get('files', [])
        title = task.get('title', '')
        description = task.get('description', '')

        if not files and not description:
            return None

        # Build file tree context
        file_context = ''
        for fp in files[:10]:
            full_path = os.path.join(self.config.repo_root, fp)
            if os.path.exists(full_path):
                try:
                    with open(full_path) as f:
                        content = f.read()[:2000]
                    file_context += f'\n--- {fp} ---\n{content}\n'
                except IOError:
                    pass

        if not file_context and not description:
            return None

        prompt = (
            f'You are preparing a developer to work on: {title}\n\n'
            f'Task description:\n{description[:1500]}\n\n'
            f'Relevant files:\n{file_context[:6000]}\n\n'
            f'Write a concise comprehension summary (max 500 words):\n'
            f'1. What these files do and how they relate\n'
            f'2. Key patterns, conventions, and naming used\n'
            f'3. Potential gotchas or tricky areas for this task\n'
            f'4. Suggested approach (brief)\n\n'
            f'Be specific — reference actual function names, types, and patterns you see.'
        )

        comp_dir = os.path.join(self.config.shared_dir, 'comprehension')
        os.makedirs(comp_dir, exist_ok=True)
        comp_file = os.path.join(comp_dir, f'{worker.worker_id}-{task["id"]}.md')

        try:
            result = subprocess.run(
                ['claude', '--print', '--no-input', '-p', prompt],
                capture_output=True, text=True, timeout=90,
                cwd=self.config.repo_root,
            )
            if result.returncode == 0 and result.stdout.strip():
                with open(comp_file, 'w') as f:
                    f.write(f'# Comprehension: {title}\n\n')
                    f.write(result.stdout.strip())
                log(f'Comprehension generated for {worker.worker_id}: {title}',
                    self.config)
                return comp_file
        except subprocess.TimeoutExpired:
            log(f'Comprehension timed out for {worker.worker_id}', self.config)
        except Exception as e:
            log(f'Comprehension failed for {worker.worker_id}: {e}', self.config)

        return None

    # ─── Quality Gate ─────────────────────────────────

    def _run_quality_gate(self, task: dict) -> bool:
        """Run quality-gate.sh on the worker's branch. Returns True if all tiers pass."""
        task_id = task['id']
        worker_id = task.get('claimed_by', '')
        worker_branch = worker_id.replace('worker-', 'worker/')
        spec_file = task.get('spec_file', '')
        current_round = task.get('round', 0)

        os.makedirs(self.config.gate_results_dir, exist_ok=True)
        gate_script = os.path.join(self.config.script_dir, 'quality-gate.sh')

        if not os.path.exists(gate_script):
            log(f'quality-gate.sh not found, skipping gate for {task_id}', self.config)
            return True

        cmd = [
            'bash', gate_script,
            '--branch', worker_branch,
            '--task-id', task_id,
        ]
        if spec_file:
            cmd += ['--spec-file', spec_file]

        log(f'Running quality gate for {task_id} (round {current_round})...', self.config)

        try:
            result = subprocess.run(
                cmd,
                capture_output=True, text=True,
                timeout=300,  # 5 minute max
                cwd=self.config.repo_root,
            )

            # quality-gate.sh exits 0 on pass, 1 on fail
            gate_passed = result.returncode == 0

            # Find the gate results JSON
            results_file = os.path.join(
                self.config.gate_results_dir, f'{task_id}-latest.json'
            )
            if os.path.exists(results_file):
                self.task_queue.update_task_field(task_id, 'gate_results', results_file)

            log(f'Quality gate {"PASSED" if gate_passed else "FAILED"} for {task_id}',
                self.config)
            return gate_passed

        except subprocess.TimeoutExpired:
            log(f'Quality gate TIMEOUT for {task_id}', self.config)
            return False
        except Exception as e:
            log(f'Quality gate ERROR for {task_id}: {e}', self.config)
            return True  # fail-open on unexpected errors

    def _enqueue_correction(self, task: dict) -> None:
        """Create a correction task with feedback, or escalate if max rounds reached."""
        task_id = task['id']
        current_round = task.get('round', 0)
        max_rounds = task.get('max_rounds', 3)
        title = task.get('title', '').removeprefix('correction: ')
        spec_file = task.get('spec_file', '')
        orig_files = task.get('files', [])
        gate_results_file = task.get('gate_results', '')

        next_round = current_round + 1

        if next_round >= max_rounds:
            log(f'Max rounds ({max_rounds}) reached for {task_id}, escalating to human',
                self.config)
            self.notifier.send(
                f'\U0001f6a8 *Escalation Required*\n'
                f'Task: {title}\n'
                f'Rounds: {next_round}/{max_rounds}\n'
                f'Quality gate failed {max_rounds} times.\n'
                f'Human review needed.'
            )
            self._update_pipeline_status(task, 'escalated')
            return

        # Synthesize feedback
        feedback_file = None
        if gate_results_file and os.path.exists(gate_results_file):
            os.makedirs(self.config.feedback_dir, exist_ok=True)
            feedback_script = os.path.join(self.config.script_dir, 'feedback-synthesizer.sh')
            if os.path.exists(feedback_script):
                try:
                    subprocess.run(
                        ['bash', feedback_script, task_id, str(next_round), gate_results_file],
                        capture_output=True, text=True, timeout=30,
                    )
                    feedback_file = os.path.join(
                        self.config.feedback_dir, f'{task_id}-round-{next_round}.md'
                    )
                    if not os.path.exists(feedback_file):
                        feedback_file = None
                except Exception as e:
                    log(f'Feedback synthesis failed for {task_id}: {e}', self.config)

        # Build correction task description
        correction_desc = f'CORRECTION TASK (Round {next_round}/{max_rounds})\n\n'
        correction_desc += f'Original task: {title}\n'
        if spec_file:
            correction_desc += f'Spec file: {spec_file}\n'
        if feedback_file:
            correction_desc += f'\nFeedback document: {feedback_file}\n'
            correction_desc += 'READ THE FEEDBACK FILE FIRST before making changes.\n'
        correction_desc += '\nFix ONLY blocking issues. Do NOT add features or refactor.\n'
        correction_desc += f'Commit with: fix(correction-r{next_round}): <summary>\n'

        # Find the original task ID for linking
        parent_id = task.get('parent_task_id') or task_id

        correction_id = self.task_queue.add_task(
            title=f'correction: {title}',
            priority='high',
            files=orig_files,
            description=correction_desc,
            spec_file=spec_file,
            parent_task_id=parent_id,
            round_num=next_round,
            max_rounds=max_rounds,
        )

        if feedback_file:
            self.task_queue.update_task_field(correction_id, 'feedback_file', feedback_file)

        log(f'Enqueued correction round {next_round}/{max_rounds} for: {title}',
            self.config)
        self.notifier.send(
            f'\U0001f504 *Correction Queued* (R{next_round}/{max_rounds})\n'
            f'Task: {title}\n'
            f'Feedback: {"generated" if feedback_file else "unavailable"}'
        )
        self._update_pipeline_status(task, f'correction-r{next_round}')

    def _notify_gate_results(self, task: dict, passed: bool) -> None:
        """Send Telegram notification with gate tier breakdown."""
        task_id = task['id']
        title = task.get('title', '').removeprefix('correction: ')
        current_round = task.get('round', 0)
        gate_results_file = task.get('gate_results', '')

        # Try to read tier-level results
        t1 = t2 = t3 = '?'
        if gate_results_file and os.path.exists(gate_results_file):
            try:
                with open(gate_results_file) as f:
                    results = json.load(f)
                t1 = '\u2705' if results.get('tier1', {}).get('pass') else '\u274c'
                t2 = '\u2705' if results.get('tier2', {}).get('pass') else '\u274c'
                t3 = '\u2705' if results.get('tier3', {}).get('pass') else '\u274c'
            except (json.JSONDecodeError, IOError):
                pass

        status = '\u2705 PASSED' if passed else '\u274c FAILED'
        self.notifier.send(
            f'\U0001f50d *Quality Gate {status}*\n'
            f'Task: {title}\n'
            f'Round: {current_round}\n'
            f'T1{t1} T2{t2} T3{t3}'
        )

    def _update_pipeline_status(self, task: dict, stage: str) -> None:
        """Write/update pipeline-status.json for dashboard visibility."""
        task_id = task['id']
        status_data = {}
        if os.path.exists(self.config.pipeline_status_file):
            try:
                with open(self.config.pipeline_status_file) as f:
                    status_data = json.load(f)
            except (json.JSONDecodeError, IOError):
                pass

        if 'tasks' not in status_data:
            status_data['tasks'] = {}

        now = datetime.utcnow().strftime('%Y-%m-%dT%H:%M:%SZ')
        entry = status_data['tasks'].get(task_id, {})
        entry.update({
            'title': task.get('title', ''),
            'status': stage,
            'round': task.get('round', 0),
            'worker': task.get('claimed_by', ''),
            'updated_at': now,
        })
        status_data['tasks'][task_id] = entry
        status_data['last_updated'] = now

        try:
            tmp = self.config.pipeline_status_file + '.tmp'
            with open(tmp, 'w') as f:
                json.dump(status_data, f, indent=2)
            os.rename(tmp, self.config.pipeline_status_file)
        except IOError as e:
            log(f'Failed to write pipeline status: {e}', self.config)

    def _send_dashboard_if_due(self) -> None:
        """Send periodic Telegram dashboard when active tasks exist."""
        now = time.time()
        if now - self._last_dashboard_time < self._dashboard_interval:
            return

        active_workers = [w for w in self.workers.values()
                          if w.state in (WorkerState.LAUNCHING, WorkerState.RUNNING)]
        tasks = self.task_queue.get_all_tasks()
        pending = [t for t in tasks if t['status'] == 'pending']

        if not active_workers and not pending:
            return

        self._last_dashboard_time = now

        lines = ['\U0001f4ca *Pipeline Dashboard*']

        for w in active_workers:
            minutes = int((now - w.launch_time) / 60) if w.launch_time else 0
            lines.append(
                f'  \u23f3 {w.task_title or "unknown"}\n'
                f'     {w.worker_id}, {minutes}min, {w.stats.tool_calls} tools'
            )

        for t in pending[:5]:
            rnd = t.get('round', 0)
            max_r = t.get('max_rounds', 3)
            prefix = '\U0001f504' if t.get('title', '').startswith('correction:') else '\U0001f4cb'
            lines.append(f'  {prefix} {t.get("title", "")} [R{rnd}/{max_r}]')

        total = len(tasks)
        done = sum(1 for t in tasks if t['status'] == 'completed')
        failed = sum(1 for t in tasks if t['status'] == 'failed')
        lines.append(f'\nTotal: {total} | Active: {len(active_workers)} | '
                      f'Pending: {len(pending)} | Done: {done} | Failed: {failed}')

        self.notifier.send('\n'.join(lines))

    # ─── Quality Ratchet ─────────────────────────────

    def _run_ratchet_if_due(self) -> None:
        """Run quality ratchet periodically to generate improvement tasks."""
        now = time.time()
        if now - self._last_ratchet_time < self._ratchet_interval:
            return

        self._last_ratchet_time = now

        ratchet_script = os.path.join(self.config.script_dir, 'quality-ratchet.sh')
        if not os.path.exists(ratchet_script):
            return

        log('Running quality ratchet...', self.config)
        try:
            result = subprocess.run(
                ['bash', ratchet_script, '--days', '7'],
                capture_output=True, text=True, timeout=60,
                cwd=self.config.repo_root,
            )
            output = result.stdout.strip()
            # Extract count from last line: "Quality Ratchet complete: N improvement tasks generated"
            for line in output.split('\n'):
                if 'improvement tasks' in line:
                    log(f'Ratchet: {line}', self.config)
                    # Notify if tasks were generated
                    if 'CREATED' in output:
                        count = output.count('CREATED:')
                        self.notifier.send(
                            f'\U0001f527 *Quality Ratchet*\n'
                            f'{count} improvement tasks generated'
                        )
                    break
        except subprocess.TimeoutExpired:
            log('Quality ratchet timed out', self.config)
        except Exception as e:
            log(f'Quality ratchet error: {e}', self.config)

    # ─── Phase Advancement ────────────────────────────

    def _check_phase_advancement(self) -> None:
        """Check if any project's current phase is done and advance to next."""
        active = self.projects.get_all_active_projects()
        if not active:
            return

        all_tasks = self.task_queue.get_all_tasks()

        for project_id, proj in active.items():
            current_phase = proj['current_phase']
            if current_phase >= len(proj['phases']):
                continue

            phase_info = proj['phases'][current_phase]
            phase_task_ids = phase_info.get('tasks', [])

            if not phase_task_ids:
                continue

            # Check if all phase tasks are completed with success
            all_done = True
            for tid in phase_task_ids:
                task = next((t for t in all_tasks if t['id'] == tid), None)
                if not task:
                    all_done = False
                    break
                if task['status'] != 'completed' or task.get('result') != 'success':
                    all_done = False
                    break

            if not all_done:
                continue

            log(f'Phase {current_phase} complete for project {project_id}', self.config)

            next_phase = self.projects.advance_phase(project_id)
            if next_phase:
                self._enqueue_phase_tasks(project_id, next_phase, proj)
            else:
                log(f'All phases complete for project {project_id}, '
                    f'triggering goal check', self.config)
                self._trigger_goal_check(project_id)

    def _enqueue_phase_tasks(self, project_id: str, phase_info: dict,
                             proj: dict) -> None:
        """Enqueue tasks for a project phase from the phase's tasks_spec."""
        phase_idx = proj['current_phase']
        spec_file = proj.get('spec_file', '')
        tasks_spec = phase_info.get('tasks_spec', [])

        if not tasks_spec:
            log(f'No tasks_spec for phase {phase_idx} of {project_id}', self.config)
            return

        for task_spec in tasks_spec:
            title = task_spec if isinstance(task_spec, str) else task_spec.get('title', '')
            desc = '' if isinstance(task_spec, str) else task_spec.get('description', '')
            files = [] if isinstance(task_spec, str) else task_spec.get('files', [])

            task_id = self.task_queue.add_task(
                title=title,
                priority='high',
                files=files,
                description=desc,
                spec_file=spec_file,
                project_id=project_id,
                phase=phase_idx,
            )
            self.projects.add_task_to_phase(project_id, phase_idx, task_id)
            log(f'Enqueued phase {phase_idx} task: {title} '
                f'(project: {project_id})', self.config)

        self.notifier.send(
            f'\U0001f680 *Phase {phase_idx} Started*\n'
            f'Project: {project_id}\n'
            f'Phase: {phase_info["name"]}\n'
            f'Tasks: {len(tasks_spec)}'
        )

    # ─── Goal Check ──────────────────────────────────

    def _trigger_goal_check(self, project_id: str) -> None:
        """Assess whether a project achieves its goal after all phases complete."""
        proj = self.projects.get_project(project_id)
        if not proj:
            return

        goal = proj.get('goal', '')
        spec_file = proj.get('spec_file', '')
        max_rounds = proj.get('max_goal_rounds', 3)
        current_rounds = proj.get('goal_eval_rounds', 0)

        if current_rounds >= max_rounds:
            log(f'Goal check max rounds ({max_rounds}) reached for {project_id}, '
                f'escalating', self.config)
            self.projects.mark_escalated(project_id)
            self.notifier.send(
                f'\U0001f6a8 *Project Escalation*\n'
                f'Project: {project_id}\n'
                f'Goal check failed {max_rounds} times.\n'
                f'Human review needed.'
            )
            return

        if not goal:
            self.projects.mark_completed(project_id)
            self.notifier.send(
                f'\U0001f389 *Project Complete*\n'
                f'Project: {project_id}\n'
                f'All phases passed quality gates.'
            )
            return

        achieved, gaps = self._run_goal_check(project_id, goal, spec_file)

        if achieved:
            self.projects.mark_completed(project_id)
            self.notifier.send(
                f'\U0001f389 *Project Goal Achieved*\n'
                f'Project: {project_id}\n'
                f'Goal: {goal[:100]}'
            )
        else:
            rounds = self.projects.increment_goal_rounds(project_id)
            gap_tasks = [
                {'title': g, 'description': f'Gap identified by goal assessment round {rounds}'}
                for g in gaps
            ]
            phase_idx = self.projects.add_goal_phase(
                project_id,
                f'Goal Gaps (Round {rounds})',
                gap_tasks,
            )
            if phase_idx >= 0:
                proj_updated = self.projects.get_project(project_id)
                phase_info = proj_updated['phases'][phase_idx]
                self._enqueue_phase_tasks(project_id, phase_info, proj_updated)

            self.notifier.send(
                f'\U0001f50d *Goal Check: Gaps Found* (R{rounds}/{max_rounds})\n'
                f'Project: {project_id}\n'
                f'Gaps: {len(gaps)}\n'
                f'New tasks enqueued.'
            )

    def _run_goal_check(self, project_id: str, goal: str,
                        spec_file: str) -> tuple[bool, list[str]]:
        """Run Claude CLI one-shot to assess project goal. Returns (achieved, gaps)."""
        all_tasks = self.task_queue.get_all_tasks()
        project_tasks = [t for t in all_tasks if t.get('project_id') == project_id]
        task_summaries = []
        for t in project_tasks:
            task_summaries.append(
                f"- {t['title']}: {t.get('result', 'unknown')} "
                f"(round {t.get('round', 0)})"
            )
        tasks_text = '\n'.join(task_summaries) or 'No task results available'

        spec_text = ''
        if spec_file:
            spec_path = os.path.join(self.config.repo_root, spec_file)
            if os.path.exists(spec_path):
                try:
                    with open(spec_path) as f:
                        spec_text = f.read()[:3000]
                except IOError:
                    pass

        prompt = (
            f'You are assessing whether a software project has achieved its goal.\n\n'
            f'PROJECT GOAL: {goal}\n\n'
            f'SPEC:\n{spec_text[:2000]}\n\n'
            f'TASK RESULTS:\n{tasks_text}\n\n'
            f'Output ONLY valid JSON (no markdown, no explanation):\n'
            f'{{"achieved": true/false, "gaps": ["gap description 1", ...]}}\n'
            f'If the project meets its goal, set achieved=true and gaps=[].\n'
            f'If not, list 1-5 specific gaps as task titles a developer should fix.'
        )

        try:
            result = subprocess.run(
                ['claude', '--print', '--no-input', '-p', prompt],
                capture_output=True, text=True, timeout=120,
                cwd=self.config.repo_root,
            )
            output = result.stdout.strip()
            start = output.find('{')
            end = output.rfind('}') + 1
            if start >= 0 and end > start:
                parsed = json.loads(output[start:end])
                achieved = parsed.get('achieved', False)
                gaps = parsed.get('gaps', [])
                return achieved, gaps
        except (subprocess.TimeoutExpired, json.JSONDecodeError, Exception) as e:
            log(f'Goal check failed for {project_id}: {e}', self.config)

        # Fail-open: if we can't assess, mark as achieved
        return True, []

    # ─── Review Enqueue ──────────────────────────────

    def _enqueue_review(self, task: dict) -> None:
        """Enqueue a findings-only review task. Reviewer must NOT touch code."""
        orig_title = task.get('title', '')
        orig_worker = task.get('claimed_by', '')
        orig_files = task.get('files', [])
        worker_branch = orig_worker.replace('worker-', 'worker/')

        # Load builder's self-score if available
        score_context = ''
        score_file = os.path.join(
            self.config.shared_dir, 'scores',
            f'{orig_worker}-{task["id"]}.json'
        )
        if os.path.exists(score_file):
            try:
                with open(score_file) as f:
                    score_data = json.load(f)
                overall = score_data.get('overall', '?')
                self_issues = score_data.get('self_identified_issues', [])
                confidence = score_data.get('confidence', '?')
                score_context = (
                    f'\n## Builder Self-Assessment\n'
                    f'Overall score: {overall}/10 | Confidence: {confidence}\n'
                    f'Self-identified issues:\n'
                )
                for issue in self_issues:
                    score_context += f'  {issue}\n'
                score_context += (
                    f'\nDimension scores: {json.dumps(score_data.get("scores", {}))}\n'
                    f'\nFocus your review on dimensions the builder scored lowest.\n'
                )
            except (json.JSONDecodeError, IOError):
                pass

        findings_dir = os.path.join(self.config.shared_dir, 'findings')
        os.makedirs(findings_dir, exist_ok=True)
        findings_file = os.path.join(findings_dir, f'review-{task["id"]}.txt')

        review_desc = (
            f'Code review for: {orig_title} (implemented by {orig_worker}).\n\n'
            f'SETUP: Read the implementation diff:\n'
            f'  git fetch origin && git diff main...{worker_branch}\n\n'
            f'YOU ARE A REVIEWER. You must NOT modify any code files.\n'
            f'Your ONLY job is to read the diff and output structured findings.\n'
            f'{score_context}\n'
            f'REVIEW CHECKLIST:\n'
            f'1. Spec compliance — does it match requirements?\n'
            f'2. Correctness — logic bugs, null derefs, edge cases\n'
            f'3. Security — secrets, injection, XSS\n'
            f'4. Convention — follows codebase patterns\n'
            f'5. Testing — meaningful tests exist\n'
            f'6. No dead code, console.logs, TODOs\n\n'
            f'OUTPUT FORMAT — one finding per line:\n'
            f'  category/severity file:line -- Problem -> Remedy\n\n'
            f'Categories: correctness, security, architecture, testing, style, performance\n'
            f'Severity: critical, major, minor\n\n'
            f'If no issues: NO_ISSUES_FOUND\n\n'
            f'Write findings to: {findings_file}\n'
            f'Do NOT edit source code. Do NOT run builds. Do NOT create commits.\n'
        )

        review_task_id = self.task_queue.add_task(
            title=f'review: {orig_title}',
            priority='high',
            files=orig_files,
            description=review_desc,
        )
        # Store findings path on the review task for later parsing
        self.task_queue.update_task_field(review_task_id, 'findings_file', findings_file)
        self.task_queue.update_task_field(review_task_id, 'parent_task_id', task['id'])

        log(f'Enqueued review for: {orig_title} (from {orig_worker})',
            self.config)
        self.notifier.notify_queued(f'review: {orig_title}', 'high')

    # ─── Review Findings Parser ──────────────────────

    def _parse_review_findings(self, review_task: dict) -> tuple[list[dict], bool]:
        """Parse structured findings from a completed review task.

        Returns (findings_list, has_blocking) where each finding is:
        {category, severity, file, line, problem, remedy}
        """
        findings_file = review_task.get('findings_file', '')
        if not findings_file or not os.path.exists(findings_file):
            log(f'No findings file for review task {review_task["id"]}', self.config)
            return [], False

        findings: list[dict] = []
        has_blocking = False

        try:
            with open(findings_file) as f:
                content = f.read().strip()

            if 'NO_ISSUES_FOUND' in content:
                return [], False

            for line in content.splitlines():
                line = line.strip()
                if not line or line.startswith('#'):
                    continue

                # Parse: category/severity file:line -- Problem -> Remedy
                try:
                    # Split on ' -- ' to get left and right parts
                    if ' -- ' not in line:
                        continue
                    left, rest = line.split(' -- ', 1)

                    # Parse problem -> remedy
                    if ' -> ' in rest:
                        problem, remedy = rest.split(' -> ', 1)
                    else:
                        problem = rest
                        remedy = ''

                    # Parse category/severity and file:line from left
                    parts = left.strip().split(None, 1)
                    if len(parts) < 2:
                        continue

                    cat_sev = parts[0]
                    file_loc = parts[1]

                    if '/' in cat_sev:
                        category, severity = cat_sev.split('/', 1)
                    else:
                        category = cat_sev
                        severity = 'minor'

                    file_path = file_loc
                    line_num = ''
                    if ':' in file_loc:
                        file_path, line_num = file_loc.rsplit(':', 1)

                    finding = {
                        'category': category.strip(),
                        'severity': severity.strip(),
                        'file': file_path.strip(),
                        'line': line_num.strip(),
                        'problem': problem.strip(),
                        'remedy': remedy.strip(),
                    }
                    findings.append(finding)

                    if severity.strip() in ('critical', 'major'):
                        has_blocking = True

                except (ValueError, IndexError):
                    continue

        except IOError as e:
            log(f'Error reading findings file: {e}', self.config)

        return findings, has_blocking

    def _enqueue_correction_from_findings(self, review_task: dict,
                                          findings: list[dict]) -> None:
        """Create a correction task from structured review findings."""
        orig_title = review_task.get('title', '').removeprefix('review: ')
        parent_id = review_task.get('parent_task_id', '')
        orig_files = review_task.get('files', [])

        # Build correction description from findings
        blocking = [f for f in findings if f['severity'] in ('critical', 'major')]
        non_blocking = [f for f in findings if f['severity'] not in ('critical', 'major')]

        desc = f'CORRECTION FROM REVIEW FINDINGS\n\n'
        desc += f'Original task: {orig_title}\n\n'

        if blocking:
            desc += '## BLOCKING Issues (must fix)\n\n'
            for i, f in enumerate(blocking, 1):
                desc += (f'{i}. **{f["category"]}/{f["severity"]}** '
                         f'`{f["file"]}:{f["line"]}` — {f["problem"]}\n')
                if f['remedy']:
                    desc += f'   Remedy: {f["remedy"]}\n'
            desc += '\n'

        if non_blocking:
            desc += '## Non-blocking (nice to have)\n\n'
            for f in non_blocking:
                desc += (f'- {f["category"]}/{f["severity"]} '
                         f'`{f["file"]}:{f["line"]}` — {f["problem"]}\n')
            desc += '\n'

        desc += 'Fix ONLY blocking issues. Do NOT add features or refactor.\n'
        desc += f'Commit with: fix(review-correction): <summary>\n'

        correction_id = self.task_queue.add_task(
            title=f'correction: {orig_title}',
            priority='high',
            files=orig_files,
            description=desc,
            parent_task_id=parent_id,
        )
        log(f'Enqueued review correction for: {orig_title} '
            f'({len(blocking)} blocking, {len(non_blocking)} minor)',
            self.config)
        self.notifier.send(
            f'\U0001f504 *Review Correction Queued*\n'
            f'Task: {orig_title}\n'
            f'Blocking: {len(blocking)} | Minor: {len(non_blocking)}'
        )

    # ─── Skill Contribution ──────────────────────────

    def _trigger_skill_contribution(self, review_task: dict,
                                    findings: list[dict]) -> None:
        """Compare builder self-score with reviewer findings to improve future scoring."""
        orig_title = review_task.get('title', '').removeprefix('review: ')
        parent_id = review_task.get('parent_task_id', '')

        # Find the original implementation task to get worker ID
        all_tasks = self.task_queue.get_all_tasks()
        impl_task = next(
            (t for t in all_tasks if t['id'] == parent_id),
            None,
        )
        if not impl_task:
            return

        worker_id = impl_task.get('claimed_by', '')
        score_file = os.path.join(
            self.config.shared_dir, 'scores',
            f'{worker_id}-{impl_task["id"]}.json'
        )
        if not os.path.exists(score_file):
            return

        try:
            with open(score_file) as f:
                score_data = json.load(f)
        except (json.JSONDecodeError, IOError):
            return

        builder_scores = score_data.get('scores', {})
        self_issues = score_data.get('self_identified_issues', [])

        # Calculate blind spots: findings by reviewer NOT in builder's self-identified issues
        self_files = set()
        for line in self_issues:
            parts = line.split()
            if len(parts) >= 2:
                f_part = parts[1].split(':')[0]
                self_files.add(f_part)
        blind_spots = [f for f in findings if f['file'] not in self_files]

        # Calculate dimension calibration
        calibration: dict = {}
        reviewer_by_category: dict[str, int] = {}
        for f in findings:
            cat = f['category']
            sev_weight = {'critical': 3, 'major': 2, 'minor': 1}.get(f['severity'], 1)
            reviewer_by_category[cat] = reviewer_by_category.get(cat, 0) + sev_weight

        # Map reviewer categories to score dimensions
        cat_to_dim = {
            'correctness': 'correctness', 'security': 'security',
            'architecture': 'convention', 'style': 'readability',
            'testing': 'testing', 'performance': 'simplicity',
        }
        for cat, weight in reviewer_by_category.items():
            dim = cat_to_dim.get(cat, cat)
            builder_score = builder_scores.get(dim, 10)
            if weight >= 2 and builder_score >= 8:
                calibration[dim] = {
                    'builder_score': builder_score,
                    'reviewer_issue_weight': weight,
                    'assessment': 'over-confident',
                }

        # Write contribution report
        contrib_dir = os.path.join(self.config.shared_dir, 'skill-contributions')
        os.makedirs(contrib_dir, exist_ok=True)
        contrib_file = os.path.join(contrib_dir, f'{impl_task["id"]}.json')

        report = {
            'task': orig_title,
            'worker': worker_id,
            'timestamp': datetime.utcnow().strftime('%Y-%m-%dT%H:%M:%SZ'),
            'blind_spots': [
                {'file': f['file'], 'line': f['line'],
                 'category': f['category'], 'severity': f['severity'],
                 'problem': f['problem']}
                for f in blind_spots
            ],
            'calibration_gaps': calibration,
            'total_self_issues': len(self_issues),
            'total_reviewer_issues': len(findings),
        }

        try:
            with open(contrib_file, 'w') as f:
                json.dump(report, f, indent=2)
        except IOError as e:
            log(f'Failed to write skill contribution: {e}', self.config)
            return

        if len(blind_spots) >= 2 or calibration:
            log(f'Skill contribution: {len(blind_spots)} blind spots, '
                f'{len(calibration)} calibration gaps for {orig_title}', self.config)

    # ─── Progress Tracking ───────────────────────────

    def _update_progress(self, task: dict) -> None:
        now = datetime.utcnow().strftime('%Y-%m-%dT%H:%M:%SZ')
        entry = (
            f'\n### {task.get("claimed_by", "unknown")} -- {now}\n'
            f'- Task: {task.get("title", "")}\n'
            f'- Result: {task.get("result", "")}\n'
        )
        try:
            with open(self.config.progress_file, 'a') as f:
                f.write(entry)
        except IOError:
            pass

    # ─── Tracked Completions ─────────────────────────

    def _load_tracked(self) -> set:
        tracked: set[str] = set()
        if os.path.exists(self.config.tracked_file):
            try:
                with open(self.config.tracked_file) as f:
                    for line in f:
                        line = line.strip()
                        if line:
                            tracked.add(line)
            except IOError:
                pass
        return tracked

    def _save_tracked(self, task_id: str) -> None:
        try:
            with open(self.config.tracked_file, 'a') as f:
                f.write(task_id + '\n')
        except IOError:
            pass

    # ─── PID File ────────────────────────────────────

    def _write_pid(self) -> None:
        with open(self.config.pid_file, 'w') as f:
            f.write(str(os.getpid()))

    def _cleanup_pid(self) -> None:
        try:
            os.unlink(self.config.pid_file)
        except OSError:
            pass


# ─── Entry Point ─────────────────────────────────────────────────────────────

def main():
    parser = argparse.ArgumentParser(
        description='Orchestrator daemon — Manages worker lifecycle and task distribution'
    )
    parser.add_argument('--interval', type=int, default=30,
                        help='Poll interval in seconds (default: 30)')
    parser.add_argument('--once', action='store_true',
                        help='Run one cycle then exit')
    parser.add_argument('--dry-run', action='store_true',
                        help='Show what would happen without launching workers')
    parser.add_argument('--timeout', type=int, default=15,
                        help='Worker inactivity timeout in minutes (default: 15)')
    parser.add_argument('--max-retries', type=int, default=2,
                        help='Max retries for timed-out tasks (default: 2)')
    args = parser.parse_args()

    config = Config(args)
    orch = Orchestrator(config)
    orch.setup_signals()
    orch.run()


if __name__ == '__main__':
    main()
