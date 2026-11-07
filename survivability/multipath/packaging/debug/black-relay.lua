-- black-relay.lua — Wireshark dissector for the Black Relay glorytun fork's
-- outer UDP packets (mud wire format).
--
-- Install: copy into your personal Lua plugins folder and restart Wireshark
--   macOS/Linux: ~/.local/lib/wireshark/plugins/
--   Windows:     %APPDATA%\Wireshark\plugins\
-- (Help > About Wireshark > Folders shows the exact path.)
--
-- Layout of every packet:  [6-byte timestamp/nonce][ciphertext][16-byte tag]
--   timestamp: little-endian 48-bit microseconds; low bit set = control msg.
--              With GT_HP=1 it is masked on the wire (looks random).
--   data packets: ciphertext = 8-byte sequence number + inner IP packet,
--              all encrypted, so neither is readable here.
-- Payload keys rotate (key exchange), so Wireshark cannot decrypt. Use
-- br-verify --key to unmask timestamps and to annotate each packet with
-- its lane, send order and delivery; the comments show up in this tree and
-- under "Packet comments".
--
-- Preferences (Edit > Preferences > Protocols > BLACKRELAY): UDP port range,
-- and whether header protection is on.

local p = Proto("blackrelay", "Black Relay (glorytun/mud)")

local f_hdr   = ProtoField.bytes("blackrelay.hdr", "Timestamp/nonce field")
local f_ts    = ProtoField.uint64("blackrelay.ts", "Sender timestamp (us)", base.DEC)
local f_kind  = ProtoField.string("blackrelay.kind", "Kind")
local f_ct    = ProtoField.bytes("blackrelay.ciphertext", "Ciphertext")
local f_tag   = ProtoField.bytes("blackrelay.tag", "Auth tag (16 bytes)")
local f_inner = ProtoField.uint16("blackrelay.inner_len", "Inner packet length if data (est.)", base.DEC)
local f_trunc = ProtoField.string("blackrelay.note", "Note")
p.fields = { f_hdr, f_ts, f_kind, f_ct, f_tag, f_inner, f_trunc }

p.prefs.ports = Pref.range("UDP ports", "5000-5250", "Tunnel UDP ports (server side)", 65535)
p.prefs.hp = Pref.bool("Header protection on (GT_HP=1)", true,
	"When on, the timestamp field is masked and shown as raw bytes only")

local SEQ, TS, TAG = 8, 6, 16

function p.dissector(tvb, pinfo, tree)
	local len = tvb:reported_length_remaining()
	if len < TS + TAG then return 0 end
	pinfo.cols.protocol = "BLACKRELAY"
	local t = tree:add(p, tvb(), "Black Relay (glorytun fork), " .. len .. " bytes")
	t:add(f_hdr, tvb(0, TS))

	local kind = "data"
	if p.prefs.hp then
		t:add(f_kind, "masked (header protection on; br-verify --key unmasks it)")
		kind = "masked"
	else
		local ts = tvb(0, TS):le_uint64()
		t:add(f_ts, tvb(0, TS), ts)
		if (ts % 2) == UInt64(1) then kind = "control" end
		t:add(f_kind, kind)
	end

	local captured = tvb:len()
	if captured >= len then
		t:add(f_ct, tvb(TS, len - TS - TAG))
		t:add(f_tag, tvb(len - TAG, TAG))
	else
		t:add(f_trunc, "capture truncated at " .. captured .. " of " .. len .. " bytes (snaplen)")
	end
	if kind ~= "control" and len > TS + TAG + SEQ then
		t:add(f_inner, len - TS - TAG - SEQ)
	end
	pinfo.cols.info = string.format("Black Relay %s, %d bytes", kind, len)
	return len
end

local udp = DissectorTable.get("udp.port")
local current = nil
local function register()
	if current then udp:remove(current, p) end
	current = p.prefs.ports
	udp:add(current, p)
end
function p.prefs_changed() register() end
register()
