local D = require'util'
local O = require'o'
local T = require'thread'
local B = require'binary'
local o = require'kvo'
local bit_ok, bit = T.spcall(require, 'bit') if not bit_ok then bit = nil end
local bit32_ok, bit32 = T.spcall(require, 'bit32') if not bit32_ok then bit32 = nil end

-- all flags are >> 1 compared to sepack-lpc1342 C code
local NO_REPLY_FLAG = 0x01


-- misc:
local function hex_trunc (data, maxlen)
  if #data > maxlen then
    return D.unq(B.bin2hex(data:sub(1,maxlen))..'…')
  else
    return D.unq(B.bin2hex(data))
  end
end

local function checkerr(data)
  if #data == 0 then return nil, "timeout" end
  if string.byte(data, 1) == 0 then
    error(string.sub(data, 2))
  end
  return string.sub(data, 2)
end

local function ExtProc_connect(address)
  local log = log:sub'ext':off()
  local host, port = string.match(address, "tcp:(.-):(.-)")
  if host and port then
    return require'cosepack-serial':newTCP(host, 9090, log)
  end
  local devname = string.match(address, "serial:(.-)")
  if devname then
    return require'cosepack-serial':new('/dev/ttyS1', log)
  end
  local usb_spec = string.match(address, "usb:?(.-)")
  if usb_spec then
    local usb_product, usb_serial
    if usb_spec:startswith("SEPACK-") then
      usb_product = usb_spec
    else
      usb_serial = usb_spec
    end
    return require'extproc':newUsb(usb_product, usb_serial, log)
  end
  error('invalid sepack address: '..tostring(address))
end



-- main class:
local Sepack = O()

-- an alternative (convenience) constructor
Sepack.open = function (self, args)
  args = args or {}
  local addr = args.address or "usb"
  local ext = ExtProc_connect(addr)
  local log = args.log or log:sub'sepack'
  local sepack = self:new(ext, log)
  sepack.address = addr
  return sepack
end

-- the canonical constructor
Sepack.new = O.constructor(function (self, ext, _log)
  self.verbose = 2
  self.log = _log or log.null
  self.ext = ext
  self._coldplug_wait = true
  self.connected = o()
  self.serial = ext.serial
  self.serial_number = o.computed(function ()
    local sn = self.serial()
    if not sn then return nil end
    local num = string.match(sn, ".+-([0-9]+)")
    return tonumber(num)
  end)
  self.channels = {}

  T.go(self._in_loop, self)
end)

function Sepack:wait()
  while true do
    local connected = self.connected()
    if connected == true then
      return self
    elseif connected == false then
      self.log:warn('• still looking for a sepack on '..self.address)
    end
    self.connected:recv()
  end
end




function Sepack:_ext_status(status)
  if status == 'connect' then
    self._coldplug_wait = nil
    T.go(self._enumerate, self)
  elseif status == true then
  elseif status == 'coldplug end' then
    self._coldplug_wait = nil
    self.connected(false)
  else
    if self._coldplug_wait then return end
    if self.verbose > 2 then self.log:green('÷ status:', status, self.connected()) end
    if status == false and self.connected() then self:on_disconnect() end
    self.connected(false)
  end
end

function Sepack:_enumerate()
  self:_addchn(0, 'control', 'force-init')
  for i, name in ipairs(self.channels.control.channel_names) do
    self:_addchn(i, name)
  end
  if self.verbose > 0 then self.log:green'÷ ready' end
  self.connected(true)
end

function Sepack:on_disconnect()
  local chns = self.channels
  for i=0,#chns do
    chns[i]:on_disconnect()
  end
end

function Sepack:_parsechnname(str)
  local type, name = string.match(str, "([^:]*):(.*)")
  if not type then return str, str end
  return type, name
end

