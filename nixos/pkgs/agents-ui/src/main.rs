//! agents-ui: the interface of scripts/agents.sh.
//!
//! The bash script owns everything that happens (the job store, the hooks,
//! opening terminal windows); this app only shows that state and runs the
//! script's commands. It is started by `agents ui`, which passes the script,
//! the working directory and the state directory in the environment.
//!
//! The prompt box at the bottom is a real micro: it runs in a pty whose screen
//! is drawn into the box, and the keyboard goes straight to it, so editing,
//! pasting, undo and all of micro's keys work exactly as in the editor. The
//! app only keeps a few keys for itself: Enter sends (micro saves and quits,
//! we read the file), Tab toggles the send mode, Esc moves the focus to the
//! agent list where single letters run the commands.

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
        event::{DisableBracketedPaste, EnableBracketedPaste},
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
}

struct Job {
    id: u32,
    status: String,
    mode: String,
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
        self.alive() || self.status == "queued"
    }
    fn first_line(&self) -> &str {
        self.prompt.lines().next().unwrap_or("")
    }
}

/// A pending yes/no question and the script command it would run.
struct Confirm {
    question: String,
    args: Vec<String>,
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
    jobs: Vec<Job>,
    sel: Option<u32>,
    table: TableState,
    mode: Mode,
    focus: Focus,
    msg: String,
    confirm: Option<Confirm>,
    loaded: Instant,
    quit: bool,
    /// The file micro edits; its saved content is what gets sent.
    prompt_file: PathBuf,
    micro_config: PathBuf,
    editor: Option<Editor>,
    editor_size: (u16, u16),
    in_paste: bool,
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
    if s >= 3600 {
        format!("{}h{:02}m", s / 3600, s % 3600 / 60)
    } else if s >= 60 {
        format!("{}m{:02}s", s / 60, s % 60)
    } else {
        format!("{s}s")
    }
}

fn squash(s: &str) -> String {
    s.split_whitespace().collect::<Vec<_>>().join(" ")
}

