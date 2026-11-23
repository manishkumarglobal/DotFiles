-- URL handler for claudejump://<percent-encoded tmux session name>
-- Exists only because macOS routes a clicked notification through a registered
-- URL scheme. It deliberately does no parsing: the whole URL is handed to
-- ~/.local/bin/claude-session-jump, which owns decoding and the jump itself,
-- so there is one place to fix if the mapping ever needs to change.
on open location this_URL
	try
		do shell script "/Users/manish/.local/bin/claude-session-jump " & quoted form of this_URL
	end try
end open location

