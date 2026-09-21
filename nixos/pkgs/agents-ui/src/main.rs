//! agents-ui: the interface of scripts/agents.sh.
//!
//! The bash script owns everything that happens (the job store, the hooks,
//! opening terminal windows); this app only shows that state and runs the
//! script's commands. It is started by plain `agents`, which passes the script,
//! the working directory and the state directory in the environment.
//!
//! The prompt box at the bottom is a real micro: it runs in a pty whose screen
//! is drawn into the box, and the keyboard goes straight to it, so editing,
//! pasting, undo and all of micro's keys work exactly as in the editor. The
//! app only keeps a few keys for itself: Enter sends (micro saves and quits,
//! we read the file), Tab toggles the send mode, Shift+Tab edits the "with #N"
//! field of the parallel mode (the prompt then waits until agent #N has
//! started and opens next to it), Esc moves the focus to the agent list where
//! single letters run the commands (p holds a queued agent back, e loads its
//! prompt into micro to change it). The mouse works too: the terminal reports
//! clicks as SGR escape sequences, which `App::mouse` matches against the
//! regions registered while drawing (rows, boxes, the mode badge, the help
//! keys); clicks on micro's screen are forwarded to it.

use std::{
    env, fs,
    io::{self, Read, Write},
    os::unix::{fs::symlink, process::CommandExt},
    path::{Path, PathBuf},
    process::{Command, Stdio},
    sync::{mpsc, Arc, Mutex},
    thread,
    time::{Duration, Instant, SystemTime, UNIX_EPOCH},
};

use portable_pty::{native_pty_system, Child, CommandBuilder, MasterPty, PtySize};
use ratatui::{
    crossterm::{
        event::{DisableBracketedPaste, DisableMouseCapture, EnableBracketedPaste, EnableMouseCapture},
        execute,
    },
    prelude::*,
    widgets::*,
    DefaultTerminal,
};
use tui_term::widget::PseudoTerminal;

#[derive(Clone, Copy, PartialEq)]
enum Mode {
    Queue,
    Parallel,
}

impl Mode {
    fn arg(self) -> &'static str {
        match self {
            Mode::Queue => "add",
            Mode::Parallel => "now",
        }
    }
    fn label(self) -> &'static str {
        match self {
            Mode::Queue => "QUEUE",
            Mode::Parallel => "PARALLEL",
        }
    }
    fn color(self) -> Color {
        match self {
            Mode::Queue => Color::Yellow,
            Mode::Parallel => Color::Magenta,
        }
    }
}

#[derive(Clone, Copy, PartialEq)]
enum Focus {
    Editor,
    List,
    /// The "with #N" field of the parallel mode.
    With,
}

struct Job {
    id: u32,
    status: String,
    mode: String,
    /// Parallel with this agent: queued until it has started.
    with: Option<u32>,
    prompt: String,
    since: u64,
    /// What it does right now (running), its last message (done/asks) or the error (failed).
    detail: String,
    session: String,
}

impl Job {
    fn alive(&self) -> bool {
        matches!(self.status.as_str(), "running" | "done" | "asks")
    }
    fn hot(&self) -> bool {
        self.alive() || self.waiting()
    }
    /// Its turn is over and the window waits for you.
    fn finished(&self) -> bool {
        matches!(self.status.as_str(), "done" | "asks")
    }
    /// The list is in zones, top to bottom: closed windows (the script
    /// forgets them after a while), finished turns, then working and queued.
    fn zone(&self) -> u8 {
        if !self.hot() {
            0
        } else if self.finished() {
            1
        } else {
            2
        }
    }
    /// Not started yet: queued, or held back.
    fn waiting(&self) -> bool {
        matches!(self.status.as_str(), "queued" | "held")
    }
    fn first_line(&self) -> &str {
        self.prompt.lines().next().unwrap_or("")
    }
}

/// One usage-limit window of the account (percent used, when it resets).
struct Limit {
    name: &'static str,
    pct: u64,
    resets: u64,
}

/// What a mouse click on a part of the screen does; the parts are registered
/// while drawing (see `App::hits`).
#[derive(Clone, Copy, PartialEq)]
enum Act {
    /// The agent table: click selects the row, double-click opens its window.
    Table,
    /// micro's screen: the click goes to micro, translated to its coordinates.
    Editor,
    /// The "with agent #" box.
    With,
    /// The mode badge, and the "Tab" key of the help line.
    Mode,
    FocusList,
    FocusEditor,
    /// One of the list's single-letter commands, as if typed.
    ListKey(u8),
    /// The confirm popup's answer.
    Answer(bool),
    /// A help label that has no click action.
    None,
}

/// A pending yes/no question and the script command it would run.
struct Confirm {
    question: String,
    args: Vec<String>,
}

/// Why micro was asked to quit, when not to send (see `App::check_editor`).
#[derive(Clone, Copy, PartialEq)]
enum Pending {
    /// Put the prompt of queued agent #N into the editor to change it.
    Load(u32),
    /// Stop editing that prompt; the draft from before comes back.
    Cancel,
}

/// micro running in a pty, drawn into the prompt box.
struct Editor {
    master: Box<dyn MasterPty + Send>,
    writer: Box<dyn Write + Send>,
    child: Box<dyn Child + Send + Sync>,
    parser: Arc<Mutex<vt100::Parser>>,
    size: (u16, u16),
}

struct App {
    sh: PathBuf,
    dir: PathBuf,
    state: PathBuf,
    slots: String,
    /// The account's usage limits (5-hour, weekly), refreshed by `agents __usage` in the background.
    limits: Vec<Limit>,
    /// When the limits were last fetched successfully (they stay on screen when a fetch fails).
    limits_at: Option<Instant>,
    jobs: Vec<Job>,
    sel: Option<u32>,
    table: TableState,
    mode: Mode,
    /// The agent number a parallel prompt should start with; empty ("-") = right away.
    with: String,
    focus: Focus,
    msg: String,
    confirm: Option<Confirm>,
    loaded: Instant,
    quit: bool,
    /// The file micro edits; its saved content is what gets sent.
    prompt_file: PathBuf,
    micro_config: PathBuf,
    editor: Option<Editor>,
    /// The editor holds the prompt of this queued agent: Enter saves it there instead of sending.
    editing: Option<u32>,
    /// micro was asked to quit for this, not to send.
    pending: Option<Pending>,
    /// The draft that was in the editor before a queued prompt was loaded; back once that is done.
    stash: Option<String>,
    editor_size: (u16, u16),
    in_paste: bool,
    /// Clickable parts of the last drawn frame, later ones on top.
    hits: Vec<(Rect, Act)>,
    /// Where micro's screen and the table's rows were drawn, for the mouse.
    editor_rect: Rect,
    rows_rect: Rect,
    /// The last click, to see a double-click.
    last_click: Option<(Instant, u16, u16)>,
    /// A button went down on micro's screen: the drag and release are its too.
    drag_editor: bool,
}

fn now() -> u64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_secs()).unwrap_or(0)
}

fn read(p: &Path) -> String {
    fs::read_to_string(p).map(|s| s.trim_end().to_string()).unwrap_or_default()
}

fn read_num(p: &Path) -> Option<u64> {
    read(p).parse().ok()
}

fn fmt_dur(s: u64) -> String {
    if s >= 86400 {
        format!("{}d{}h", s / 86400, s % 86400 / 3600)
    } else if s >= 3600 {
        format!("{}h{:02}m", s / 3600, s % 3600 / 60)
    } else if s >= 60 {
        format!("{}m{:02}s", s / 60, s % 60)
    } else {
        format!("{s}s")
    }
}

