```toml
title = "用go语言给lua写扩展"
slug = "extending-lua-with-go-language"
desc = "extending-lua-with-go-language"
date = "2018-11-27 00:14:21"
update_date = "2018-11-27 00:14:21"
author = ""
thumb = ""
draft = false
tags = ["tag"]
```

## 背景
最近的一个lua项目中需要解析wbxml，WBXML是XML的二进制表示形式，Exchange与手机端之间的通讯采用的就是该协议，我需要解析到手机端提交过来的数据，以提高用户体验。
但是lua没有现成的Wbxml解析库，从头撸一个势必要花费大量造轮子的时间，在网上查找了半天，发现有一个go语言版本的[https://github.com/magicmonty/activesync-go](https://github.com/magicmonty/activesync-go)，写了几行测试代码，确认该库可以正常解析出Exchange的wbxml数据内容，如下所示：
![](http://docs.xsec.io/images/wbxml/001.png)


## 微服务 VS lua 扩展

最初的方案打算用golang实现一个微服务，供openresty调用，该方案的特点是方便，能快速实现，但缺点也是非常明显的：
- 性能损耗大：openresty每接收到一个请求都需要调用golang的restful api，然后等待golang把wbxml解析完并返回，这中间有非常大的性能损耗
- 增加运维成本：golang微服务奔溃后，openresty将无法拿到想到的信息了，在运维时，除了要关注openresty本身外，还要时刻关注golang微服务的业务连续性、性能等指标

最佳的方案是提供一个lua的扩展，无缝集成到openresty中，这样可以完美地规避掉上述2个缺点。

## 用GO语言扩展lua

### 编写规范
关于用go语言扩展lua，github中已有现成的辅助库[https://github.com/theganyo/lua2go](https://github.com/theganyo/lua2go)可以使用，它的工作流程如下：

1. 编写go模块，并导出需要给lua使用的函数：
```golang 
//export add
func add(operand1 int, operand2 int) int {
    return operand1 + operand2
}
```
1. 将go模块编译为静态库：
```golang
go build -buildmode=c-shared -o example.so example.go
```
1. 编写lua文件，加载自己的.so文件：
```lua
local lua2go = require('lua2go')
local example = lua2go.Load('./example.so')
```
1. 在lua文件与头文件模块中注册导出的函数：
```lua
lua2go.Externs[[
  extern GoInt add(GoInt p0, GoInt p1);
]]
```
1. 在lua文件中调用导出的函数并将结果转化为lua格式的数据：
```lua 
local goAddResult = example.add(1, 1)
local addResult = lua2go.ToLua(goAddResult)
print('1 + 1 = ' .. addResult)
```

详细情况可以参考该项目的[example](https://github.com/theganyo/lua2go/tree/master/example)

### 编写自己的的wbxml解析库

`getDecodeResult`函数可以将wbxml的二进制数据直接解析成xml格式的string
```golang
func getDecodeResult(data ...byte) string {
	var result string
	result, _ = Decode(bytes.NewBuffer(data), MakeCodeBook(PROTOCOL_VERSION_14_1))
	return result
}
```

但解析出来的xml的格式如下，多层嵌套且用了命名空间，虽然能看到明文的xml了，但是还是不能直接取到我们想要的数据
```xml
<?xml version="1.0" encoding="utf-8"?>
<O:Provision xmlns:O="Provision" xmlns:S="Settings">
    <S:DeviceInformation>
        <S:Set>
            <S:Model>MIX 2</S:Model>
            <S:IMEI>888833336669999</S:IMEI>
            <S:FriendlyName>MIX 2</S:FriendlyName>
            <S:OS>Android 8.0.0</S:OS>
            <S:PhoneNumber>+8618599999999</S:PhoneNumber>
            <S:UserAgent>Android/8.0.0-EAS-1.3</S:UserAgent>
            <S:MobileOperator>中国联通 (46001)</S:MobileOperator>
        </S:Set>
    </S:DeviceInformation>
    <O:Policies>
        <O:Policy>
            <O:PolicyType>MS-EAS-Provisioning-WBXML</O:PolicyType>
        </O:Policy>
    </O:Policies>
</O:Provision>
```

我们需要再对xml进行一次解析，解析到对应的struct中，就可以方便地获取想要的数据了，但是这个xml格式比较复杂，笔者试着手工定义了几次都失败了，干脆找了个自动化工具自动生成了，自动化工具的地址为[https://github.com/miku/zek](https://github.com/miku/zek)。

作者还提供了个Web版的在线工具，使用起来非常方便，地址为：[https://www.onlinetool.io/xmltogo/](https://www.onlinetool.io/xmltogo/)

最后生成的Struct如下：
```golang
type Provision struct {
	XMLName           xml.Name `xml:"Provision"`
	Text              string   `xml:",chardata"`
	O                 string   `xml:"O,attr"`
	S                 string   `xml:"S,attr"`
	DeviceInformation struct {
		Text string `xml:",chardata"`
		Set  struct {
			Text           string `xml:",chardata"`
			Model          string `xml:"Model"`
			IMEI           string `xml:"IMEI"`
			FriendlyName   string `xml:"FriendlyName"`
			OS             string `xml:"OS"`
			PhoneNumber    string `xml:"PhoneNumber"`
			UserAgent      string `xml:"UserAgent"`
			MobileOperator string `xml:"MobileOperator"`
		} `xml:"Set"`
	} `xml:"DeviceInformation"`
	Policies struct {
		Text   string `xml:",chardata"`
		Policy struct {
			Text       string `xml:",chardata"`
			PolicyType string `xml:"PolicyType"`
		} `xml:"Policy"`
	} `xml:"Policies"`
}

```

最终我们自己导出的处理wbxml的函数如下（将需要关注的信息放到一个用`||`分割的字符串中返回）:

```golang
//export parse
func parse(data []byte) (*C.char) {
	result := make([]string, 0)
	xmldata := getDecodeResult(data...)
	fmt.Println(xmldata)

	out := Provision{}
	xml.Unmarshal([]byte(xmldata), &out)

	//fmt.Printf("Model: %v\n", out.DeviceInformation.Set.Model)
	//fmt.Printf("Imie: %v\n", out.DeviceInformation.Set.IMEI)
	//fmt.Printf("FriendlyName: %v\n", out.DeviceInformation.Set.FriendlyName)
	//fmt.Printf("PhoneNumber: %v\n", out.DeviceInformation.Set.PhoneNumber)
	//fmt.Printf("MobileOperator: %v\n", out.DeviceInformation.Set.MobileOperator)

	result = append(result, out.DeviceInformation.Set.Model)
	result = append(result, out.DeviceInformation.Set.IMEI)
	result = append(result, out.DeviceInformation.Set.FriendlyName)
	result = append(result, out.DeviceInformation.Set.PhoneNumber)
	result = append(result, out.DeviceInformation.Set.MobileOperator)

	return C.CString(strings.Join(result, "||"))
}
```

接下来分别在`wbxml.h`和`xbxml/lua`中导出这个函数，如下所示：

`wbxml.h`的内容：
```c
#ifndef GO_CGO_PROLOGUE_H
#define GO_CGO_PROLOGUE_H

typedef signed char GoInt8;
typedef unsigned char GoUint8;
typedef short GoInt16;
typedef unsigned short GoUint16;
typedef int GoInt32;
typedef unsigned int GoUint32;
typedef long long GoInt64;
typedef unsigned long long GoUint64;
typedef GoInt64 GoInt;
typedef GoUint64 GoUint;
typedef __SIZE_TYPE__ GoUintptr;
typedef float GoFloat32;
typedef double GoFloat64;
typedef float _Complex GoComplex64;
typedef double _Complex GoComplex128;

/*
  static assertion to make sure the file is being used on architecture
  at least with matching size of GoInt.
*/
typedef char _check_for_64_bit_pointer_matching_GoInt[sizeof(void*)==64/8 ? 1:-1];

typedef struct { const char *p; GoInt n; } GoString;
typedef void *GoMap;
typedef void *GoChan;
typedef struct { void *t; void *v; } GoInterface;
typedef struct { void *data; GoInt len; GoInt cap; } GoSlice;

#endif

/* End of boilerplate cgo prologue.  */

#ifdef __cplusplus
extern "C" {
#endif

extern char* parse(GoString data);

#ifdef __cplusplus
}
#endif
```

`wbxml`的内容：

```lua
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
```
最终的结果如下图所示：
![](http://docs.xsec.io/images/wbxml/002.png)