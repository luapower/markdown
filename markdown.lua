--[[

	Markdown parser in Lua.
	Written by Cosmin Apreutesei. Public Domain.

	Implemented features:
	- paragraphs separated by blank lines.
	- html blocks with markdown inside (except for <script> <pre> and <style> tags).
		- bonus: raises on invalid tag trees.
	- inline html.
	- headers with `# foo`, `## foo` etc.
	- quotes with `> foo`
	- italics with `_foo_`
	- bold with `__foo__`
	- strike-through with `~~foo~~`
	- links pointing to named links with `[label]` or `[text][label]`
	- links pointing to urls with `[text](url)`
	- named links with `[label]: link`
	- embedded code with `code`
	- lists with indented `* stuff`
	- code blocks with tab indentation
	- code blocks with `~~~{.lua} ... ~~~`
	- tables with `--- ... ---` with blank lines between lines or not.
]]

local add = table.insert
local push = table.insert
local pop = table.remove
local _ = string.format
local glue = require'glue'

--for a string, return a function that given a byte index in the string
--returns the line and column numbers corresponding to that index.
local function textpos(s)
	--collect char indices of all the lines in s, incl. the index at #s + 1
	local t = {}
	for i in s:gmatch'()[^\r\n]*\r?\n?' do
		t[#t+1] = i
	end
	assert(#t >= 2)
	return function(i)
		--do a binary search in t to find the line
		assert(i > 0 and i <= #s + 1)
		local min, max = 1, #t
		while true do
			local k = math.floor(min + (max - min) / 2)
			if i >= t[k] then
				if k == #t or i < t[k+1] then --found it
					return k, i - t[k] + 1
				else --look forward
					min = k
				end
			else --look backward
				max = k
			end
		end
	end
end

--raise an error for something that happened at s[i], so that position in
--file (line, column) can be printed. if i is nil, eof is assumed.
--if s is nil, no position info is printed with the error.
local function raise(s, i, err, ...)
	err = _(err, ...)
	local where
	if s then
		if i then
			local pos = textpos(s)
			local line, col = pos(i)
			where = _('line %d, col %d', line, col)
		else
			where = 'eof'
		end
		err = _('error at %s: %s.', where, err)
	else
		err = _('error: %s.', err)
	end
	error(err, 2)
end

local function md(s, out)
	--TODO: encode ampersands etc.
	out(s)
end

local self_closing_tags = {
	area = 1,
	base = 1,
	br = 1,
	col = 1,
	embed = 1,
	hr = 1,
	img = 1,
	input = 1,
	link = 1,
	meta = 1,
	param = 1,
	source = 1,
	track = 1,
	wbr = 1,
}

local md_blocks --fw. decl.

local function html_block(s, i, out, raise)

	local open_tags = {}
	local text, indent, tag, attrs, end_tag, j

	local function out_md(s)
		local tag = open_tags[#open_tags]
		if tag ~= 'pre' and s:find'^[\t ]*\r?\n[\t ]*\r?\n' then
			--starts after a blank line: it's embedded markdown.
			local function block_raise(i1, ...)
				raise(i + i1 - 1, ...)
			end
			md_blocks(s, 1, out, block_raise)
		else
			out(s)
		end
	end

	out'\n'

	::next::

	text, indent, tag, attrs, j = s:match('^(.-)([\t ]*)<([%a][%w%-]*)(.-)>()', i)
	if text then
		out_md(text)
		out(indent, '<', tag, attrs, '>')
		i = j
		tag = tag:lower()
		if tag == 'script' or tag == 'style' then
			end_tag, j = s:match('^(.-</'..glue.esc(tag, '*i')..'>)()', i)
			if end_tag then
				out(end_tag)
				i = j
			else
				raise(i, '<%s> tag not closed', tag)
			end
		elseif not self_closing_tags[tag] then
			add(open_tags, tag)
		end
		if #open_tags == 0 then
			goto done
		end
		goto next
	end

	text, indent, end_tag, j = s:match('^(.-)([\t ]*)</([%a][%w-]*)>()', i)
	if text then
		if #open_tags > 0 then
			if end_tag:lower() ~= open_tags[#open_tags] then
				raise(i, '</%s> inside <%s>', end_tag, open_tags[#open_tags])
			end
		else
			raise(i, '</%s> when no tag is open', end_tag)
		end
		out_md(text)
		out(indent, '</', end_tag, '>')
		pop(open_tags)
		i = j
		if #open_tags == 0 then
			goto done
		end
		goto next
	end

	if #open_tags > 0 then
		raise(i, '<%s> tag not closed', open_tags[#open_tags])
	end

	::done::
	out'\n'
	return i
end

local function md_block(s, out, raise)
	local tabs = s:match'^[\t]*()' - 1
	local spcs = s:match'^[ ]*()' - 1

	if tabs == 0 and spcs == 0 then

		--headers with `# foo`, `## foo` etc.
		do local hashes, s = s:match'^#+()[\t ]+(.*)'
			if hashes then
				local n = tostring(hashes - 1)
				out('\n<h', n, '>'); md(s, out); out('</h', n, '>\n')
				return
			end
		end

		--

		out('\n<p>'); md(s, out); out('</p>\n')

	end

end

--markdown blocks are separated by one or more blank lines.
--[[local]] function md_blocks(s, i, out, raise)

	::again::

	--skip any blank lines at the beginning.
	local next_i = s:match('^[\t ]*\r?\n()', i)
	if next_i then
		i = next_i
		goto again
	end

	--embedded html block: the html parser tells us where it ends.
	if s:find('^<%a', i) then
		i = html_block(s, i, out, raise)
		goto again
	end

	--first blank line closes this block and starts another block.
	local j, next_i = s:match('()\r?\n[\t ]*\r?\n()', i)

	--last line or eof closes this block and the file.
	j = j or s:match('()\r?\n[\t ]*$', i) or #s + 1

	local bs = s:sub(i, j-1)
	if #bs > 0 then
		local function block_raise(i1, ...)
			raise(i + i1 - 1, ...)
		end
		md_block(bs, out, block_raise)
	end

	if next_i then
		i = next_i
		goto again
	end

end

local function parse(s)
	local t = {}
	local function out(...)
		for i = 1, select('#', ...) do
			local s = select(i, ...)
			t[#t+1] = s
		end
	end
	local function block_raise(i, ...)
		raise(s, i, ...)
	end
	md_blocks(s, 1, out, block_raise)
	print(table.concat(t))
end

parse[[

# H1

## H2

some paragraph [link] whatever.

another one

<script>

	<p>

</script>

<p>
	<p>
		<img blah>

s

	</p>
</p>

new para

]]