/// The path with $HOME shortened to ~, for the header.
fn home_tilde(p: &Path) -> String {
    let s = p.display().to_string();
    match env::var("HOME") {
        Ok(h) if !h.is_empty() && s.starts_with(&h) => format!("~{}", &s[h.len()..]),
        _ => s,
    }
}

fn squash(s: &str) -> String {
    s.split_whitespace().collect::<Vec<_>>().join(" ")
}

/// What a working agent is up to, from the tail of its transcript: one line
/// saying what it does, or the question it is waiting on (an AskUserQuestion
/// dialog blocks the turn, so the hooks do not see it end).
enum Activity {
    Doing(String),
    Asking(String),
}

fn activity(transcript: &str) -> Activity {
    use std::io::{Seek, SeekFrom};
    let Ok(mut f) = fs::File::open(transcript) else {
        return Activity::Doing("(starting)".into());
    };
    let len = f.metadata().map(|m| m.len()).unwrap_or(0);
    let take = len.min(96 * 1024);
    if f.seek(SeekFrom::Start(len - take)).is_err() {
        return Activity::Doing(String::new());
    }
    let mut raw = Vec::new();
    if f.read_to_end(&mut raw).is_err() {
        return Activity::Doing(String::new());
    }
    let buf = String::from_utf8_lossy(&raw);
    let mut last = String::new();
    // A question dialog the user has not answered yet: its tool_use without a tool_result after it.
    let mut question: Option<String> = None;
    // The first line may be a partial one when we started mid-file.
    for line in buf.lines().skip(if take < len { 1 } else { 0 }) {
        let Ok(j) = serde_json::from_str::<serde_json::Value>(line) else {
            continue;
        };
        if j["isSidechain"].as_bool() == Some(true) {
            continue;
        }
        if j["type"] == "user" {
            question = None;
            continue;
        }
        if j["type"] != "assistant" {
            continue;
        }
        let Some(content) = j["message"]["content"].as_array() else {
            continue;
        };
        for c in content {
            match c["type"].as_str() {
                Some("tool_use") => {
                    let i = &c["input"];
                    if c["name"] == "AskUserQuestion" {
                        let qs: Vec<&str> = i["questions"].as_array().into_iter().flatten().filter_map(|q| q["question"].as_str()).collect();
                        question = Some(squash(&qs.join(" ")));
                    }
                    let arg = ["command", "file_path", "pattern", "description", "prompt", "query"]
                        .iter()
                        .find_map(|k| i[k].as_str())
                        .unwrap_or("");
                    last = format!("{}: {}", c["name"].as_str().unwrap_or("?"), squash(arg));
                }
                Some("text") => {
                    if let Some(t) = c["text"].as_str().filter(|t| !t.is_empty()) {
                        last = format!("\"{}\"", squash(t));
                    }
                }
                _ => {}
            }
        }
    }
    if let Some(q) = question {
        Activity::Asking(q)
    } else if last.is_empty() {
        Activity::Doing("(starting)".into())
    } else {
        Activity::Doing(last)
    }
}

/// Asks the script for the account's usage limits every minute (the endpoint
/// is rate limited) and hands each answer to the main loop: the limits, or
/// None when the fetch failed (offline, login token expired).
fn poll_limits(sh: PathBuf, dir: PathBuf, tx: mpsc::Sender<Option<Vec<Limit>>>) {
    thread::spawn(move || loop {
        let out = Command::new(&sh)
            .arg("__usage")
            .current_dir(&dir)
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .output();
        let limits = out.map(|out| {
            String::from_utf8_lossy(&out.stdout)
                .lines()
                .filter_map(|l| {
                    let mut f = l.split_whitespace();
                    let name = match f.next()? {
                        "five_hour" => "5h",
                        "seven_day" => "week",
                        _ => return None,
                    };
                    Some(Limit { name, pct: f.next()?.parse().ok()?, resets: f.next()?.parse().ok()? })
                })
                .collect::<Vec<_>>()
        });
        if tx.send(limits.ok().filter(|l| !l.is_empty())).is_err() {
            break;
        }
        thread::sleep(Duration::from_secs(60));
    });
}

/// A config dir for the embedded micro: the user's own settings, plugins and
/// colorschemes (symlinked), plus Ctrl-s = save and quit, which is how Enter
/// hands the text over.
fn micro_config_dir(state: &Path) -> PathBuf {
    let ours = state.join("micro-config");
    let _ = fs::remove_dir_all(&ours);
    let _ = fs::create_dir_all(&ours);
    let home = env::var("HOME").unwrap_or_default();
    let theirs = env::var("MICRO_CONFIG_HOME")
        .map(PathBuf::from)
        .or_else(|_| env::var("XDG_CONFIG_HOME").map(|x| PathBuf::from(x).join("micro")))
        .unwrap_or_else(|_| PathBuf::from(&home).join(".config/micro"));
    let mut bindings = serde_json::Map::new();
    if let Ok(entries) = fs::read_dir(&theirs) {
        for e in entries.flatten() {
            let name = e.file_name();
            if name == "bindings.json" {
                if let Ok(serde_json::Value::Object(m)) = serde_json::from_str(&read(&e.path())) {
                    bindings = m;
                }
                continue;
            }
            let _ = symlink(e.path(), ours.join(&name));
        }
    }
    bindings.insert("Ctrl-s".into(), "Save,Quit".into());
    let _ = fs::write(ours.join("bindings.json"), serde_json::Value::Object(bindings).to_string());
    ours
}

impl App {
    fn new() -> Result<App, String> {
        let sh = env::var("AGENTS_SH").map_err(|_| "AGENTS_SH not set: start this through `agents`".to_string())?;
        let state = env::var("AGENTS_STATE_DIR").map_err(|_| "AGENTS_STATE_DIR not set".to_string())?;
        let dir = env::var("AGENTS_DIR").map(PathBuf::from).or_else(|_| env::current_dir()).map_err(|e| e.to_string())?;
        let state = PathBuf::from(state);
        let mode = if read(&state.join("uimode")) == "now" { Mode::Parallel } else { Mode::Queue };
        let mut app = App {
            sh: PathBuf::from(sh),
            dir,
            slots: env::var("AGENTS_SLOTS").unwrap_or_else(|_| "1".into()),
            limits: Vec::new(),
            limits_at: None,
            jobs: Vec::new(),
            sel: None,
            table: TableState::default(),
            mode,
            with: String::new(),
            focus: Focus::Editor,
            msg: String::new(),
            confirm: None,
            loaded: Instant::now(),
            quit: false,
            prompt_file: state.join("prompt.md"),
            micro_config: micro_config_dir(&state),
            editor: None,
            editing: None,
            pending: None,
            stash: None,
            editor_size: (8, 80),
            in_paste: false,
            hits: Vec::new(),
            editor_rect: Rect::default(),
            rows_rect: Rect::default(),
            last_click: None,
            drag_editor: false,
            state,
        };
        app.load();
        Ok(app)
    }

