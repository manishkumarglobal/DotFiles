-- URL handler for claudejump://<percent-encoded tmux session name>
-- Exists only because macOS routes a clicked notification through a registered
-- URL scheme. It deliberately does no parsing: the whole URL is handed to
-- .local/bin/claude-session-jump under the home of the user running this app,
-- found when the click arrives so the source names no account. That helper owns
-- decoding and the jump itself, so there is one place to fix if the mapping
-- ever needs to change.
on open location this_URL
	try
		-- `path to home folder` ends with a slash. Quoted, so a home with spaces works.
		set jump_helper to (POSIX path of (path to home folder)) & ".local/bin/claude-session-jump"
		do shell script (quoted form of jump_helper) & " " & quoted form of this_URL
	end try
end open location
