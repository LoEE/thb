local T = require'thread'
local D = require'util'

local M = {}
setmetatable(M, M)

-- private keys
local _observers = newproxy()
local _value = newproxy()
local onObserve = require'lib.cbstack'()



local mt = {}

function mt:__call(...)
  local o = setmetatable({}, self)
  return self.init and self.init(o, ...) or o
end

local function Class()
  local o = {}
  o.__index = o
  return setmetatable(o, mt)
end



local walk, walkattrs

local function joinkeys(a, b)
  if a then
    return a..'.'..b
  else
    return b
  end
end

function walk(ob, key, cbs)
  if type(ob) == 'table' then
    if ob[walk] then
      ob[walk](ob, key, cbs)
      return true
    elseif ob[M.observableAttributes] then
      walkattrs(ob, key, cbs)
      return true
    end
  end
end

function walkattrs(self, key, cbs)
  for _, k in ipairs(self[M.observableAttributes]) do
    local v = self[k]
    local childkey = joinkeys(key, k)
    if not walk(v, childkey, cbs) then
      if cbs.attribute then cbs.attribute(childkey, v) end
    end
  end
end

M.joinkeys = joinkeys
M.walk = walk
M.observableAttributes = newproxy()

function M.walkall(self, key, cbs)
  for k, v in pairs(self) do
    if type(k) == 'string' then
      local childkey = joinkeys(key, k)
      if not walk(v, childkey, cbs) then
        if cbs.attribute then cbs.attribute(childkey, v) end
      end
    end
  end
end




local Observable = Class()

function M:__call(...)
  return Observable(...)
end

function Observable:init(init, opts)
  self[_observers] = {}
  self[_value] = init
  if opts then
    self.read = opts.read
    self.write = opts.write
  end
end

function Observable:setcomputed(f, write)
  checks('Observable', 'function', 'function')
  if write and self.write then error('the observable already has a write callback', 2) end
  self.write = write
  write(self())

  local weakref = setmetatable({ self }, { __mode = 'v' })
  local dirty = true
  local color = true
  local list = {}

  local mark, note, update
  function mark()
    dirty = true
    T.Idle.call(update)
  end
  function note(ob, k)
    if list[ob] == nil then
      ob:watch(mark)
    end
    list[ob] = color
  end
  function update()
    dirty = false
    color = not color
    if weakref[1] then
      onObserve:push(note)
      local new = f()
      onObserve:pop()
      weakref[1]:rawset(new)
    end
    for ob,c in pairs(list) do
      if c ~= color then
        ob:unwatch(mark)
        list[ob] = nil
      end
    end
    if dirty then mark() end
  end

  update()
  return self
end

function Observable:__call(...)
  local old = self[_value]
  if select('#', ...) == 0 then
    onObserve(self)
    if self.read then
      return self:read(old)
    else
      return old
    end
  else
    local function handle_write(...)
      if select('#', ...) > 0 then
        local new = ...
        if old ~= new then
          self[_value] = new
          for _,fun in ipairs(self[_observers]) do
            T.queuecall(function () fun(new) end)
          end
        end
        return new
      end
    end
    if self.write then
      return handle_write(self:write(...))
    else
      return handle_write(...)
    end
  end
end

function Observable:rawset(new)
  if new ~= self[_value] then
    self[_value] = new
    for _,fun in ipairs(self[_observers]) do
      T.queuecall(function () fun(new) end)
    end
  end
end

function Observable:watch(fun)
  local o = self[_observers]
  assert(type(fun) == 'function', "function expected")
  o[#o+1] = fun
  return fun
end

function Observable:unwatch(fun)
  local o = self[_observers]
  for i=1,#o do
    if o[i] == fun then
      return table.remove(o, i)
    end
  end
  return fun
end

function Observable:__tostring()
  return 'o('..D.repr(self())..')'
end

Observable[walk] = function (self, key, cbs)
  if cbs.observable then cbs.observable(key, self) end
end



local ObservableDict = Class()
M.Dict = ObservableDict

function ObservableDict:init(init, opts)
  if init == nil then init = {} end
  assert(type(init) == 'table', 'the initial value of an ObservableDict has to be a table')
  rawset(self, _observers, {})
  rawset(self, _value, init)
  if opts then
    self.change = opts.change
  end
end

function ObservableDict:__index(k)
  onObserve(self, k)
  local v = self[_value][k]
  if v == nil then return getmetatable(self)[k] end
  return v
end

function ObservableDict:__newindex(k,v)
  assert(type(k) == 'string', 'ObservableDict keys have to be strings')
  local new
  if self.change then new = self:change(k, v) end
  if new == nil then new = v end
  if new ~= nil and self[_value][k] ~= nil then
    for _,fun in ipairs(self[_observers]) do
      T.queuecall(function () fun('del', k) end)
    end
  end
  self[_value][k] = new
  local action
  if v ~= nil then action = 'add' else action = 'del' end
  for _,fun in ipairs(self[_observers]) do
    T.queuecall(function () fun(action, k) end)
  end
end

function ObservableDict:__call(new)
  assert(not new, 'you cannot set ObservableDict value')
  onObserve(self)
  local keys = {}
  for k in pairs(self[_value]) do
    keys[#keys+1] = k
  end
  return unpack(keys)
end

ObservableDict.rawset = Observable.rawset

ObservableDict.watch = Observable.watch
ObservableDict.unwatch = Observable.unwatch

function ObservableDict:__tostring()
  return 'o.Dict('..D.repr(self())..')'
end

function ObservableDict:each()
  onObserve(self)
  return next, self[_value], nil
end

ObservableDict[walk] = function (self, key, cbs)
  if cbs.dict then cbs.dict(key, self) end
  if cbs.dict_item then
    for k, v in self:each() do
      if type(k) == 'string' then
        cbs.dict_item(key, k, v)
      end
    end
  end
end



function M.computed(f, write)
  local o
  if write then
    o = Observable(nil, { write = write })
  else
    o = Observable()
  end
  return o:setcomputed(f)
end



--[[
local time = Observable(T.now())
Observable.time = time
T.go(function ()
  while true do
    T.sleep(.2)
    time(T.now())
  end
end)

function M.timer()
  local start = time()
  return M.computed(
  function ()
    return time() - start
  end,
  function (ob, new)
    start = time() - new
    return new
  end)
end
--]]



return M