    /// Run a script command; returns (success, its output).
    fn run(&self, args: &[&str], stdin: Option<&str>) -> (bool, String) {
        let mut cmd = Command::new(&self.sh);
        cmd.args(args).current_dir(&self.dir).stdin(if stdin.is_some() { Stdio::piped() } else { Stdio::null() });
        let mut child = match cmd.stdout(Stdio::piped()).stderr(Stdio::piped()).spawn() {
            Ok(c) => c,
            Err(e) => return (false, format!("cannot run {}: {e}", self.sh.display())),
        };
        if let (Some(text), Some(mut pipe)) = (stdin, child.stdin.take()) {
            let _ = pipe.write_all(text.as_bytes());
        }
        let out = match child.wait_with_output() {
            Ok(o) => o,
            Err(e) => return (false, e.to_string()),
        };
        let mut text = String::from_utf8_lossy(&out.stdout).trim().to_string();
        let err = String::from_utf8_lossy(&out.stderr).trim().to_string();
        if !err.is_empty() {
            if !text.is_empty() {
                text.push(' ');
            }
            text.push_str(&err);
        }
        (out.status.success(), squash(&text))
    }

    fn load(&mut self) {
        self.loaded = Instant::now();
        // The script's reaper notices closed windows; run it before reading.
        let _ = self.run(&["__reap"], None);
        let mut jobs = Vec::new();
        let Ok(entries) = fs::read_dir(self.state.join("jobs")) else {
            self.jobs = jobs;
            return;
        };
        for e in entries.flatten() {
            let jd = e.path();
            let Some(id) = jd.file_name().and_then(|n| n.to_str()).and_then(|n| n.parse::<u32>().ok()) else {
                continue;
            };
            let status = read(&jd.join("status"));
            let started = read_num(&jd.join("started"));
            let created = read_num(&jd.join("created")).unwrap_or(0);
            let ended = read_num(&jd.join("ended"));
            let since = match status.as_str() {
                "queued" => now().saturating_sub(created),
                "running" => now().saturating_sub(started.unwrap_or(created)),
                // The time stops when the turn ended.
                "done" | "asks" => read_num(&jd.join("turn")).unwrap_or_else(now).saturating_sub(started.unwrap_or(created)),
                _ => ended.unwrap_or_else(now).saturating_sub(started.unwrap_or(created)),
            };
            let mut status = status;
            if status == "queued" && jd.join("hold").exists() {
                status = "held".into();
            }
            let detail = match status.as_str() {
                // A question dialog mid-turn shows as asking, like a turn that ended with one.
                "running" => match activity(&read(&jd.join("transcript"))) {
                    Activity::Doing(d) => d,
                    Activity::Asking(q) => {
                        status = "asks".into();
                        q
                    }
                },
                "done" | "asks" => read(&jd.join("last")),
                "failed" => read(&jd.join("err")),
                _ => String::new(),
            };
            jobs.push(Job {
                id,
                status,
                mode: read(&jd.join("mode")),
                with: read_num(&jd.join("with")).map(|n| n as u32),
                prompt: read(&jd.join("prompt")),
                since,
                detail,
                session: read(&jd.join("session")),
            });
        }
        // Three zones with a rule between them (see `zone`): closed agents at
        // the top, then finished turns (done, asking), then the working and
        // queued ones at the bottom, each oldest first. An agent you talk to
        // again is working and drops back down.
        jobs.sort_by_key(|j| (j.zone(), j.id));
        self.jobs = jobs;
        // Nothing (valid) selected: the oldest working agent, the first row
        // below the rules; else the first queued one, else whatever is on top.
        if !self.jobs.iter().any(|j| Some(j.id) == self.sel) {
            let pick = |f: &dyn Fn(&Job) -> bool| self.jobs.iter().find(|j| f(j)).map(|j| j.id);
            self.sel = pick(&|j| j.status == "running").or_else(|| pick(&|j| j.zone() == 2)).or_else(|| pick(&|_| true));
        }
        self.table.select(self.sel_index().map(|i| self.row_of(i)));
        // The prompt being edited belongs to an agent that started or went away meanwhile.
        if let Some(id) = self.editing {
            if !self.jobs.iter().any(|j| j.id == id && j.waiting()) {
                self.editing = None;
                self.msg = format!("#{id} is not queued any more: Enter sends the prompt as a new agent");
            }
        }
    }

    fn sel_index(&self) -> Option<usize> {
        self.jobs.iter().position(|j| Some(j.id) == self.sel)
    }

    /// The rules between the zones: the index of each job that starts a new
    /// zone (the rule is drawn right above it), so only where both sides have
    /// something.
    fn rules(&self) -> Vec<usize> {
        (1..self.jobs.len()).filter(|&i| self.jobs[i].zone() != self.jobs[i - 1].zone()).collect()
    }

    /// Table row of the i-th job: every rule above it takes a row of its own.
    fn row_of(&self, i: usize) -> usize {
        i + self.rules().iter().filter(|&&r| r <= i).count()
    }

    fn job_at_row(&self, row: usize) -> Option<usize> {
        (0..self.jobs.len()).find(|&i| self.row_of(i) == row)
    }

    fn selected(&self) -> Option<&Job> {
        self.sel_index().map(|i| &self.jobs[i])
    }

    fn move_sel(&mut self, delta: isize) {
        if self.jobs.is_empty() {
            return;
        }
        let i = self.sel_index().unwrap_or(0) as isize + delta;
        let i = i.clamp(0, self.jobs.len() as isize - 1) as usize;
        self.sel = Some(self.jobs[i].id);
        self.table.select(Some(self.row_of(i)));
    }

    fn counts(&self) -> (usize, usize, usize, usize, usize) {
        let n = |s: &str| self.jobs.iter().filter(|j| j.status == s).count();
        (n("running"), n("done"), n("asks"), n("queued") + n("held"), n("held"))
    }

    fn toggle_mode(&mut self) {
        self.mode = if self.mode == Mode::Queue { Mode::Parallel } else { Mode::Queue };
        let _ = fs::write(self.state.join("uimode"), self.mode.arg());
        if self.focus == Focus::With {
            self.focus = Focus::Editor;
        }
    }

    /// The agent number of the "with" field, if it is set.
    fn with_id(&self) -> Option<u32> {
        (self.mode == Mode::Parallel).then(|| self.with.parse().ok()).flatten()
    }

    /// The "with" field points at an agent that is not in the list.
    fn with_unknown(&self) -> bool {
        self.with_id().is_some_and(|id| !self.jobs.iter().any(|j| j.id == id))
    }

    /// The script command that sends a prompt in the current mode.
    fn send_args(&self) -> Vec<String> {
        let mut args = vec![self.mode.arg().to_string()];
        if let Some(id) = self.with_id() {
            args.push("-w".into());
            args.push(id.to_string());
        }
        args
    }

    /// Shift+Tab: into the "with #N" field of the parallel mode, and back out.
    fn toggle_with(&mut self) {
        if self.focus == Focus::With {
            self.focus = Focus::Editor;
            return;
        }
        if self.mode != Mode::Parallel {
            self.toggle_mode();
        }
        self.focus = Focus::With;
    }

    /// Typing in the "with #N" field: digits, Backspace, "-" clears, Enter/Esc leave.
    fn key_with(&mut self, b: u8) {
        match b {
            b'0'..=b'9' if self.with.len() < 4 => self.with.push(b as char),
            0x7f | 0x08 => {
                self.with.pop();
            }
            b'-' | 0x15 => self.with.clear(), // Ctrl+U too
            b'\r' | b'\n' => self.focus = Focus::Editor,
            _ => {}
        }
    }

    fn act(&mut self, args: &[&str]) {
        let (_, out) = self.run(args, None);
        self.msg = out;
        self.load();
    }

    fn ask(&mut self, question: &str, args: &[&str]) {
        self.confirm = Some(Confirm { question: question.into(), args: args.iter().map(|s| s.to_string()).collect() });
    }

