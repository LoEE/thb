-- Copyright (c) 2013 Daurnimator
--           https://github.com/daurnimator/luatz/blob/eabec5f434225aa68aa33565d8cf5055f287662e/luatz/timetable.lua
-- Copyright (c) 2015 LoEE – Jakub Piotr Cłapa
--
-- Released under the MIT License

local floor = math.floor
local function idiv(n, d)
  return floor(n/d)
end

local mon_lengths = { 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 }
-- Number of days in year until start of month; not corrected for leap years
local months_to_days_cumulative = { 0 }
for i = 2, 12 do
  months_to_days_cumulative [ i ] = months_to_days_cumulative [ i-1 ] + mon_lengths [ i-1 ]
end
-- For Sakamoto's Algorithm (day of week)
local sakamoto = {0, 3, 2, 5, 0, 3, 5, 1, 4, 6, 2, 4};

local function is_leap ( y )
  if (y % 4) ~= 0 then
    return false
  elseif (y % 100) ~= 0 then
    return true
  else
    return (y % 400) == 0
  end
end

local function year_length ( y )
  return is_leap ( y ) and 366 or 365
end

local function month_length ( m , y )
  if m == 2 then
    return is_leap ( y ) and 29 or 28
  else
    return mon_lengths [ m ]
  end
end

local function leap_years_since ( year )
  return idiv ( year , 4 ) - idiv ( year , 100 ) + idiv ( year , 400 )
end

local function day_of_year ( day , month , year )
  local yday = months_to_days_cumulative [ month ]
  if month > 2 and is_leap ( year ) then
    yday = yday + 1
  end
  return yday + day
end

local function day_of_week ( day , month , year )
  if month < 3 then
    year = year - 1
  end
  return ( year + leap_years_since ( year ) + sakamoto[month] + day ) % 7 + 1
end

local function borrow ( tens , units , base )
  local frac = tens % 1
  units = units + frac * base
  tens = tens - frac
  return tens , units
end

local function carry ( tens , units , base )
  if units >= base then
    tens  = tens + idiv ( units , base )
    units = units % base
  elseif units < 0 then
    tens  = tens - 1 + idiv ( -units , base )
    units = base - ( -units % base )
  end
  return tens , units
end

-- Modify parameters so they all fit within the "normal" range
local function normalise ( year , month , day , hour , min , sec )
  -- `month` and `day` start from 1, need -1 and +1 so it works modulo
  month , day = month - 1 , day - 1

  -- Convert everything (except seconds) to an integer
  -- by propagating fractional components down.
  year  , month = borrow ( year  , month , 12 )
  -- Carry from month to year first, so we get month length correct in next line around leap years
  year  , month = carry ( year , month , 12 )
  month , day   = borrow ( month , day   , month_length ( floor ( month + 1 ) , year ) )
  day   , hour  = borrow ( day   , hour  , 24 )
  hour  , min   = borrow ( hour  , min   , 60 )
  min   , sec   = borrow ( min   , sec   , 60 )

  -- Propagate out of range values up
  -- e.g. if `min` is 70, `hour` increments by 1 and `min` becomes 10
  -- This has to happen for all columns after borrowing, as lower radixes may be pushed out of range
  min   , sec   = carry ( min   , sec   , 60 ) -- TODO: consider leap seconds?
  hour  , min   = carry ( hour  , min   , 60 )
  day   , hour  = carry ( day   , hour  , 24 )
  -- Ensure `day` is not underflowed
  -- Add a whole year of days at a time, this is later resolved by adding months
  -- TODO[OPTIMIZE]: This could be slow if `day` is far out of range
  while day < 0 do
    year = year - 1
    day  = day + year_length ( year )
  end
  year , month = carry ( year , month , 12 )

  -- TODO[OPTIMIZE]: This could potentially be slow if `day` is very large
  while true do
    local i = month_length ( month + 1 , year )
    if day < i then break end
    day = day - i
    month = month + 1
    if month >= 12 then
      month = 0
      year = year + 1
    end
  end

  -- Now we can place `day` and `month` back in their normal ranges
  -- e.g. month as 1-12 instead of 0-11
  month , day = month + 1 , day + 1

  return year , month , day , hour , min , sec
end

local leap_years_since_1970 = leap_years_since ( 1970 )
local function timestamp ( year , month , day , hour , min , sec )
  year , month , day , hour , min , sec = normalise ( year , month , day , hour , min , sec )

  local days_since_epoch = day_of_year ( day , month , year )
    + 365 * ( year - 1970 )
    -- Each leap year adds one day
    + ( leap_years_since ( year - 1 ) - leap_years_since_1970 ) - 1

  return days_since_epoch * (60*60*24)
    + hour  * (60*60)
    + min   * 60
    + sec
end

local function timegm (tm)
  return timestamp(tm.year, tm.month, tm.day, tm.hour, tm.min, tm.sec)
end

return timegm
