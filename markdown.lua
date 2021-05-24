--[[

	Markdown parser in Lua.
	Written by Cosmin Apreutesei. Public domain.

	No attempt at compatibility with any spec was made here.
	What you see is what you get:

	* paragraphs separated by blank lines.
	* html blocks with markdown blocks inside.
	  * embedded markdown blocks must begin with a blank line.
	  * no parsing done inside <script> <pre> and <style> tags.
	  * bonus: raises on unpaired tags.
	* inline html, comes free as we're not escaping html inside markdown blocks.
	  * note: no raising on unpaired tags on inline html.
	* headers with `# foo`, `## foo` etc.
	* quotes with `> foo`.
	* italics with `_foo_` or `*foo*`.
	* bold with `__foo__` or `**foo**`.
	* strike-through with `~~foo~~`.
	* preformatted text with ``foo``.
	* backslash quoting for: \`*_{}()#+-.! .
	* links pointing to named links with `[label]` or `[text][label]`.
	* links pointing to urls with `[text](url)`.
	* image links with `!LINK`.
	* link definitions with `[label]: link`.
	* unordered lists with indented `* stuff`.
	* code blocks with tab indentation.
	* code blocks with `~~~{.lua} ... ~~~` or ``` ... ```.
	* tables with `--- ... ---` with blank lines between lines or not.

]]

local glue = require'glue'

local add = table.insert
local push = table.insert
local pop = table.remove
local _ = string.format
local attr = glue.attr

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

local function link(text, url, image)
	if image then
		return _('<img src="%s" alt="%s">', url, text)
	else
		return _('<a href="%s">%s</a>', url, text)
	end
end

local function md(s, out, assert, links)
	local i = 1
	local italic, bold, strike
	::next::
	local j = s:find('[\\_%*`~!%[]', i) --tokenize on \, _, __, *, **, `, ~~, !, [
	local ts = s:sub(i, j and j-1)
	if #ts > 0 then
		out(ts)
	end
	if not j then
		return --eof
	end
	i = j
	local c = s:sub(i, i)
	if c == '`' then
		local j = s:find('`', i+1)
		assert(j, i, 'unfinished "`"')
		out(s:sub(i+1, j-1))
		i = j+1
		goto next
	elseif c == '\\' or c == '_' or c == '*' or c == '~' then --possibly two-char
		local c2 = s:sub(i+1, i+1)
		if c == '\\' then --backslash quote
			assert(c2 ~= '', i, 'unfinished quote')
			out(c2)
			i = i+2
			goto next
		elseif c == '_' or c == '*' then --bold or italic
			if c2 == c then --bold
				bold = not bold
				assert(bold or (not strike and not italic), i, 'mismatched bold')
				out(bold and '<b>' or '</b>')
				i = i+2
			else
				italic = not italic
				assert(italic or (not strike and not bold), i, 'mismatched italic')
				out(italic and '<i>' or '</i>')
				i = i+1
			end
			goto next
		elseif c == '~' and c2 == '~' then
			strike = not strike
			assert(strike or (not bold and not italic), i, 'mismatched strike')
			out(strike and '<strike>' or '</strike>')
			i = i+2
			goto next
		end
	elseif c == '!' or c == '[' then --link
		local image
		if c == '[' then
			image = false
		elseif s:sub(i+1, i+1) == '[' then
		 	image = true
			i = i+1
		end
		if image ~= nil then
			local text, label, url
			text, j = s:match('^%[(.-)%]()', i)
			assert(text, i, '`]` expected')
			i = j
			url, j = s:find('^%((.-)%)()', i)
			if url then --[text](url), resolved now.
				out(link(text, url, image))
				i = j
			else --[text][label] or [label], resolved later.
				label, j = s:find('^%[(.-)%]()', i)
				if label then --[text][label]
					i = j
				else --[label]
					label = text
				end
				local out_i = out(text)
				local l = attr(links, label)
				l.i = out_i
				l.text = text
				l.image = image
			end
			goto next
		end
	end
	if c ~= '' then --false alarm (wasn't a token).
		out(c)
		i = i+1
		goto next
	end
end

local self_closing_tags = {
	area=1, base=1, br=1, col=1, embed=1, hr=1, img=1, input=1, link=1,
	meta=1, param=1, source=1, track=1, wbr=1,
}

local md_blocks --fw. decl.

local function html_block(s, i, out, assert, links)

	local open_tags = {}
	local text, indent, tag, attrs, end_tag, j

	local function out_md(s)
		local tag = open_tags[#open_tags]
		if tag ~= 'pre' and s:find'^[\t ]*\r?\n[\t ]*\r?\n' then
			--starts after a blank line: it's embedded markdown.
			local function block_assert(v, i1, ...)
				assert(v, i + i1 - 1, ...)
			end
			md_blocks(s, 1, out, block_assert, links)
		else
			out(s)
		end
	end

	out'\n'

	::next::

	text, indent, tag, attrs, j = s:match('^(.-)([\t ]*)<([%a][%w%-]*)(.-)>()', i)
	if text then
		out_md(text)
		out(indent); out'<'; out(tag); out(attrs); out'>'
		i = j
		tag = tag:lower()
		if tag == 'script' or tag == 'style' then
			end_tag, j = s:match('^(.-</'..glue.esc(tag, '*i')..'>)()', i)
			assert(end_tag, i, '<%s> tag not closed', tag)
			out(end_tag)
			i = j
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
		assert(#open_tags > 0, i, '</%s> when no tag is open', end_tag)
		assert(end_tag:lower() == open_tags[#open_tags],
				i, '</%s> inside <%s>', end_tag, open_tags[#open_tags])
		out_md(text)
		out(indent); out'</'; out(end_tag); out'>'
		pop(open_tags)
		i = j
		if #open_tags == 0 then
			goto done
		end
		goto next
	end

	assert(#open_tags == 0, i, '<%s> tag not closed', open_tags[#open_tags])

	::done::
	out'\n'
	return i
end

local function md_block(s, out, assert, links)
	local tabs = s:match'^[\t]*()' - 1
	local spcs = s:match'^[ ]*()' - 1

	if tabs == 0 and spcs == 0 then

		--headers with `# foo`, `## foo` etc.
		do local hashes, s = s:match'^#+()[\t ]*(.*)'
			if hashes then
				local n = tostring(hashes - 1)
				out'\n<h'; out(n); out'>'; md(s, out, assert, links); out'</h'; out(n); out'>\n'
				return
			end
		end

		--quotes with `>foo`
		do local s = s:match'^>[\t ]*(.*)'
			if s then
				out'\n<blockquote>'; md(s, out, assert, links); out'</blockquote>\n'
				return
			end
		end

		--link defs with `[label]: url`
		do local label, url = s:match'^%[(.-)%]:[\t ]*(.*)'
			if label then
				attr(links, label).url = url
				return
			end
		end

		--normal markdown paragraph.
		out'\n<p>'; md(s, out, assert, links); out'</p>\n'

	end

end

--markdown blocks are separated by one or more blank lines.
--[[local]] function md_blocks(s, i, out, assert, links)

	::again::

	--skip any blank lines at the beginning.
	local next_i = s:match('^[\t ]*\r?\n()', i)
	if next_i then
		i = next_i
		goto again
	end

	--embedded html block: the html parser tells us where it ends.
	if s:find('^<%a', i) then
		i = html_block(s, i, out, assert, links)
		goto again
	end

	--first blank line closes this block and starts another block.
	local j, next_i = s:match('()\r?\n[\t ]*\r?\n()', i)

	--last line or eof closes this block and the file.
	j = j or s:match('()\r?\n[\t ]*$', i) or #s + 1

	local bs = s:sub(i, j-1)
	if #bs > 0 then
		local function block_assert(v, i1, ...)
			assert(v, i + i1 - 1, ...)
		end
		md_block(bs, out, block_assert, links)
	end

	if next_i then
		i = next_i
		goto again
	end

end

local function parse(s)

	local t = {}
	local links = {} --{label->{i=, text=, image=}}
	local function out(s)
		t[#t+1] = s
		return #t
	end
	local function assert(v, i, ...)
		if v then return v end
		raise(s, i, ...)
	end
	md_blocks(s, 1, out, assert, links)

	--resolve links
	for label,l in pairs(links) do
		if l.url and l.i then
			t[l.i] = link(l.text, l.url, l.image)
		end
	end

	return table.concat(t)
end

--self-test ------------------------------------------------------------------

if not ... then

print(parse[[

# H1

## H2

some paragraph ![link] whatever.

another one

<script>

	<p>

</script>

<p>
	<p>
		<img blah>

s

	</p>
</p>new para

>here's a __quote__ with \* and \_ and \_\_ and \*\* and \`...\`
**that** `_spans_` multiple
lines

[link]: http://link.com/

]])

end