    /// Something to read (a transcript, the notes) opens in its own terminal
    /// window, like the agents themselves.
    fn open_window(&mut self, title: &str, shell_cmd: &str) {
        let term = env::var("AGENTS_TERM").unwrap_or_else(|_| "kitty".into());
        let mut cmd = Command::new(&term);
        cmd.args(["--title", title, "-d"]).arg(&self.dir).args(["sh", "-c", shell_cmd]);
        cmd.stdin(Stdio::null()).stdout(Stdio::null()).stderr(Stdio::null()).process_group(0);
        if let Err(e) = cmd.spawn() {
            self.msg = format!("cannot start {term}: {e}");
        }
    }

    // -- the embedded editor

    fn spawn_editor(&mut self) {
        let (rows, cols) = self.editor_size;
        let pty = native_pty_system();
        let pair = match pty.openpty(PtySize { rows, cols, pixel_width: 0, pixel_height: 0 }) {
            Ok(p) => p,
            Err(e) => {
                self.msg = format!("no pty for the editor: {e}");
                return;
            }
        };
        let editor = env::var("AGENTS_EDITOR").unwrap_or_else(|_| "micro".into());
        let mut cmd = CommandBuilder::new(&editor);
        if editor == "micro" || editor.ends_with("/micro") {
            cmd.arg("-config-dir");
            cmd.arg(&self.micro_config);
        }
        // Started in the state dir so micro shows a plain "prompt.md".
        cmd.arg("prompt.md");
        cmd.cwd(&self.state);
        cmd.env("TERM", "xterm-256color");
        let child = match pair.slave.spawn_command(cmd) {
            Ok(c) => c,
            Err(e) => {
                self.msg = format!("cannot start {editor}: {e}");
                return;
            }
        };
        drop(pair.slave);
        let (Ok(mut reader), Ok(writer)) = (pair.master.try_clone_reader(), pair.master.take_writer()) else {
            self.msg = "cannot talk to the editor's pty".into();
            return;
        };
        let parser = Arc::new(Mutex::new(vt100::Parser::new(rows, cols, 0)));
        let sink = parser.clone();
        thread::spawn(move || {
            let mut buf = [0u8; 8192];
            while let Ok(n) = reader.read(&mut buf) {
                if n == 0 {
                    break;
                }
                if let Ok(mut p) = sink.lock() {
                    p.process(&buf[..n]);
                }
            }
        });
        self.editor = Some(Editor { master: pair.master, writer, child, parser, size: (rows, cols) });
    }

    fn editor_write(&mut self, bytes: &[u8]) {
        if let Some(ed) = &mut self.editor {
            let _ = ed.writer.write_all(bytes);
            let _ = ed.writer.flush();
        }
    }

    fn resize_editor(&mut self, rows: u16, cols: u16) {
        self.editor_size = (rows.max(2), cols.max(10));
        if let Some(ed) = &mut self.editor {
            if ed.size != self.editor_size {
                ed.size = self.editor_size;
                let _ = ed.master.resize(PtySize { rows: ed.size.0, cols: ed.size.1, pixel_width: 0, pixel_height: 0 });
                if let Ok(mut p) = ed.parser.lock() {
                    p.screen_mut().set_size(ed.size.0, ed.size.1);
                }
            }
        }
    }

    /// micro has quit: whatever it saved is the prompt to send (or, while a
    /// queued agent's prompt is being edited, its new prompt), unless it was
    /// asked to quit for something else. Then start it again for the next one.
    fn check_editor(&mut self) {
        if let Some(ed) = &mut self.editor {
            if !matches!(ed.child.try_wait(), Ok(Some(_))) {
                return;
            }
            self.editor = None;
            if self.pending.is_none() {
                self.send_prompt();
            }
        }
        // Not running: it just quit, or this is the first start (the file
        // keeps whatever draft was in it).
        match self.pending.take() {
            Some(Pending::Load(id)) => self.load_prompt(id),
            Some(Pending::Cancel) => self.cancel_edit(),
            None => {}
        }
        self.spawn_editor();
    }

    /// The saved prompt file goes out: to the script as a new agent, or into
    /// the queued agent whose prompt is being edited.
    fn send_prompt(&mut self) {
        let text = fs::read_to_string(&self.prompt_file).unwrap_or_default();
        if text.trim().is_empty() {
            self.restore_stash();
            return;
        }
        let ok = if let Some(id) = self.editing {
            let (ok, out) = self.run(&["edit", &id.to_string()], Some(text.trim_end()));
            self.msg = out;
            if ok {
                self.editing = None;
            }
            ok
        } else {
            let args = self.send_args();
            let args: Vec<&str> = args.iter().map(String::as_str).collect();
            let (ok, out) = self.run(&args, Some(text.trim_end()));
            self.msg = out;
            if ok {
                // "with #N" is for that one prompt; the next one runs right away again.
                self.with.clear();
            }
            ok
        };
        if ok {
            self.restore_stash();
        }
        self.load();
    }

    /// The next editor starts on the draft that was set aside, if any, else empty.
    fn restore_stash(&mut self) {
        let _ = fs::write(&self.prompt_file, self.stash.take().unwrap_or_default());
    }

    /// Ask micro to save and quit so that `check_editor` can do `p` with the file.
    fn request(&mut self, p: Pending) {
        self.pending = Some(p);
        if self.editor.is_some() {
            self.editor_write(b"\x13");
        }
    }

    /// The editor is not running: put #N's prompt into its file, keeping the
    /// draft that was there for later.
    fn load_prompt(&mut self, id: u32) {
        let Some(prompt) = self.jobs.iter().find(|j| j.id == id).map(|j| j.prompt.clone()) else {
            self.msg = format!("there is no agent #{id}");
            return;
        };
        let draft = fs::read_to_string(&self.prompt_file).unwrap_or_default();
        if self.editing.is_none() && !draft.trim().is_empty() {
            self.stash = Some(draft);
        }
        let _ = fs::write(&self.prompt_file, prompt + "\n");
        self.editing = Some(id);
        self.msg = format!("editing the prompt of #{id}: Enter saves it, e in the list cancels");
    }

    fn cancel_edit(&mut self) {
        self.editing = None;
        self.restore_stash();
        self.msg = "edit cancelled".into();
    }

    // -- keys

