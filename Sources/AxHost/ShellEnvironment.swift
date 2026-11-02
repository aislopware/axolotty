#if os(macOS)
import AxModel
import AxProtocol
import Foundation

/// The environment and command line every pane starts with.
enum ShellEnvironment {
    static let termProgramVersion = "0.1.0"

    /// The person's login shell from the directory service, else zsh.
    static var loginShell: String {
        if let pw = getpwuid(getuid()), let sh = pw.pointee.pw_shell, sh.pointee != 0 { return String(cString: sh) }
        return "/bin/zsh"
    }

    static var home: String {
        if let pw = getpwuid(getuid()), let d = pw.pointee.pw_dir { return String(cString: d) }
        return NSHomeDirectory()
    }

    /// Path and argv for a recipe. A nil command is an interactive login shell.
    static func command(_ recipe: SpawnRecipe, shell override: String? = nil,
                        integration: URL? = nil) -> (path: String, argv: [String])
    {
        if let override {
            guard let cmd = recipe.command, !cmd.isEmpty else { return (override, [override]) }
            return (override, [override, "-c", cmd.count == 1 ? cmd[0] : cmd.map(quote).joined(separator: " ")])
        }
        if let cmd = recipe.command, let first = cmd.first {
            // Through the login shell so PATH and aliases match what the person sees.
            let shell = loginShell
            let line = cmd.count == 1 ? first : cmd.map(quote).joined(separator: " ")
            return (shell, [shell, "-l", "-i", "-c", line])
        }
        let shell = loginShell
        let base = shell.split(separator: "/").last.map(String.init) ?? "zsh"
        // bash has no ZDOTDIR: it starts on the integration's rc file, which
        // reads the login files a login bash would (works on bash 3.2 too).
        if base == "bash", let integration {
            return (shell, ["bash", "--rcfile", integration.appending(path: "bash/axolotty.bash").path(percentEncoded: false)])
        }
        return (shell, ["-" + base])  // leading dash: login shell
    }

    /// Set by a coding agent for the commands it runs. A pane is a fresh
    /// terminal, never inside that agent, even when the server was started
    /// from one: the agent would otherwise treat the pane as its child, and
    /// its session id, pid and messaging socket and token would reach every
    /// program in every pane. The person's own settings (`CLAUDE_CODE_USE_BEDROCK`,
    /// `CLAUDE_CODE_DISABLE_*`, …) are theirs and stay.
    static let agentSessionMarkers: Set<String> = [
        "CLAUDECODE", "CLAUDE_PID", "CLAUDE_CODE_ENTRYPOINT", "CLAUDE_CODE_CHILD_SESSION", "CLAUDE_CODE_SSE_PORT",
        "CLAUDE_CODE_SESSION_ID", "CLAUDE_CODE_SESSION_ATTENDED", "CLAUDE_CODE_EXECPATH", "CLAUDE_CODE_PROCESS_WRAPPER",
        "CODEX_SANDBOX", "CODEX_SANDBOX_NETWORK_DISABLED", "CODEX_THREAD_ID",
    ]

    static func isAgentSessionMarker(_ key: String) -> Bool {
        agentSessionMarkers.contains(key) || key.hasPrefix("CLAUDE_CODE_MESSAGING_")
    }

