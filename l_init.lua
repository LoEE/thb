os.executable_path, os.platform, os.arch = ...

_G.thb = {}

package.path = ''
package.cpath = ''

setmetatable(_G, {
  __newindex = function (_, n)
    error("error: write to a global variable: "..n, 2)
  end,
  __index = function (_, n)
    if n == 'D' or n == 'log' then rawset(_G, 'D', require'util') return _G[n] end
    error("error: read from a non-existing global variable: "..n, 2)
  end,
})

require'extensions'

local function addtoPATH(p)
  package.path = p..'/?.luac;'..p..'/?/init.luac;'..p..'/?.lua;'..p..'/?/init.lua;'..package.path
  package.cpath = p..'/?.so;'..package.cpath
end

os.executable_dir = os.dirname(os.executable_path)
addtoPATH(os.executable_dir..'/lualib')
addtoPATH(os.executable_dir..'/lualib/'..os.platform)

local main

local function drop_arguments(n)
  for i=0,#arg do
    arg[i] = arg[i+n]
  end
end

local function dofile_error(code, msg)
  io.stderr:write(msg..'\n')
  io.stderr:flush()
  os.exit(code)
end

local function dofile(fname)
  local fd, openerr = io.open(fname, 'r')
  if not fd then return dofile_error(3, 'Error loading file: '..fname..': '..openerr) end
  local src = assert(fd:read'*a')
  fd:close()
  local chunks = {string.format(
    "local __SRC_DIR = %q; local __MAIN__ = true; local rrequire = require;",
    os.dirname(fname)
  )}
  if src:startswith'#!' then chunks[#chunks+1] = '--' end
  chunks[#chunks+1] = src
  local i = 0
  local code, syntax_err = load(function () i = i + 1 return chunks[i] end, '@'..fname)
  if not code then return dofile_error(3, 'Syntax error:\n\t'..syntax_err) end
  local ok, err = xpcall(code, debug.traceback) local dofile_tb = debug.traceback():sub(18)
  local tb_prefix = "\9[C]: in function 'xpcall'\n" .. dofile_tb
  if not ok then
     -- remove pcall, dofile and our callers from the traceback
    if err:sub(#err - #tb_prefix + 1, -1) == tb_prefix then err = err:sub(1, #err - #tb_prefix) end
    dofile_error(4, err)
  end
end
thb.dofile = dofile

if not os.basename(arg[0]):startswith"thb" then
  -- FIXME: realpath does not work for executables in PATH
  os.program_path = os.dirname(os.realpath(arg[0]))
  addtoPATH(os.program_path)
  function main()
    local name = arg[0]
    if name:endswith".exe" then
      name = name:sub(1, -5)
    end
    dofile(name..'.lua')
  end
elseif arg[1] then
  if string.sub(arg[1], 1, 1) == ':' then
    arg[1] = os.executable_dir..'/'..string.sub(arg[1], 2)..'.lua'
  else
    local rpath = os.realpath(arg[1])
    if not rpath then io.stderr:write('error: file not found: '..arg[1]..'\n') os.exit(2) end
    os.program_path = os.dirname(os.realpath(arg[1]))
    addtoPATH(os.program_path)
  end
  function main()
    drop_arguments(1)
    dofile(arg[0])
    local loop = require'loop'
    loop.run()
  end
else
  function main()
    addtoPATH('.')
    local loop = require'loop'
    local repl = require'repl'
    repl.start(0)
    loop.run()
  end
end

main()