    /// Raw bytes from the terminal. With the editor focused nearly everything
    /// goes to micro untouched; the app only takes Enter, Tab, Shift+Tab and a
    /// lone Esc.
    fn input(&mut self, bytes: &[u8]) {
        let mut i = 0;
        let mut pass: Vec<u8> = Vec::new();
        while i < bytes.len() {
            let b = bytes[i];
            // Escape sequences: bracketed paste markers, arrows, Alt+key.
            if b == 0x1b {
                let rest = &bytes[i + 1..];
                let seq_len = match rest.first() {
                    Some(b'[') | Some(b'O') => {
                        1 + rest[1..].iter().position(|&c| (0x40..=0x7e).contains(&c)).map(|p| p + 1).unwrap_or(rest.len() - 1)
                    }
                    Some(_) => 1,
                    None => 0,
                };
                let seq = &bytes[i..i + 1 + seq_len];
                i += 1 + seq_len;
                match seq {
                    b"\x1b[200~" => self.in_paste = true,
                    b"\x1b[201~" => self.in_paste = false,
                    _ => {}
                }
                if self.in_paste || seq == b"\x1b[200~" || seq == b"\x1b[201~" {
                    pass.extend_from_slice(seq);
                    continue;
                }
                if seq.starts_with(b"\x1b[<") {
                    self.flush_pass(&mut pass);
                    self.mouse(seq);
                    continue;
                }
                match (self.focus, seq) {
                    (_, b"\x1b") => {
                        self.flush_pass(&mut pass);
                        self.key_esc();
                    }
                    (_, b"\x1b[Z") => {
                        // Shift+Tab: the "with #N" field
                        self.flush_pass(&mut pass);
                        self.toggle_with();
                    }
                    (Focus::Editor, b"\x1b\r") | (Focus::Editor, b"\x1b\n") => pass.push(b'\r'), // Alt+Enter: newline
                    (Focus::Editor, _) => pass.extend_from_slice(seq),
                    (Focus::List, b"\x1b[A") | (Focus::List, b"\x1bOA") => self.move_sel(-1),
                    (Focus::List, b"\x1b[B") | (Focus::List, b"\x1bOB") => self.move_sel(1),
                    (Focus::List, b"\x1b[5~") => self.move_sel(-10),
                    (Focus::List, b"\x1b[6~") => self.move_sel(10),
                    (Focus::List, _) | (Focus::With, _) => {}
                }
                continue;
            }
            i += 1;
            if self.in_paste {
                pass.push(b);
                continue;
            }
            if self.confirm.is_some() {
                self.flush_pass(&mut pass);
                let c = self.confirm.take().unwrap();
                if b == b'y' || b == b'Y' {
                    let args: Vec<&str> = c.args.iter().map(String::as_str).collect();
                    self.act(&args);
                } else {
                    self.msg = "cancelled".into();
                }
                continue;
            }
            match (self.focus, b) {
                (_, b'\t') => {
                    self.flush_pass(&mut pass);
                    self.toggle_mode();
                }
                (Focus::Editor, b'\r') => {
                    // Send: micro saves and quits (our Ctrl-s binding), check_editor picks the file up.
                    pass.extend_from_slice(b"\x13");
                }
                (Focus::Editor, b'\n') => pass.push(b'\r'), // Ctrl+J: newline
                (Focus::Editor, _) => pass.push(b),
                (Focus::List, _) => {
                    self.flush_pass(&mut pass);
                    self.key_list(b);
                }
                (Focus::With, _) => {
                    self.flush_pass(&mut pass);
                    self.key_with(b);
                }
            }
        }
        self.flush_pass(&mut pass);
    }

    fn flush_pass(&mut self, pass: &mut Vec<u8>) {
        if !pass.is_empty() {
            let bytes = std::mem::take(pass);
            self.editor_write(&bytes);
        }
    }

    /// An SGR mouse report: `ESC [ < button ; x ; y M` (press, drag, wheel)
    /// or `... m` (release), 1-based coordinates.
    fn mouse(&mut self, seq: &[u8]) {
        let release = seq.last() == Some(&b'm');
        let body = String::from_utf8_lossy(&seq[3..seq.len() - 1]);
        let mut nums = body.split(';').map(|n| n.parse::<u16>().unwrap_or(0));
        let (Some(b), Some(x), Some(y)) = (nums.next(), nums.next(), nums.next()) else {
            return;
        };
        let (x, y) = (x.saturating_sub(1), y.saturating_sub(1));
        let wheel = b & 64 != 0;
        let motion = b & 32 != 0;
        let at = |r: Rect| x >= r.x && x < r.x + r.width && y >= r.y && y < r.y + r.height;

        // micro gets every event on its screen, and the rest of a drag that started there.
        if self.editor.is_some() && (self.drag_editor || at(self.editor_rect)) {
            if !wheel && !motion && !release {
                self.drag_editor = true;
                self.focus = Focus::Editor;
            }
            if release {
                self.drag_editor = false;
            }
            let ed = self.editor_rect;
            let (ex, ey) = (x.saturating_sub(ed.x).min(ed.width.saturating_sub(1)) + 1, y.saturating_sub(ed.y).min(ed.height.saturating_sub(1)) + 1);
            let bytes = format!("\x1b[<{b};{ex};{ey}{}", if release { 'm' } else { 'M' });
            self.editor_write(bytes.as_bytes());
            return;
        }
        if wheel {
            if at(self.rows_rect) {
                self.move_sel(if b & 1 == 0 { -1 } else { 1 });
            }
            return;
        }
        if motion || release || b & 3 != 0 {
            return; // only the left button does things
        }
        let act = self.hits.iter().rev().find(|(r, _)| at(*r)).map(|(_, a)| *a);
        if self.confirm.is_some() {
            // Modal: only its buttons count.
            if let Some(Act::Answer(yes)) = act {
                let c = self.confirm.take().unwrap();
                if yes {
                    let args: Vec<&str> = c.args.iter().map(String::as_str).collect();
                    self.act(&args);
                } else {
                    self.msg = "cancelled".into();
                }
            }
            return;
        }
        let double = self.last_click.is_some_and(|(t, lx, ly)| t.elapsed() < Duration::from_millis(400) && lx == x && ly == y);
        self.last_click = Some((Instant::now(), x, y));
        match act {
            Some(Act::Table) => {
                let row = (y - self.rows_rect.y) as usize + self.table.offset();
                if let Some(job) = self.job_at_row(row).map(|i| &self.jobs[i]) {
                    let id = job.id;
                    self.msg.clear();
                    self.sel = Some(id);
                    self.table.select(Some(row));
                    self.focus = Focus::List;
                    if double {
                        self.act(&["open", &id.to_string()]);
                    }
                }
            }
            Some(Act::Editor) => self.focus = Focus::Editor,
            Some(Act::With) => {
                if self.mode != Mode::Parallel {
                    self.toggle_mode();
                }
                self.focus = Focus::With;
            }
            Some(Act::Mode) => self.toggle_mode(),
            Some(Act::FocusList) => {
                self.msg.clear();
                self.focus = Focus::List;
            }
            Some(Act::FocusEditor) => {
                self.msg.clear();
                self.focus = Focus::Editor;
            }
            Some(Act::ListKey(k)) => self.key_list(k),
            _ => {}
        }
    }

    fn key_esc(&mut self) {
        self.msg.clear();
        self.focus = match self.focus {
            Focus::Editor => Focus::List,
            Focus::List | Focus::With => Focus::Editor,
        };
    }