/// One line saying what the agent is doing, from the tail of its transcript.
fn activity(transcript: &str) -> String {
    use std::io::{Seek, SeekFrom};
    let Ok(mut f) = fs::File::open(transcript) else {
        return "(starting)".into();
    };
    let len = f.metadata().map(|m| m.len()).unwrap_or(0);
    let take = len.min(96 * 1024);
    if f.seek(SeekFrom::Start(len - take)).is_err() {
        return String::new();
    }
    let mut raw = Vec::new();
    if f.read_to_end(&mut raw).is_err() {
        return String::new();
    }
    let buf = String::from_utf8_lossy(&raw);
    let mut last = String::new();
    // The first line may be a partial one when we started mid-file.
    for line in buf.lines().skip(if take < len { 1 } else { 0 }) {
        let Ok(j) = serde_json::from_str::<serde_json::Value>(line) else {
            continue;
        };
        if j["isSidechain"].as_bool() == Some(true) || j["type"] != "assistant" {
            continue;
        }
        let Some(content) = j["message"]["content"].as_array() else {
            continue;
        };
        for c in content {
            match c["type"].as_str() {
                Some("tool_use") => {
                    let i = &c["input"];
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
    if last.is_empty() {
        "(starting)".into()
    } else {
        last
    }
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
        let sh = env::var("AGENTS_SH").map_err(|_| "AGENTS_SH not set: start this through `agents ui`".to_string())?;
        let state = env::var("AGENTS_STATE_DIR").map_err(|_| "AGENTS_STATE_DIR not set".to_string())?;
        let dir = env::var("AGENTS_DIR").map(PathBuf::from).or_else(|_| env::current_dir()).map_err(|e| e.to_string())?;
        let state = PathBuf::from(state);
        let mode = if read(&state.join("uimode")) == "now" { Mode::Parallel } else { Mode::Queue };
        let mut app = App {
            sh: PathBuf::from(sh),
            dir,
            slots: env::var("AGENTS_SLOTS").unwrap_or_else(|_| "1".into()),
            jobs: Vec::new(),
            sel: None,
            table: TableState::default(),
            mode,
            focus: Focus::Editor,
            msg: String::new(),
            confirm: None,
            loaded: Instant::now(),
            quit: false,
            prompt_file: state.join("prompt.md"),
            micro_config: micro_config_dir(&state),
            editor: None,
            editor_size: (8, 80),
            in_paste: false,
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
                "running" | "done" | "asks" => now().saturating_sub(started.unwrap_or(created)),
                _ => ended.unwrap_or_else(now).saturating_sub(started.unwrap_or(created)),
            };
            let detail = match status.as_str() {
                "running" => activity(&read(&jd.join("transcript"))),
                "done" | "asks" => read(&jd.join("last")),
                "failed" => read(&jd.join("err")),
                _ => String::new(),
            };
            jobs.push(Job {
                id,
                status,
                mode: read(&jd.join("mode")),
                prompt: read(&jd.join("prompt")),
                since,
                detail,
                session: read(&jd.join("session")),
            });
        }
        // Live ones first, oldest at the top; finished ones below, newest first.
        jobs.sort_by_key(|j| j.id);
        let (hot, cold): (Vec<Job>, Vec<Job>) = jobs.into_iter().partition(Job::hot);
        self.jobs = hot;
        self.jobs.extend(cold.into_iter().rev());
        if !self.jobs.iter().any(|j| Some(j.id) == self.sel) {
            self.sel = self.jobs.first().map(|j| j.id);
        }
        self.table.select(self.sel_index());
    }

    fn sel_index(&self) -> Option<usize> {
        self.jobs.iter().position(|j| Some(j.id) == self.sel)
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
        self.table.select(Some(i));
    }

    fn counts(&self) -> (usize, usize, usize, usize) {
        let n = |s: &str| self.jobs.iter().filter(|j| j.status == s).count();
        (n("running"), n("done"), n("asks"), n("queued"))
    }

    fn toggle_mode(&mut self) {
        self.mode = if self.mode == Mode::Queue { Mode::Parallel } else { Mode::Queue };
        let _ = fs::write(self.state.join("uimode"), self.mode.arg());
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

    /// micro has quit: whatever it saved is the prompt to send. Then start it
    /// again on an empty file for the next one.
    fn check_editor(&mut self) {
        let Some(ed) = &mut self.editor else {
            // First start: keep whatever draft is in the file.
            self.spawn_editor();
            return;
        };
        if !matches!(ed.child.try_wait(), Ok(Some(_))) {
            return;
        }
        self.editor = None;
        let text = fs::read_to_string(&self.prompt_file).unwrap_or_default();
        if !text.trim().is_empty() {
            let (ok, out) = self.run(&[self.mode.arg()], Some(text.trim_end()));
            self.msg = out;
            if ok {
                let _ = fs::write(&self.prompt_file, "");
            }
            self.load();
        } else {
            let _ = fs::write(&self.prompt_file, "");
        }
        self.spawn_editor();
    }

    // -- keys

    /// Raw bytes from the terminal. With the editor focused nearly everything
    /// goes to micro untouched; the app only takes Enter, Tab and a lone Esc.
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
                match (self.focus, seq) {
                    (_, b"\x1b") => {
                        self.flush_pass(&mut pass);
                        self.key_esc();
                    }
                    (Focus::Editor, b"\x1b\r") | (Focus::Editor, b"\x1b\n") => pass.push(b'\r'), // Alt+Enter: newline
                    (Focus::Editor, _) => pass.extend_from_slice(seq),
                    (Focus::List, b"\x1b[A") | (Focus::List, b"\x1bOA") => self.move_sel(-1),
                    (Focus::List, b"\x1b[B") | (Focus::List, b"\x1bOB") => self.move_sel(1),
                    (Focus::List, b"\x1b[5~") => self.move_sel(-10),
                    (Focus::List, b"\x1b[6~") => self.move_sel(10),
                    (Focus::List, _) => {}
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

    fn key_esc(&mut self) {
        self.msg.clear();
        self.focus = match self.focus {
            Focus::Editor => Focus::List,
            Focus::List => Focus::Editor,
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
            b'r' | b'R' | 0x12 => {
                if let Some(id) = &sel {
                    self.act(&["retry", id]);
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
        "exited" => "  closed",
        "failed" => "✗ failed",
        "killed" => "✗ killed",
        other => other,
    }
}

fn key_help<'a>(pairs: &[(&'a str, &'a str)]) -> Line<'a> {
    let mut spans = Vec::new();
    for (i, (k, d)) in pairs.iter().enumerate() {
        if i > 0 {
            spans.push(Span::raw("  "));
        }
        spans.push(Span::styled(*k, Style::new().bold()));
        spans.push(Span::styled(format!(" {d}"), Style::new().dim()));
    }
    Line::from(spans)
}

fn frame_block(title: String, focused: bool, color: Color) -> Block<'static> {
    let style = if focused { Style::new().fg(color) } else { Style::new().dim() };
    Block::bordered().border_type(BorderType::Rounded).border_style(style).title(title)
}

/// Returns the inner area of the editor box, so the pty can follow its size.
fn draw(f: &mut Frame, app: &mut App) -> Rect {
    let area = f.area();
    let editor_h = (area.height / 3).clamp(6, 14);
    let chunks = Layout::vertical([
        Constraint::Length(1),
        Constraint::Min(4),
        Constraint::Length(5),
        Constraint::Length(editor_h),
        Constraint::Length(1),
        Constraint::Length(1),
    ])
    .split(area);

    // Header: where we are, how many agents do what, the send mode on the right.
    let (working, done, asking, queued) = app.counts();
    let mode = format!(" {} ", app.mode.label());
    let mut left = vec![
        Span::styled(" agents ", Style::new().bold().reversed()),
        Span::raw(" "),
        Span::styled(app.dir.display().to_string(), Style::new().dim()),
        Span::raw("   "),
        Span::styled(format!("{working} working"), status_style("running")),
        Span::raw("  "),
        Span::styled(format!("{done} done"), status_style("done")),
        Span::raw("  "),
        Span::styled(format!("{queued} queued"), status_style("queued")),
    ];
    if asking > 0 {
        left.push(Span::raw("  "));
        left.push(Span::styled(format!("{asking} asking you"), status_style("asks")));
    }
    left.push(Span::styled(format!("   {} slot(s)", app.slots), Style::new().dim()));
    let used: usize = left.iter().map(|s| s.content.chars().count()).sum();
    let pad = (area.width as usize).saturating_sub(used + mode.chars().count() + 1);
    left.push(Span::raw(" ".repeat(pad)));
    left.push(Span::styled(mode, Style::new().fg(Color::Black).bg(app.mode.color()).bold()));
    f.render_widget(Paragraph::new(Line::from(left)), chunks[0]);

    // The agent table.
    let list_focused = app.focus == Focus::List;
    let list_block = frame_block(" agents ".into(), list_focused, Color::Cyan);
    if app.jobs.is_empty() {
        let empty = Paragraph::new(Line::from(Span::styled(
            "no agents yet — write a prompt below and press Enter",
            Style::new().dim().italic(),
        )))
        .block(list_block);
        f.render_widget(empty, chunks[1]);
    } else {
        let rows: Vec<Row> = app
            .jobs
            .iter()
            .map(|j| {
                let st = status_style(&j.status);
                let mode = if j.mode == "now" { "par" } else { "queue" };
                let dur = if j.status == "queued" { "-".to_string() } else { fmt_dur(j.since) };
                let prompt_style = if j.hot() { Style::new() } else { Style::new().dim() };
                let detail = if j.detail.is_empty() || !j.hot() { String::new() } else { format!("   › {}", j.detail) };
                let detail_style = if j.status == "asks" {
                    status_style("asks").remove_modifier(Modifier::BOLD)
                } else {
                    Style::new().dim()
                };
                Row::new(vec![
                    Cell::from(Span::styled(format!("#{}", j.id), prompt_style)),
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
        let highlight = if list_focused { Style::new().reversed() } else { Style::new().bg(Color::DarkGray) };
        let table = Table::new(
            rows,
            [
                Constraint::Length(5),
                Constraint::Length(10),
                Constraint::Length(5),
                Constraint::Length(7),
                Constraint::Min(10),
            ],
        )
        .header(Row::new(["", "status", "mode", "time", "prompt"]).style(Style::new().dim().underlined()))
        .column_spacing(1)
        .row_highlight_style(highlight)
        .block(list_block);
        f.render_stateful_widget(table, chunks[1], &mut app.table);
    }

    // Details of the selected agent.
    let mut lines: Vec<Line> = Vec::new();
    let mut title = String::from(" details ");
    if let Some(j) = app.selected() {
        title = format!(" #{} · {} ", j.id, j.status);
        lines.push(Line::from(squash(&j.prompt)));
        let (tag, style) = match j.status.as_str() {
            "running" => ("now", status_style("running")),
            "done" | "asks" => ("said", status_style(&j.status)),
            "failed" => ("error", status_style("failed")),
            _ => ("", Style::new()),
        };
        if j.status == "queued" {
            lines.push(Line::from(Span::styled("waiting for a free queue slot", Style::new().dim())));
        } else if !j.detail.is_empty() {
            lines.push(Line::from(vec![Span::styled(format!("{tag}  "), style.bold()), Span::raw(j.detail.clone())]));
        }
        let hint = match j.status.as_str() {
            "running" | "done" | "asks" => "Enter in the list jumps into its window",
            "queued" => "opens in its own window when a slot is free",
            _ => "window closed — Enter opens a new one resuming the conversation, d removes it",
        };
        lines.push(Line::from(vec![
            Span::styled(hint, Style::new().dim()),
            Span::styled(format!("   session {}", &j.session[..j.session.len().min(8)]), Style::new().dim()),
        ]));
    }
    let details = Paragraph::new(lines).wrap(Wrap { trim: false }).block(frame_block(title, false, Color::Reset));
    f.render_widget(details, chunks[2]);

    // The prompt box: micro's screen.
    let editor_focused = app.focus == Focus::Editor;
    let title = match app.mode {
        Mode::Queue => " prompt → queue   Enter sends · Tab: parallel · Esc: list ",
        Mode::Parallel => " prompt → parallel   Enter sends · Tab: queue · Esc: list ",
    };
    let block = frame_block(title.into(), editor_focused, app.mode.color());
    let inner = block.inner(chunks[3]);
    f.render_widget(block, chunks[3]);
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

    // Message and key help.
    f.render_widget(Paragraph::new(Span::styled(format!(" {}", app.msg), Style::new().fg(Color::Yellow))), chunks[4]);
    let help = if editor_focused {
        key_help(&[
            ("⏎", if app.mode == Mode::Queue { "send (queue)" } else { "send (parallel)" }),
            ("Alt+⏎", "newline"),
            ("Tab", "mode"),
            ("Esc", "agent list"),
            ("micro keys", "everything else"),
        ])
    } else {
        key_help(&[
            ("↑↓", "select"),
            ("⏎", "window"),
            ("k", "close"),
            ("d", "remove"),
            ("r", "retry"),
            ("l", "transcript"),
            ("x", "clear finished"),
            ("n", "notes"),
            ("Tab", "mode"),
            ("Esc/i", "back to prompt"),
            ("q", "quit"),
        ])
    };
    f.render_widget(Paragraph::new(help), chunks[5]);

    // Confirmation popup.
    if let Some(c) = &app.confirm {
        let w = (c.question.chars().count() as u16 + 6).clamp(30, area.width.saturating_sub(4));
        let h = 5;
        let x = area.x + (area.width.saturating_sub(w)) / 2;
        let y = area.y + (area.height.saturating_sub(h)) / 2;
        let popup = Rect::new(x, y, w, h);
        f.render_widget(Clear, popup);
        let text = vec![Line::from(c.question.clone()), Line::from(""), key_help(&[("y", "yes"), ("n", "no")]).centered()];
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
    let _ = execute!(io::stdout(), EnableBracketedPaste);

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

    let mut last_inner = Rect::default();
    while !app.quit {
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
    let _ = execute!(io::stdout(), DisableBracketedPaste);
    ratatui::restore();
}