function Sepack:_addchn(id, namedesc, forceinit)
  local type, name = self:_parsechnname(namedesc)
  local chn = self.channels[id]
  if chn then
    if chn.name ~= name then
      error(string.format("channel change after reconnecting: %s -> %s", chn.name, name), 0)
    end
    chn:on_connect()
  else
    if self.channels[name] and self.channels[name].id ~= id then
      error(string.format("duplicate channel name: %s [no. %d and %d]", name, self.channels[name].id, id), 0)
    end
    local CT = self.channeltypes._default
    for k, v in pairs(self.channeltypes) do
      if string.startswith(type, k) then CT = v break end
    end
    chn = CT:new(self, id, name)
    self.channels[name] = chn
    self.channels[id] = chn
    chn:on_connect()
    chn:init()
  end
end

function Sepack:chn(name)
  local chn = self.channels[name]
  if not chn then return error('unknown channel: '..name, 0) end
  return chn
end

do
  local function parse_packet(p, i, implicit_length)
    local head = p:byte(i)
    local id, final, flags
    if bit ~= nil then
      id = bit.band(head, 0xf)
      final = bit.band(head, 0x10) == 0
      flags = bit.rshift(bit.band(head, 0xe0), 5)
    else
      id = bit32.extract (head, 0, 4)
      final = bit32.extract (head, 4) == 0
      flags = bit32.extract (head, 5, 3)
    end
    local len, data
    if implicit_length then
      len = #p - 1
      data = p:sub(i+1)
      i = i+1+len
    else
      len = p:byte(i+1)
      data = p:sub(i+2, i+2+len-1)
      i = i+2+len
    end
    return id, data, flags, final, i
  end

  function Sepack:_in_loop ()
    local events = {
      [self.ext.inbox] = function (p)
        if self.verbose > 2 then self.log:cyan(string.format('<<[%d]', #p), hex_trunc(p, 20)) end
        local i = 1
        local id, data, flags, final
        while i <= #p do
          id, data, flags, final, i = parse_packet(p, i, self.ext.implicit_length)
          local channel = self.channels[id]
          if self.verbose > 1 or not channel then
            self.log:green(string.format('<%s%s:%x', channel and channel.name or 'ch?',
                                                     final and "" or "+",
                                                     flags),
                           D.hex(data))
          end
          if channel then
            -- channel.bytes_received = (channel.bytes_received or 0) + #data
            channel:_handle_rx(data, flags, final)
          end
        end
      end,
      [self.ext.status] = function (...) self:_ext_status(...) end,
    }
    while true do T.recv(events) end
  end
end

do
  local function format_packet(id, data, flags, final, implicit_length)
    flags = (flags or 0) * 2
    if not final then flags = flags + 1 end
    if implicit_length then
      return string.char(id + (flags * 16))..data
    else
      return string.char(id + (flags * 16), #data)..data
    end
  end

  function Sepack:write (channel, data, flags)
    if self.verbose > 1 then self.log:green(string.format ("%s:%x>", channel.name, flags or 0), D.hex(data)) end
    local pkgs = {}
    repeat
      local final = #data <= 62
      local p = format_packet(channel.id, data:sub(1,62), flags, final, self.ext.implicit_length)
      pkgs[#pkgs+1] = p
      data = data:sub(63)
    until #data == 0
    if self.ext.implicit_length then
      for _,out in ipairs(pkgs) do
        if self.verbose > 2 then
          self.log:cyan(string.format('>>[%d]', #out), hex_trunc(out, 20))
        end
        self.ext.outbox:put(out)
      end
    else
      local out = table.concat(pkgs)
      if self.verbose > 2 then self.log:cyan(string.format('>>[%d]', #out), hex_trunc(out, 20)) end
      self.ext.outbox:put(out)
    end
  end
end

function Sepack:setup (channel, data)
  data = data or ''
  return self:chn'control':xchg(string.char(channel.id)..data)
end



local function add_threadsafety(channel)
  function channel:_inbox_put(data)
    local chn = table.remove(self.reply_chns, 1)
    if not chn then error('spurious reply received: '..data) end
    chn:put(data)
  end

  function channel:on_connect()
    self.reply_chns = {}
  end

  function channel:on_disconnect()
    local rc = self.reply_chns
    self.reply_chns = nil
    for i=1,#rc do rc[i]:put("") end
  end

  function channel:recv()
    error("only use xchg on the "..self.name.." channel")
  end

  function channel:xchg(data)
    local chn = T.Mailbox:new()
    local rc = self.reply_chns
    if not rc then return "" end
    rc[#rc+1] = chn
    self:write(data, 0)
    return chn:recv()
  end
end



local CT = {}
Sepack.channeltypes = CT



CT._default = O()

CT._default.new = O.constructor(function (self, sepack, id, name)
  self.sepack = sepack
  self.id = id
  self.name = name
  self.inbox = T.Mailbox:new()
  self.buffer = {}
  self.busy = false
  self.connected = o(false)
end)

function CT._default:_decode(data)
  return data
end

function CT._default:_inbox_put(data)
  self.inbox:put(data)
end

function CT._default:_handle_rx(data, flags, final)
  local b = self.buffer
  local r
  if b == false then
    r = data
  else
    b[#b+1] = data
    if final then
      data = table.concat(b)
      for i=1,#b do b[i] = nil end
      r = data
    end
  end
  if r then self:_inbox_put(self:_decode(r)) end
end

function CT._default:init()
end

function CT._default:write(data, flags)
  flags = flags or NO_REPLY_FLAG
  self.sepack:write(self, data, flags)
end

function CT._default:setup(data)
  return checkerr(self.sepack:setup(self, data))
end

function CT._default:on_connect()
  self.connected(true)
end

function CT._default:on_disconnect()
  self.connected(false)
  if self.busy then self.inbox:put("") end
end

function CT._default:xchg(data)
  if not self.connected() then return "" end
  self:write(data, 0)
  local r = self:recv()
  return r
end

function CT._default:recv()
  if self.busy then error("multiple recvs detected on channel: "..self.name, 1) end
  self.busy = true
  return (function (...)
    self.busy = false
    return ...
  end)(self.inbox:recv())
end

function CT._default:__tostring()
  return string.format("<%d:%s>", self.id, self.name)
end



CT.control = O(CT._default)
add_threadsafety(CT.control)

function CT.control:init()
  self.inbox = nil -- only xchg should be used
  local names = self.sepack:setup(self)
  assert(#names > 0)
  names = string.split(names, ' ')
  table.remove(names, 1) -- drop 'control'
  self.channel_names = names
end

CT.control.__tostring = CT._default.__tostring



CT.uart = O(CT._default)

function CT.uart:init()
  self.last_timeouts = {}
  self.last_flags = {}
end

function CT.uart:setup(baud, bits, parity, stopbits)
  self.baud = baud
  self.bits = bits or 8
  self.parity = parity or 'N'
  self.stopbits = stopbits or 1
  self.last_setup = B.flat{'s', B.enc32BE(self.baud), self.bits, self.parity, self.stopbits}
  checkerr(self.sepack:setup(self, self.last_setup))
end

function CT.uart:on_connect()
  CT._default.on_connect(self)
  if self.last_setup then checkerr(self.sepack:setup(self, self.last_setup)) end
  if self.last_timeouts then
    for type,ms in pairs(self.last_timeouts) do
      self:settimeout(type, ms)
    end
  end
  if self.last_flags then
    for type,on in pairs(self.last_flags) do
      self:setflag(type, on)
    end
  end
end

do
  local timeouts = {
    rx = 'i',
    tx = 'o',
    reply = 'r',
  }
  function CT.uart:settimeout(type, ms)
    local t = timeouts[type]
    if not t then error('invalid timeout type: '..type) end
    self.last_timeouts[type] = ms
    checkerr(self.sepack:setup(self, B.flat{t, B.enc16BE(ms * 10)}))
  end
end

do
  local flags = {
    ext = 'x',
    cts = 'c',
  }
  function CT.uart:setflag(type, on)
    local t = flags[type]
    if not t then error('invalid flag: '..type) end
    self.last_flags[type] = on
    checkerr(self.sepack:setup(self, B.flat{t, on}))
  end
end

CT.uart.__tostring = CT._default.__tostring



CT.gpio = O(CT._default)
add_threadsafety(CT.gpio)

do
  local chainer = O()

  chainer.new = O.constructor(function (self, gpio)
    self.gpio = gpio
    self._pull = 'up'
    self._hyst = true
    self.cmds = {}
    self.rets = {}
  end)

  function chainer:push(...)
    for i=1,select('#', ...) do
      local v = select(i, ...)
      assert(type(v) == 'string')
      self.cmds[#self.cmds+1] = v
    end
  end

  local _pullmap = { up = 'u', down = 'd', repeater = 'r', none = 'z' }
  function chainer:_setpull(pull)
    if pull ~= self._pull then
      local v = _pullmap[pull]
      if not v then error('invalid PULL option: '..pull) end
      self:push('S', v)
      self._pull = pull
    end
  end

  function chainer:_sethyst(hyst)
    if hyst ~= self._hyst then
      local v
      if hyst then v = 'h' else v = 'l' end
      self:push('S', v)
      self._hyst = hyst
    end
  end

  function chainer:setup(name, mode, ...)
    local pin = self.gpio:_getpin(name)
    local pull = 'up'
    local hyst = true
    for i=1,select('#', ...) do
      local v = select(i, ...)
      assert(type(v) == 'string', 'gpio setup option is not a string')
      if v:startswith('pull-') then
        pull = v:sub(6)
      elseif v == 'no-hystheresis' then
        hyst = false
      else
        error('unknown gpio setup option: '..v)
      end
    end
    self:_setpull(pull) self:_sethyst(hyst)
    local cmd
    if mode == 'in' then
      cmd = 'I'
    elseif mode == 'out' then
      cmd = 'O'
    elseif mode == 'peripheral' then
      cmd = 'P'
    else
      error('invalid gpio mode: '..mode)
    end
    self:push(cmd, pin)
    return self
  end

  function chainer:output(name)
    return self:setup(name, 'out', 'pull-none', 'no-hystheresis')
  end

  function chainer:input(name, ...)
    return self:setup(name, 'in', ...)
  end

  function chainer:peripheral(name, ...)
    return self:setup(name, 'peripheral', ...)
  end

  function chainer:float(name)
    return self:setup(name, 'in', 'pull-none')
  end

  function chainer:delay(ms)
    self:push('d', B.enc16BE(ms - 1))
    return self
  end

  function chainer:read(name, key)
    if not key then key = name end
    self.rets[#self.rets+1] = key
    self:push('r', self.gpio:_getpin(name))
    return self
  end

  function chainer:write(name, v)
    local cmd
    if v then cmd = '1' else cmd = '0' end
    self:push(cmd, self.gpio:_getpin(name))
    return self
  end

  function chainer:hi(name)
    return self:write(name, true)
  end

  function chainer:lo(name)
    return self:write(name, false)
  end

  function chainer:run()
    local reply = self.gpio:xchg(table.concat(self.cmds))
    local t = {}
    if #reply > 0 then
      local iptr = 1
      local optr = 1
      while iptr < #reply do
        if reply:sub(iptr,iptr) == 'r' then
          if not self.rets[optr] then error('unexpected reply byte @ '..iptr) end
          t[self.rets[optr]] = reply:byte(iptr+1,iptr+1)
          iptr = iptr + 2
          optr = optr + 1
        else
          error('invalid reply byte @ '..iptr)
        end
      end
    end
    return t
  end

  CT.gpio._chainer = chainer
end

do
  local pin = O()

  pin.new = O.constructor(function (self, gpio, name)
    self.gpio = gpio
    self.name = name
  end)

  function pin:read()
    return self.gpio:seq():read(self.name):run()[self.name]
  end

  for _,method in ipairs{'setup', 'output', 'input', 'float', 'peripheral',
                         'write', 'hi', 'lo', } do
    pin[method] = function (self, ...)
      local seq = self.gpio:seq()
      seq[method](seq, self.name, ...)
      return seq:run()
    end
  end
  CT.gpio._pin = pin
end

function CT.gpio:init()
  local pins = self.sepack:setup(self)
  assert(#pins > 0)
  pins = pins:split(' ')
  local result = {}
  for i, pin in ipairs(pins) do
    local names, modes = pin:splitv(':')
    names = names:split('/')
    local name
    if not modes:find('p') then name = names[1] else name = names[2] end
    result[i-1] = { name = name, modes = modes, }
    for _, alias in ipairs(names) do result[alias] = i-1 end
  end
  self.pins = result
  return result
end

function CT.gpio:alias(old, new)
  self:_getpin(old)
  assert(not self.pins[new], "gpio pin name in use")
  self.pins[new] = self.pins[old]
end

function CT.gpio:_getpin(name)
  local pin = self.pins[name]
  if type(pin) ~= 'number' then error('unknown gpio pin: '..name) end
  return string.char(pin)
end

function CT.gpio:seq()
  return self._chainer:new(self)
end

function CT.gpio:pin(name)
  self:_getpin(name)
  return self._pin:new(self, name)
end

CT.gpio.__tostring = CT._default.__tostring



CT.notify = O(CT._default)

function CT.notify:init()
  self.pins = {}
  local pins = self.sepack:setup(self):split(' ')
  local result = {}
  for i, pin in ipairs(pins) do
    local names, _ = pin:splitv(':')
    names = names:split('/')
    local name = names[1]
    result[i-1] = name
    self.pins[name] = o()
    self.pins['n'..name] = o()
    for _, alias in ipairs(names) do result[alias] = i-1 end
  end
  self._pins = result
end

function CT.notify:_decode(data)
  if not self._pins then return {} end
  if data:startswith('n') or data:startswith('r') then
    local changes = {}
    for off=2,#data,2 do
      local i, v = string.byte(data, off, off+1)
      local name = self._pins[i]
      v = v == 1
      changes[name] = v
    end
    return changes
  else
    return {}
  end
end

function CT.notify:_inbox_put(changes)
  if type(changes) ~= 'table' then error('malformed packet: '..D.repr(changes)) end
  for name, v in pairs(changes) do
    self.pins[name](v)
    self.pins['n'..name](not v)
  end
end

function CT.notify:on_connect()
  CT._default.on_connect(self)
  if self.debouncetimes then
    for name, ms in pairs(self.debouncetimes) do
      self:setdebounce(name, ms)
    end
    self:write'r'
  end
end

function CT.notify:_getpin(name)
  local pin = self._pins[name]
  if type(pin) ~= 'number' then error('unknown notify pin: '..name) end
  return string.char(pin)
end

function CT.notify:setdebounce(name, ms)
  if not self.debouncetimes then self.debouncetimes = {} self:write'r' end
  local pin = self:_getpin(name)
  checkerr(self.sepack:setup(self, 't'..pin..B.enc16BE(ms)))
  self.debouncetimes[name] = ms
end

CT.notify.__tostring = CT._default.__tostring



CT.adc = O(CT._default)

function CT.adc:start(fs)
  local reply = checkerr(self.sepack:setup(self, B.enc32BE(fs)))
  if reply then
    return B.dec32BE(reply) / 256
  else
    return nil, "timeout"
  end
end

function CT.adc:stop()
  checkerr(self.sepack:setup(self, B.enc32BE(0)))
end

function CT.adc:_decode(data)
  local r = {}
  assert(#data % 2, "invalid ADC data length")
  for i=1,#data,2 do
    local v = B.dec16BE(data, i)
    r[#r+1] = v
  end
  return r
end

CT.adc.__tostring = CT._default.__tostring


CT.spi = O(CT._default)

function CT.spi:setup_master(clk, bits, cpol, cpha)
  self.clk = clk
  self.bits = bits or 8
  self.cpol = cpol or 1
  self.cpha = cpha or 1
  local new = B.flat{'M', self.bits, self.cpol, self.cpha, B.enc32BE(self.clk)}
  if new ~= self.last_setup then
    self.last_setup = new
    local reply = checkerr(self.sepack:setup(self, self.last_setup))
    if reply then
      return B.dec32BE(reply)
    else
      return nil, "timeout"
    end
  end
end

function CT.spi:setup_slave(bits, cpol, cpha)
  self.bits = bits or 8
  self.cpol = cpol or 1
  self.cpha = cpha or 1
  local new = B.flat{'S', self.bits, self.cpol, self.cpha}
  if new ~= self.last_setup then
    self.last_setup = new
    return checkerr(self.sepack:setup(self, self.last_setup))
  end
end

function CT.spi:on_connect()
  CT._default.on_connect(self)
  if self.last_setup then checkerr(self.sepack:setup(self, self.last_setup)) end
end


CT.spi.__tostring = CT._default.__tostring



CT.watchdog = O(CT._default)

function CT.watchdog:on_connect()
  if not self.status then self.status = o(false) end
  CT._default.on_connect(self)
  local ok, err = T.pcall(function ()
    local uptime = self:getuptime()
    local reset = self:reset_status()
    if not next(reset) then reset = nil end
    self.status({ uptime = uptime, reset = reset })
  end)
  if not ok then
    self.status({ error = err })
  end
end

function CT.watchdog:auto()
  self.watcher = self.status:watch(function () self.sepack.log:struct('connect', self.status()) end)
  self.sepack.log:struct('connect', self.status())
  self.feeder_thd = T.go(function()
    while true do
      self:write('-')
      T.sleep(5)
    end
  end)
end

function CT.watchdog:query()
  local reply = self:setup('?')
  if not reply then return nil, "timeout" end
  local _, time_left = B.unpack(reply, ">s4")
  local mode
  if time_left < 0 then
    mode = "reset"
    time_left = -time_left
  else
    mode = "countdown"
  end
  return mode, time_left
end

function CT.watchdog:reset_status()
  local reply = self:setup('R')
  if not reply then return nil, "timeout" end
  local _, status = B.unpack(reply, ">s4")
  local b = B.unpackbits(status, 'soft bod wdt ext por')
  for k,v in pairs(b) do if not v then b[k] = nil end end
  return b
end

function CT.watchdog:getuptime()
  local reply = self:setup('B')
  if not reply then return nil, "timeout" end
  return B.dec32BE(reply)
end

function CT.watchdog:settimer(val)
  return self:setup('='..B.enc32BE(val))
end

function CT.watchdog:feed()
  self:write('0')
end

CT.watchdog.__tostring = CT._default.__tostring



CT.phy = O(CT._default)

CT.phy.PHYS = { [0] = "none", "rs485ch1", "rs485ch2", "rs232ch1", "rs232ch2", "mdb" }
for k,v in pairs(CT.phy.PHYS) do CT.phy.PHYS[v] = k end

function CT.phy:init()
  self.assignments = {}
end

function CT.phy:setup(uart, phy)
  checks('table', 'number', 'string')
  if uart < 0 or uart > 2 then error('invalid UART id: '..tostring(uart)) end
  local phyid = self.PHYS[phy]
  if not phyid then error('invalid PHY: '..phy) end
  self.assignments[uart] = phy
  self:write(string.char(uart, phyid))
end

function CT.phy:on_connect()
  CT._default.on_connect(self)
  if self.assignments then
    for k,v in pairs(self.assignments) do
      self:setup(k, v)
    end
  end
end

CT.phy.__tostring = CT._default.__tostring



CT.pwm = O(CT._default)

CT.pwm.VALID_IDS = { [1] = true, [2] = true, [3] = true }

function CT.pwm:setup(channels, frequency)
  checks('table', 'string', '?number')
  frequency = frequency or 15000
  local chnmask = 0
  for i=1,#channels do
    local id = tonumber(string.sub(channels, i, i))
    if not self.VALID_IDS[id] then error('invalid PWM channel id: '..id.. ' at position: '..i) end
    chnmask = chnmask + 2^(id-1)
  end
  self.channels = channels
  local freq_mHz = math.floor(frequency * 1000 + .5)
  local reply = checkerr(self.sepack:setup(self, string.char(chnmask)..B.enc32BE(freq_mHz)))
  local actual_freq = B.dec32BE(reply) / 1000
  local resolution = 1/B.dec16BE(reply, 5)
  return actual_freq, resolution
end

function CT.pwm:on_connect()
  CT._default.on_connect(self)
  if self.channels then
    self:setup(self.channels)
  end
end

CT.pwm.__tostring = CT._default.__tostring



return Sepack