    /// Single-letter commands while the list has the focus.
    fn key_list(&mut self, b: u8) {
        self.msg.clear();
        let sel = self.sel.map(|id| id.to_string());
        match b {
            b'q' | b'Q' | 0x11 | 0x03 => self.quit = true,
            b'i' | b'I' => self.focus = Focus::Editor,
            b'\r' | b'o' | b'O' | 0x0f => {
                if let Some(id) = &sel {
                    self.act(&["open", id]);
                }
            }
            b'k' | b'K' | 0x0b => {
                if let Some(id) = &sel {
                    self.ask(&format!("Close the window of #{id}?"), &["kill", id]);
                }
            }
            b'd' | b'D' | 0x04 => {
                if let (Some(id), Some(job)) = (&sel, self.selected()) {
                    if job.alive() {
                        self.ask(&format!("Remove #{id} and close its window?"), &["drop", id]);
                    } else {
                        self.act(&["drop", id]);
                    }
                }
            }
            b'h' | b'H' => {
                if let Some(id) = &sel {
                    self.act(&["hide", id]);
                }
            }
            b'r' | b'R' | 0x12 => {
                if let Some(id) = &sel {
                    self.act(&["retry", id]);
                }
            }
            b'p' | b'P' | 0x10 => {
                // Hold a queued agent back (it does not start whatever frees up), or let it go again.
                if let (Some(id), Some(job)) = (&sel, self.selected()) {
                    match job.status.as_str() {
                        "queued" => self.act(&["hold", id]),
                        "held" => self.act(&["release", id]),
                        _ => self.msg = format!("#{id} is not queued"),
                    }
                }
            }
            b'e' | b'E' | 0x05 => {
                // The prompt of a queued agent goes into the editor; Enter there saves it back.
                if let (Some(id), Some(job)) = (self.sel, self.selected()) {
                    if self.editing == Some(id) {
                        self.request(Pending::Cancel);
                    } else if job.waiting() {
                        self.request(Pending::Load(id));
                        self.focus = Focus::Editor;
                    } else {
                        self.msg = format!("#{id} has started: r queues its prompt again");
                    }
                }
            }
            b'w' | b'W' | 0x17 => {
                // The next prompt runs in parallel with the selected agent.
                if let Some(id) = &sel {
                    self.with = id.clone();
                    if self.mode != Mode::Parallel {
                        self.toggle_mode();
                    }
                    self.focus = Focus::Editor;
                }
            }
            b'x' | b'X' | 0x18 => self.ask("Clear all finished agents? Done ones get their windows closed.", &["clear"]),
            b'l' | b'L' | 0x0c => {
                if let Some(id) = &sel {
                    let cmd = format!("'{}' log '{}' | less -R +G", self.sh.display(), id);
                    self.open_window(&format!("agent #{id}: transcript"), &cmd);
                }
            }
            b'n' | b'N' | 0x0e => {
                let pager = env::var("PAGER").unwrap_or_else(|_| "less -R".into());
                let cmd = format!("{pager} '{}'", self.state.join("notes.md").display());
                self.open_window("agents: notes", &cmd);
            }
            _ => {}
        }
    }
}

// ---------------------------------------------------------------- drawing

fn status_style(st: &str) -> Style {
    match st {
        "running" => Style::new().fg(Color::Red).bold(),
        "done" => Style::new().fg(Color::Green),
        "asks" => Style::new().fg(Color::Magenta).bold(),
        "queued" => Style::new().fg(Color::Yellow),
        "held" => Style::new().fg(Color::Blue).bold(),
        "failed" | "killed" => Style::new().fg(Color::Red),
        _ => Style::new().dim(),
    }
}

fn status_word(st: &str) -> &str {
    match st {
        "running" => "● working",
        "done" => "✓ done",
        "asks" => "? asking",
        "queued" => "· queued",
        "held" => "‖ held",
        "exited" => "  closed",
        "failed" => "✗ failed",
        "killed" => "✗ killed",
        other => other,
    }
}

/// A line of "key what-it-does" pairs. Drawn at `at` (its left end), each pair
/// with an action becomes a clickable button.
fn key_help<'a>(hits: &mut Vec<(Rect, Act)>, at: (u16, u16), pairs: &[(&'a str, &'a str, Act)]) -> Line<'a> {
    let mut spans = Vec::new();
    let mut x = at.0;
    for (i, (k, d, act)) in pairs.iter().enumerate() {
        if i > 0 {
            spans.push(Span::raw("  "));
            x += 2;
        }
        let w = (k.chars().count() + 1 + d.chars().count()) as u16;
        if *act != Act::None {
            hits.push((Rect::new(x, at.1, w, 1), *act));
        }
        x += w;
        spans.push(Span::styled(*k, Style::new().bold()));
        spans.push(Span::styled(format!(" {d}"), Style::new().dim()));
    }
    Line::from(spans)
}

/// A thin bracket beside the ids that joins each "with #N" job to agent #N:
/// ╭ on the group's first row, ├ on its other members, ╰ on its last, and │
/// on rows in between that are not part of it. Groups that overlap share it.
fn link_column(jobs: &[Job]) -> Vec<char> {
    let mut col = vec![' '; jobs.len()];
    let mut targets: Vec<u32> = Vec::new();
    for j in jobs {
        if let Some(w) = j.with {
            if !targets.contains(&w) && jobs.iter().any(|t| t.id == w) {
                targets.push(w);
            }
        }
    }
    for t in targets {
        let members: Vec<usize> = (0..jobs.len()).filter(|&i| jobs[i].id == t || jobs[i].with == Some(t)).collect();
        let (top, bottom) = (members[0], members[members.len() - 1]);
        for i in top..=bottom {
            let c = if i == top {
                '╭'
            } else if i == bottom {
                '╰'
            } else if members.contains(&i) {
                '├'
            } else {
                '│'
            };
            col[i] = match (col[i], c) {
                (' ', c) | ('│', c) => c,
                (old, '│') => old,
                (old, new) if old == new => old,
                _ => '├',
            };
        }
    }
    col
}

