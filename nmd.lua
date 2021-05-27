--[=[

	Not Markdown parser in Lua.
	Written by Cosmin Apreutesei. Public domain.

	It's better than other markdowns because:

	* it reports unmatched tags, mixed indentation, etc. with text positions.
	* bullet lists indented with tabs are not seen as code (tab-friendly lists!).
	* bullet lists don't need to start with a blank line.
	* supports markdown blocks in html tags (they must start with a blank line).
	* supports pandoc tables, for easy writing of API tables.
	* doesn't have 100 KLOC of C code like

	No attempt at compatibility with any spec was made here.
	What you see is what you get:

	* paragraphs separated by blank lines.
	* html blocks with markdown blocks inside.
	  * embedded markdown blocks must begin with a blank line.
	  * no parsing done inside <script> <pre> and <style> tags.
	  * reports unpaired tags.
	* inline html for a specific set of tags, otherwise `<`, `>`, and `&` are escaped.
	* backslash quoting for: \`*_{}()#+-.! .
	* <h1>, <h2> etc. with `# foo`, `## foo` etc.
	* <blockquote> with `> foo`.
	* <i> with `_foo_` or `*foo*`.
	* <b> with `__foo__` or `**foo**`.
	* <strike> with `~~foo~~`.
	* inline <pre> with `foo`.
	* <br> with "\" at the end of the line.
	* <a> with `[label]`, `[text][label]` or `[text](url)`.
	* <img> with `![label]`, `![alt][label]` or `![alt](url)`.
	  * text inside brackets can be any markdown text.
	  * TODO: test [![alt](image-url)]](link).
	* link definitions with `[label]: link`.
	* <ul>/<li> with indented `* foo` (works with tabs!).
	* <pre> blocks identified by indentation only.
	* <pre><code> blocks with ```lang\n ... ``` or ~~~{.lang}\n ... ~~~.
	* <hr> with `---`.
	* <table> with `--- ... ---` with blank lines between lines or not.

]=]

local glue = require'glue'

local add = table.insert
local push = table.insert
local pop = table.remove
local _ = string.format

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

local function link(text, url, image)
	if image then
		return _('<img src="%s" alt="%s">', url, text)
	else
		return _('<a href="%s">%s</a>', url, text)
	end
end

local function html(s) --TODO: escape <, >, &
	return s
end

local function parse(s)

	local t = {}
	local function out(s)
		t[#t+1] = s
		return #t
	end

	local links = {} --{label->{i=, text=, image=}}
	local function getlink(label)
		return glue.attr(links, label)
	end

	local cur_i = 1
	local errors = {} --{{line=, col=, error=},...}
	local function check(v, i, ...)
		if v then return v end
		pos = pos or textpos(s)
		local line, col = pos(cur_i + i - 1)
		add(errors, {line = line, col = col, error = _(...)})
	end

	local cur_blocks = {}

	local function open_block(indent, tag)
		push(cur_blocks, {indent = indent, tag = tag})
		out'\n<'; out(tag); out'>\n'
	end

	local function close_block()
		local block = pop(cur_blocks)
		out'\n</'; out(block.tag); out'>\n'
	end

	local function indent_level(s, i)
		local d = s:match('^[\t ]+', i) or ''
		for level = #cur_blocks, 1, -1 do
			local d1 = cur_blocks[level].indent
			if #d > #d1 then
				check(glue.starts(d, d1), i, 'mixed indentation')
				return level + 1, d
			elseif #d == #d1 then
				check(d == d1, i, 'mixed indentation')
				return level, d
			end
		end
		return

		local tabs = math.floor(#(s:gsub('[\t]', '    ')) / 4)
		return s, tabs
	end

	local function skip_blank_lines(s, i)
		local i0
		repeat
			i0 = i
			i = s:match('^[\t ]*\r?\n()', i)
		until not i
		return i0
	end

	local function md_blocks(s, i)
		local init_tabs = cur_tabs
		local init_n_blocks = #cur_blocks
		i = skip_blank_lines(s, i)
		local indent, tabs = line_indent(s, i)
		if tabs < init_tabs then --outdent: close child blocks and exit.
			while #cur_blocks > init_n_blocks do
				close_block()
			end
			return i
		elseif tabs > init_tabs then --indent: sub-list or pre block.
			if s:match('^[\t ]*[%*%+%-][\t ]+', i) then --sub-list
				open_block(indent, tabs, 'ul')
				list_block(s, i)
			else --pre block
				open_block(indent, tabs, 'pre')
				indented_code_block()
			end
		else --same indentation: any kind of block.

		end

	end

	md_blocks(s, 1)

	--resolve links
	for label,l in pairs(links) do
		if l.url and l.i then
			t[l.i] = link(l.text, l.url, l.image)
		end
	end

	return table.concat(t), errors
end

--self-test ------------------------------------------------------------------

if not ... then

pp(parse[[

	* item, indented, creates 1 indent level.
		* sub-item without paragraph
which can continue totally unindented.

		* sub-item on own paragraph

		  sub-item new paragraph (not enough indentation)

		sub-item new paragraph (no indentation)

	  item2 new paragraph little-indented
which can continue totally unindented.

			indent: embed code on same sub-item, new paragraph

			same code

			* still same code

		outdent: code ends, back to sub-item new paragraph

	outdent: back to item new paragraph

	still on item, can't embed code yet.


	two blank lines exits all lists, and now this is indented code.

]])

--[=[
pp(parse[[

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

### embedded markdown

	</p>
</p>new para

	this is
	code

>here's a __quote__ with \* and \_ and \_\_ and \*\* and \`...\`
**that** `_spans_` multiple
lines

[link]: http://link.com/

]])
]=]

end