    static func quote(_ s: String) -> String {
        if !s.isEmpty, s.allSatisfy({ $0.isLetter || $0.isNumber || "-_./=:@%+,".contains($0) }) { return s }
        return "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// The child environment: the server's (minus terminal-specific variables),
    /// terminal identity, Axolotty addressing and shell integration.
    static func environment(pane: PaneID, recipe: SpawnRecipe, paths: RuntimePaths,
                            base: [String: String] = ProcessInfo.processInfo.environment) -> [String]
    {
        var env = base.filter { key, _ in
            !key.hasPrefix("TERM") && key != "COLORTERM" && !key.hasPrefix("AXOLOTTY_") && key != "ZDOTDIR"
                && !key.hasPrefix("XPC_") && key != "__CFBundleIdentifier" && !key.hasPrefix("GHOSTTY")
                && !key.hasPrefix("ITERM") && key != "SHLVL" && key != "OLDPWD" && key != "PWD" && key != "_"
                && !isAgentSessionMarker(key)
        }
        env["HOME"] = env["HOME"] ?? home
        env["SHELL"] = loginShell
        if env["USER"] == nil, let pw = getpwuid(getuid()), let n = pw.pointee.pw_name { env["USER"] = String(cString: n) }
        env["LOGNAME"] = env["USER"]
        env["LANG"] = env["LANG"] ?? "en_US.UTF-8"
        env["PATH"] = env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        env["TERM_PROGRAM"] = "Axolotty"
        env["TERM_PROGRAM_VERSION"] = termProgramVersion
        env["AXOLOTTY_PANE_ID"] = pane.raw.uuidString
        env["AXOLOTTY_SOCKET"] = paths.hostSocket.path(percentEncoded: false)
        // The CLI first on PATH (agents call `axolotty`).
        var bin = paths.bin.path(percentEncoded: false)
        if bin.count > 1, bin.hasSuffix("/") { bin.removeLast() }
        env["PATH"] = bin + ":" + (env["PATH"] ?? "")
        // The shell integration puts it first again after the person's rc files.
        env["AXOLOTTY_BIN"] = bin
        env["AXOLOTTY_MCP"] = paths.mcpConfig.path(percentEncoded: false)

        // zsh integration: our ZDOTDIR loads the person's files, then adds OSC 133/7 hooks.
        let shell = recipe.command == nil ? loginShell : ""
        if shell.hasSuffix("/zsh") {
            if let user = base["ZDOTDIR"] { env["AXOLOTTY_ZDOTDIR"] = user }
            env["ZDOTDIR"] = paths.shellIntegration.appending(path: "zsh").path(percentEncoded: false)
        } else if shell.hasSuffix("/bash") {
            env["AXOLOTTY_BASH_LOGIN"] = "1"
        } else if shell.hasSuffix("/fish") {
            // fish ≥ 4 marks prompts (OSC 133, with the command line) and the
            // directory (OSC 7) itself; vendor_conf.d only keeps our CLI first on PATH.
            let ours = paths.shellIntegration.path(percentEncoded: false)
            env["XDG_DATA_DIRS"] = ours + ":" + (base["XDG_DATA_DIRS"] ?? "/usr/local/share:/usr/share")
            env["AXOLOTTY_FISH_DATA"] = ours
        }
        for (k, v) in recipe.env { env[k] = v }
        return env.map { "\($0.key)=\($0.value)" }.sorted()
    }

    /// Writes the integration scripts (idempotent), and links the CLI onto
    /// every pane's PATH so programs and agents can call `axolotty`.
    static func install(_ paths: RuntimePaths, cli: URL? = nil) throws {
        let fm = FileManager.default
        let dir = paths.shellIntegration.appending(path: "zsh")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        func write(_ text: String, to file: URL) throws {
            try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = Data(text.utf8)
            if (try? Data(contentsOf: file)) != data { try data.write(to: file, options: .atomic) }
        }
        try write(zshenv, to: dir.appending(path: ".zshenv"))
        try write(bash, to: paths.shellIntegration.appending(path: "bash/axolotty.bash"))
        try write(fish, to: paths.shellIntegration.appending(path: "fish/vendor_conf.d/axolotty.fish"))

        guard let cli else { return }
        try fm.createDirectory(at: paths.bin, withIntermediateDirectories: true)
        let link = paths.bin.appending(path: "axolotty").path(percentEncoded: false)
        // Agents Axolotty starts get its tools through this file (never the agent's own config).
        let mcp: [String: Any] = ["mcpServers": ["axolotty": ["command": link, "args": ["mcp"]]]]
        let mcpData = try JSONSerialization.data(withJSONObject: mcp, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        if (try? Data(contentsOf: paths.mcpConfig)) != mcpData { try mcpData.write(to: paths.mcpConfig, options: .atomic) }
        let target = cli.path(percentEncoded: false)
        if (try? fm.destinationOfSymbolicLink(atPath: link)) != target {
            try? fm.removeItem(atPath: link)
            try fm.createSymbolicLink(atPath: link, withDestinationPath: target)
        }
        for name in ["open", "pbcopy"] {
            let file = paths.bin.appending(path: name)
            try write(shim(name, cli: link), to: file)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path(percentEncoded: false))
        }
    }

    /// `open` and `pbcopy` first on every pane's PATH: what a program opens
    /// or copies for the person reaches the Mac they type from (a sign-in
    /// link, `/copy` in an agent), as if the program ran there. Anything
    /// else, or with no far person, is the system's own command, unchanged.
    static func shim(_ name: String, cli: String, system: String = "/usr/bin") -> String {
        // Inside "…", only these four mean anything to sh.
        var inner = ""
        for ch in cli {
            if "\\\"$`".contains(ch) { inner.append("\\") }
            inner.append(ch)
        }
        let q = "\"" + inner + "\""
        switch name {
        case "open":
            return """
            #!/bin/sh
            # Axolotty: a lone web link opens on the Mac the person types from.
            if [ $# -eq 1 ] && [ -x \(q) ]; then
              case "$1" in http://*|https://*) \(q) open-url "$1" 2>/dev/null && exit 0 ;; esac
            fi
            exec \(system)/open "$@"

            """
        default:
            return """
            #!/bin/sh
            # Axolotty: a copy also reaches the Mac the person types from.
            [ -x \(q) ] || exec \(system)/pbcopy "$@"
            AXOLOTTY_SYSTEM_PBCOPY=\(system)/pbcopy exec \(q) pbcopy "$@"

            """
        }
    }

    static let zshenv = #"""
    # Axolotty shell integration for zsh. Restores the person's ZDOTDIR first so
    # every later startup file is theirs, then adds prompt marks (OSC 133) and
    # the working directory (OSC 7). Generated; edits are overwritten.
    if [[ -n "${AXOLOTTY_ZDOTDIR+x}" ]]; then
      ZDOTDIR="$AXOLOTTY_ZDOTDIR"
      unset AXOLOTTY_ZDOTDIR
    else
      unset ZDOTDIR
    fi
    {
      _ax_env="${ZDOTDIR-$HOME}/.zshenv"
      [[ -r "$_ax_env" ]] && builtin source -- "$_ax_env"
    } always {
      builtin unset _ax_env
    }
    if [[ -o interactive && -z "${_AX_HOOKED-}" ]]; then
      typeset -g _AX_HOOKED=1 _ax_ran=0 _ax_pathed=0
      builtin autoload -Uz add-zsh-hook
      _ax_osc7() {
        builtin local p="${PWD//\%/%25}"
        p="${p// /%20}"
        builtin printf '\e]7;file://%s%s\a' "${HOST}" "$p"
      }
      _ax_precmd() {
        builtin local ret=$?
        if [[ -n "${AXOLOTTY_BIN-}" && "${path[1]-}" != "$AXOLOTTY_BIN" ]] && (( ! _ax_pathed )); then
          # First prompt: after the person's rc files, so Axolotty's tools come first.
          path=("$AXOLOTTY_BIN" ${path:#$AXOLOTTY_BIN})
        fi
        _ax_pathed=1
        (( _ax_ran )) && builtin printf '\e]133;D;%s\a' "$ret"
        _ax_ran=0
        _ax_osc7
        builtin printf '\e]133;A\a'
      }
      _ax_preexec() {
        _ax_ran=1
        # The command line rides along (URL-encoded) for the host's command record.
        builtin local c="${1//\%/%25}"
        c="${c//$'\n'/%0A}"; c="${c//;/%3B}"; c="${c//$'\a'/%07}"; c="${c//$'\e'/%1B}"
        builtin printf '\e]133;C;cmdline_url=%s\a' "$c"
      }
      add-zsh-hook precmd _ax_precmd
      add-zsh-hook preexec _ax_preexec
      add-zsh-hook chpwd _ax_osc7
    fi
    """#

    /// bash's --rcfile. Works on bash 3.2 (macOS) and 5.
    static let bash = #"""
    # Axolotty shell integration for bash (the --rcfile). Reads the login files
    # a login bash would have read, then adds prompt marks (OSC 133, with the
    # command line) and the working directory (OSC 7). Generated; edits are
    # overwritten. Works alongside bash-preexec when the person uses it.
    if [ -n "${AXOLOTTY_BASH_LOGIN-}" ]; then
      unset AXOLOTTY_BASH_LOGIN
      [ -r /etc/profile ] && . /etc/profile
      for _ax_f in "$HOME/.bash_profile" "$HOME/.bash_login" "$HOME/.profile"; do
        if [ -r "$_ax_f" ]; then . "$_ax_f"; break; fi
      done
      unset _ax_f
    fi
    if [[ $- == *i* && -z "${_AX_HOOKED-}" ]]; then
      _AX_HOOKED=1
      _ax_ran=0
      _ax_armed=0
      if [[ -n "${AXOLOTTY_BIN-}" ]]; then
        PATH="$AXOLOTTY_BIN:${PATH//$AXOLOTTY_BIN:/}"
      fi
      _ax_osc7() {
        local p="${PWD//%/%25}"
        p="${p// /%20}"
        builtin printf '\e]7;file://%s%s\a' "${HOSTNAME}" "$p"
      }
      _ax_command_start() {
        local c="$1"
        c="${c//%/%25}"; c="${c//$'\n'/%0A}"; c="${c//;/%3B}"; c="${c//$'\a'/%07}"; c="${c//$'\e'/%1B}"
        _ax_ran=1
        builtin printf '\e]133;C;cmdline_url=%s\a' "$c"
      }
      _ax_precmd() {
        local ret=$?
        (( _ax_ran )) && builtin printf '\e]133;D;%s\a' "$ret"
        _ax_ran=0
        _ax_osc7
        builtin printf '\e]133;A\a'
        return $ret
      }
      if [[ -n "${bash_preexec_imported-}${__bp_imported-}" ]]; then
        _ax_preexec() { _ax_command_start "$1"; }
        precmd_functions=(_ax_precmd "${precmd_functions[@]}")
        preexec_functions+=(_ax_preexec)
      else
        # The DEBUG trap fires before every simple command: only the first
        # after a prompt starts a command line.
        _ax_debug() {
          (( _ax_armed )) || return 0
          [[ -n "${COMP_LINE-}" ]] && return 0
          [[ "$BASH_COMMAND" == _ax_precmd* ]] && return 0
          _ax_armed=0
          local line
          line=$(HISTTIMEFORMAT= builtin history 1 2>/dev/null)
          line="${line#"${line%%[![:space:]]*}"}"
          line="${line#*[[:space:]]}"
          line="${line#"${line%%[![:space:]]*}"}"
          _ax_command_start "${line:-$BASH_COMMAND}"
        }
        # Armed last, so the person's own PROMPT_COMMAND does not count as a command.
        _ax_arm() { _ax_armed=1; }
        trap '_ax_debug' DEBUG
        PROMPT_COMMAND="_ax_precmd${PROMPT_COMMAND:+; $PROMPT_COMMAND}; _ax_arm"
      fi
    fi
    """#

    /// fish ≥ 4 emits OSC 133 and OSC 7 itself: this only restores
    /// XDG_DATA_DIRS and puts Axolotty's CLI first after the person's config.
    static let fish = #"""
    # Axolotty shell integration for fish. Generated; edits are overwritten.
    if set -q AXOLOTTY_FISH_DATA
        set -gx XDG_DATA_DIRS (string match -v -- $AXOLOTTY_FISH_DATA (string split : -- $XDG_DATA_DIRS) | string join :)
        set -e AXOLOTTY_FISH_DATA
    end
    if status is-interactive; and set -q AXOLOTTY_BIN
        function __axolotty_path --on-event fish_prompt
            set -gx PATH $AXOLOTTY_BIN (string match -v -- $AXOLOTTY_BIN $PATH)
            functions -e __axolotty_path
        end
    end
    """#
}
#endif
