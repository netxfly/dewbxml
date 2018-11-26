-- ensure the lua2go lib is on the LUA_PATH so it will load
-- normally, you'd just put it on the LUA_PATH
package.path = package.path .. ';../lua/?.lua'

-- load lua2go
local lua2go = require('lua2go')

-- load my Go library
local example = lua2go.Load('/data/code/golang/src/dewbxml/wbxml.so')

-- copy just the extern functions from benchmark.h into ffi.cdef structure below
-- (the boilerplate cgo prologue is already defined for you in lua2go)
-- this registers your Go functions to the ffi library..
lua2go.Externs[[
    extern char* parse(GoString data);
]]

local filename = "/data/code/golang/src/dewbxml/file.bin"
local file = io.open(filename,"rb")
local data = file:read("*a")
local goResult = example.parse(lua2go.ToGo(data))

local Result = lua2go.ToLua(goResult)

print('Result: ' .. Result)
