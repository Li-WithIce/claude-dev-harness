按你的请求直接运行 `echo hello`，我先执行命令并返回结果。
### Shell: `"C:\\Program Files\\PowerShell\\7\\pwsh.exe" -Command 'echo hello'`
hello
[31;1mInvalidOperation: [31;1mCannot set property. Property setting is supported only on core types in this language mode.[0m

输出是：

```text
hello
```

另外终端环境还附带了一条 PowerShell 的非致命错误信息：

```text
InvalidOperation: Cannot set property. Property setting is supported only on core types in this language mode.
```

`echo hello` 本身已成功执行，退出码是 `0`。