fn frame_block(title: impl Into<Line<'static>>, focused: bool, color: Color) -> Block<'static> {
    let style = if focused { Style::new().fg(color) } else { Style::new().dim() };
    Block::bordered().border_type(BorderType::Rounded).border_style(style).title(title)
}

/// Returns the inner area of the editor box, so the pty can follow its size.
fn draw(f: &mut Frame, app: &mut App) -> Rect {
    let area = f.area();
    let editor_h = (area.height / 4).clamp(5, 8);
    let chunks = Layout::vertical([
        Constraint::Length(1),
        Constraint::Min(4),
        Constraint::Length(4),
        Constraint::Length(editor_h),
        Constraint::Length(1),
        Constraint::Length(1),
    ])
    .split(area);
    app.hits.clear();

    // Header: where we are, how many agents do what, the send mode on the right.
    let (working, done, asking, queued, held) = app.counts();
    let mode = match app.with_id() {
        Some(id) => format!(" {} with #{id} ", app.mode.label()),
        None => format!(" {} ", app.mode.label()),
    };
    let mut left = vec![
        Span::styled(" agents ", Style::new().bold().reversed()),
        Span::raw(" "),
        Span::styled(home_tilde(&app.dir), Style::new().dim()),
        Span::raw("   "),
        Span::styled(format!("{working} working"), status_style("running")),
        Span::raw("  "),
        Span::styled(format!("{done} done"), status_style("done")),
        Span::raw("  "),
        Span::styled(format!("{queued} queued"), status_style("queued")),
    ];
    if held > 0 {
        left.push(Span::styled(format!(" ({held} held)"), status_style("held")));
    }
    if asking > 0 {
        left.push(Span::raw("  "));
        left.push(Span::styled(format!("{asking} asking you"), status_style("asks")));
    }
    left.push(Span::styled(format!("   {} slot(s)", app.slots), Style::new().dim()));
    // Usage limits: "5h 24% (3h58m)  week 54% (4d2h)" -- percent used, time until the reset.
    for (i, l) in app.limits.iter().enumerate() {
        let pct_style = match l.pct {
            90.. => Style::new().fg(Color::Red).bold(),
            70.. => Style::new().fg(Color::Yellow),
            _ => Style::new().fg(Color::Green),
        };
        left.push(Span::styled(if i == 0 { "   " } else { "  " }, Style::new()));
        left.push(Span::styled(format!("{} ", l.name), Style::new().dim()));
        left.push(Span::styled(format!("{}%", l.pct), pct_style));
        if l.resets > 0 {
            left.push(Span::styled(format!(" ({})", fmt_dur(l.resets.saturating_sub(now()))), Style::new().dim()));
        }
    }
    // Fetches keep failing (offline, or the login token expired and no claude
    // session has refreshed it): say how old the numbers are.
    if let Some(age) = app.limits_at.map(|t| t.elapsed().as_secs()).filter(|&s| s >= 180) {
        left.push(Span::styled(format!(" (as of {} ago)", fmt_dur(age)), Style::new().fg(Color::Yellow)));
    }
    let used: usize = left.iter().map(|s| s.content.chars().count()).sum();
    let pad = (area.width as usize).saturating_sub(used + mode.chars().count() + 1);
    left.push(Span::raw(" ".repeat(pad)));
    let mode_w = mode.chars().count() as u16;
    app.hits.push((Rect::new(((used + pad) as u16).min(area.width.saturating_sub(mode_w)), chunks[0].y, mode_w, 1), Act::Mode));
    left.push(Span::styled(mode, Style::new().fg(Color::Black).bg(app.mode.color()).bold()));
    f.render_widget(Paragraph::new(Line::from(left)), chunks[0]);

    // The agent table.
    let list_focused = app.focus == Focus::List;
    let list_block = frame_block(" agents ", list_focused, Color::Cyan);
    // Its rows: below the border and the header row.
    let list_inner = list_block.inner(chunks[1]);
    app.rows_rect = Rect { y: list_inner.y + 1, height: list_inner.height.saturating_sub(1), ..list_inner };
    app.hits.push((app.rows_rect, Act::Table));
    if app.jobs.is_empty() {
        let empty = Paragraph::new(Line::from(Span::styled(
            "no agents yet — write a prompt below and press Enter",
            Style::new().dim().italic(),
        )))
        .block(list_block);
        f.render_widget(empty, chunks[1]);
    } else {
        let links = link_column(&app.jobs);
        // The rules between the zones: empty rows here, drawn over below (a
        // cell per column would leave gaps in the line). A "with #N" bracket
        // that reaches across a rule is kept joined.
        let rules: Vec<(usize, bool)> = app.rules().iter().map(|&r| (app.row_of(r) - 1, matches!(links[r - 1], '╭' | '├' | '│'))).collect();
        let mut rows: Vec<Row> = app
            .jobs
            .iter()
            .zip(links)
            .map(|(j, link)| {
                let st = status_style(&j.status);
                let mode = match j.with {
                    Some(w) => format!("with #{w}"),
                    None if j.mode == "now" => "par".to_string(),
                    None => "queue".to_string(),
                };
                let dur = if j.waiting() { "-".to_string() } else { fmt_dur(j.since) };
                let prompt_style = if j.hot() { Style::new() } else { Style::new().dim() };
                let detail = if app.editing == Some(j.id) {
                    "   › editing below".to_string()
                } else if j.detail.is_empty() || !j.hot() {
                    String::new()
                } else {
                    format!("   › {}", j.detail)
                };
                let detail_style = if j.status == "asks" {
                    status_style("asks").remove_modifier(Modifier::BOLD)
                } else {
                    Style::new().dim()
                };
                Row::new(vec![
                    Cell::from(Span::styled(format!("#{}", j.id), prompt_style)),
                    Cell::from(Span::styled(link.to_string(), Style::new().fg(Color::Cyan).dim())),
                    Cell::from(Span::styled(status_word(&j.status).to_string(), st)),
                    Cell::from(Span::styled(mode, Style::new().dim())),
                    Cell::from(Span::styled(dur, Style::new().dim())),
                    Cell::from(Line::from(vec![
                        Span::styled(j.first_line().to_string(), prompt_style),
                        Span::styled(detail, detail_style),
                    ])),
                ])
            })
            .collect();
        for &(row, _) in &rules {
            rows.insert(row, Row::new(Vec::<Cell>::new()));
        }
        let highlight = if list_focused { Style::new().reversed() } else { Style::new().bg(Color::DarkGray) };
        let table = Table::new(
            rows,
            [
                Constraint::Length(4),
                Constraint::Length(1),
                Constraint::Length(10),
                Constraint::Length(9),
                Constraint::Length(7),
                Constraint::Min(10),
            ],
        )
        .header(Row::new(["", "", "status", "mode", "time", "prompt"]).style(Style::new().dim().underlined()))
        .column_spacing(1)
        .row_highlight_style(highlight)
        .block(list_block);
        f.render_stateful_widget(table, chunks[1], &mut app.table);
        // The rules whose rows are on screen (the bracket column is after the
        // 4-wide id column and the spacing).
        for (row, bracket) in rules.into_iter().filter(|&(row, _)| row >= app.table.offset()) {
            let y = app.rows_rect.y + (row - app.table.offset()) as u16;
            if y >= app.rows_rect.y + app.rows_rect.height {
                continue;
            }
            let mut line: Vec<char> = vec!['─'; app.rows_rect.width as usize];
            if bracket && line.len() > 5 {
                line[5] = '┼';
            }
            let s: String = line.into_iter().collect();
            f.render_widget(Paragraph::new(Span::styled(s, Style::new().dim())), Rect { y, height: 1, ..app.rows_rect });
        }
    }

    // Details of the selected agent: its prompt, and one line on what it does
    // now (running), said (done) or waits for (queued), with the keys for it.
    let mut lines: Vec<Line> = Vec::new();
    let mut title = String::from(" details ");
    if let Some(j) = app.selected() {
        title = format!(" #{} · {} · {} ", j.id, j.status, &j.session[..j.session.len().min(8)]);
        lines.push(Line::from(squash(&j.prompt)));
        let keys = |s: &str| Span::styled(format!("   {s}"), Style::new().dim());
        let hold_keys = if app.editing == Some(j.id) { "its prompt is in the box below: Enter there saves it, e cancels" } else { "p holds it back, e changes its prompt" };
        lines.push(match j.status.as_str() {
            "running" => Line::from(vec![Span::styled("now  ", status_style("running")), Span::raw(j.detail.clone())]),
            "done" | "asks" => Line::from(vec![Span::styled("said  ", status_style(&j.status)), Span::raw(j.detail.clone())]),
            "failed" => Line::from(vec![Span::styled("error  ", status_style("failed")), Span::raw(j.detail.clone()), keys("Enter opens a new window resuming it, d removes it")]),
            "held" => Line::from(vec![
                Span::styled("held: does not start whatever frees up; the ones behind it go past", status_style("held").remove_modifier(Modifier::BOLD)),
                keys(if app.editing == Some(j.id) { hold_keys } else { "p releases it, e changes its prompt" }),
            ]),
            "queued" => {
                let waiting = match j.with {
                    Some(w) => format!("waiting for #{w} to start, then opens next to it"),
                    None if j.mode == "now" => "opens right away".to_string(),
                    None => "waiting for a free queue slot".to_string(),
                };
                Line::from(vec![Span::styled(waiting, Style::new().dim()), keys(hold_keys)])
            }
            _ => Line::from(Span::styled("window closed — Enter opens a new one resuming the conversation, d removes it", Style::new().dim())),
        });
    }
    let details = Paragraph::new(lines).wrap(Wrap { trim: false }).block(frame_block(title, false, Color::Reset));
    f.render_widget(details, chunks[2]);

    // The prompt box: micro's screen. In parallel mode its first line is the
    // "with #N" input box: "-" means right away, a number waits for that agent.
    let editor_focused = app.focus == Focus::Editor;
    let with_focused = app.focus == Focus::With;
    let (title, color) = match (app.editing, app.mode) {
        (Some(id), _) => (format!(" prompt of #{id}   Enter saves it · Esc: list (e there cancels) "), Color::Cyan),
        (None, Mode::Queue) => (" prompt → queue   Enter sends · Tab: parallel · Esc: list ".to_string(), app.mode.color()),
        (None, Mode::Parallel) => (" prompt → parallel   Enter sends · Tab: queue · Shift+Tab: with # · Esc: list ".to_string(), app.mode.color()),
    };
    let block = frame_block(title, editor_focused || with_focused, color);
    let mut inner = block.inner(chunks[3]);
    f.render_widget(block, chunks[3]);
    if app.mode == Mode::Parallel && inner.height > 2 {
        let row = Rect { height: 1, ..inner };
        inner = Rect { y: inner.y + 1, height: inner.height - 1, ..inner };
        let text = if app.with.is_empty() { "-".to_string() } else { app.with.clone() };
        let cursor = if with_focused { "▏" } else { " " };
        let field_style = if with_focused {
            Style::new().fg(Color::Black).bg(Color::White).bold()
        } else if app.with_unknown() {
            Style::new().fg(Color::Red).bg(Color::DarkGray).bold()
        } else {
            Style::new().bg(Color::DarkGray).bold()
        };
        let hint = match (with_focused, app.with_id()) {
            (true, _) => "digits · - = right away · ⏎ back to prompt".to_string(),
            (false, Some(id)) if app.with_unknown() => format!("there is no agent #{id}"),
            (false, Some(id)) => format!("waits until #{id} starts, then opens next to it"),
            (false, None) => "opens right away · Shift+Tab to edit".to_string(),
        };
        let line = Line::from(vec![
            Span::styled(" with agent #", Style::new().bold()),
            Span::styled(format!(" {text:<4}{cursor}"), field_style),
            Span::styled(format!("  {hint}"), Style::new().dim()),
        ]);
        f.render_widget(Paragraph::new(line), row);
        app.hits.push((row, Act::With));
    }
    app.editor_rect = inner;
    app.hits.push((inner, Act::Editor));
    if let Some(ed) = &app.editor {
        if let Ok(parser) = ed.parser.lock() {
            let mut term = PseudoTerminal::new(parser.screen());
            if !editor_focused {
                term = term.cursor(tui_term::widget::Cursor::default().visibility(false));
            }
            f.render_widget(term, inner);
        }
    } else {
        f.render_widget(Paragraph::new(Span::styled("(editor not running)", Style::new().dim())), inner);
    }

    // Message and key help (the keys are buttons too).
    f.render_widget(Paragraph::new(Span::styled(format!(" {}", app.msg), Style::new().fg(Color::Yellow))), chunks[4]);
    let at = (chunks[5].x, chunks[5].y);
    let enter_does = match (app.editing, app.mode) {
        (Some(id), _) => format!("save prompt of #{id}"),
        (None, Mode::Queue) => "send (queue)".to_string(),
        (None, Mode::Parallel) => "send (parallel)".to_string(),
    };
    let edit_key = if app.editing.is_some() && app.editing == app.sel { "cancel edit" } else { "edit prompt" };
    let help = match app.focus {
        Focus::Editor => key_help(
            &mut app.hits,
            at,
            &[
                ("⏎", enter_does.as_str(), Act::None),
                ("Alt+⏎", "newline", Act::None),
                ("Tab", "mode", Act::Mode),
                ("Shift+Tab", "with #", Act::With),
                ("Esc", "agent list", Act::FocusList),
                ("micro keys", "everything else", Act::None),
            ],
        ),
        Focus::With => key_help(
            &mut app.hits,
            at,
            &[
                ("0-9", "agent to start with", Act::None),
                ("-", "none: run right away", Act::None),
                ("⌫", "delete", Act::None),
                ("⏎/Esc", "back to prompt", Act::FocusEditor),
                ("Tab", "mode", Act::Mode),
            ],
        ),
        Focus::List => key_help(
            &mut app.hits,
            at,
            &[
                ("↑↓", "select", Act::None),
                ("⏎", "window", Act::ListKey(b'o')),
                ("h", "hide", Act::ListKey(b'h')),
                ("k", "close", Act::ListKey(b'k')),
                ("d", "remove", Act::ListKey(b'd')),
                ("r", "retry", Act::ListKey(b'r')),
                ("p", "hold/release", Act::ListKey(b'p')),
                ("e", edit_key, Act::ListKey(b'e')),
                ("w", "prompt with", Act::ListKey(b'w')),
                ("l", "transcript", Act::ListKey(b'l')),
                ("x", "clear finished", Act::ListKey(b'x')),
                ("n", "notes", Act::ListKey(b'n')),
                ("Tab", "mode", Act::Mode),
                ("Esc/i", "back to prompt", Act::FocusEditor),
                ("q", "quit", Act::ListKey(b'q')),
            ],
        ),
    };
    f.render_widget(Paragraph::new(help), chunks[5]);

    // Confirmation popup.
    if let Some(question) = app.confirm.as_ref().map(|c| c.question.clone()) {
        let w = (question.chars().count() as u16 + 6).clamp(30, area.width.saturating_sub(4));
        let h = 5;
        let x = area.x + (area.width.saturating_sub(w)) / 2;
        let y = area.y + (area.height.saturating_sub(h)) / 2;
        let popup = Rect::new(x, y, w, h);
        f.render_widget(Clear, popup);
        // The answers line is centred: "y yes  n no" is 11 columns wide.
        let buttons = (x + 1 + (w - 2).saturating_sub(11) / 2, y + 3);
        let answers = key_help(&mut app.hits, buttons, &[("y", "yes", Act::Answer(true)), ("n", "no", Act::Answer(false))]);
        let text = vec![Line::from(question), Line::from(""), answers.centered()];
        f.render_widget(
            Paragraph::new(text).alignment(Alignment::Center).block(
                Block::bordered().border_type(BorderType::Rounded).border_style(Style::new().fg(Color::Yellow)).title(" confirm "),
            ),
            popup,
        );
    }
    inner
}

fn main() {
    let mut app = match App::new() {
        Ok(a) => a,
        Err(e) => {
            eprintln!("agents-ui: {e}");
            std::process::exit(1);
        }
    };
    let mut term: DefaultTerminal = ratatui::init();
    let _ = execute!(io::stdout(), EnableBracketedPaste, EnableMouseCapture);

    // The keyboard, as raw bytes: most of them are for micro.
    let (tx, rx) = mpsc::channel::<Vec<u8>>();
    thread::spawn(move || {
        let mut stdin = io::stdin().lock();
        let mut buf = [0u8; 4096];
        loop {
            match stdin.read(&mut buf) {
                Ok(0) | Err(_) => break,
                Ok(n) => {
                    if tx.send(buf[..n].to_vec()).is_err() {
                        break;
                    }
                }
            }
        }
    });

    let (ltx, lrx) = mpsc::channel::<Option<Vec<Limit>>>();
    poll_limits(app.sh.clone(), app.dir.clone(), ltx);

    let mut last_inner = Rect::default();
    while !app.quit {
        while let Ok(limits) = lrx.try_recv() {
            if let Some(limits) = limits {
                app.limits = limits;
                app.limits_at = Some(Instant::now());
            }
        }
        let inner = match term.draw(|f| {
            last_inner = draw(f, &mut app);
        }) {
            Ok(_) => last_inner,
            Err(_) => break,
        };
        if inner.height > 0 && inner.width > 0 {
            app.resize_editor(inner.height, inner.width);
        }
        app.check_editor();
        match rx.recv_timeout(Duration::from_millis(50)) {
            Ok(bytes) => app.input(&bytes),
            Err(mpsc::RecvTimeoutError::Timeout) => {}
            Err(mpsc::RecvTimeoutError::Disconnected) => break,
        }
        if app.loaded.elapsed() >= Duration::from_secs(1) {
            app.load();
        }
    }
    if let Some(mut ed) = app.editor.take() {
        let _ = ed.child.kill();
    }
    let _ = execute!(io::stdout(), DisableMouseCapture, DisableBracketedPaste);
    ratatui::restore();
}
