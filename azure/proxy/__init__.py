# Azure Functions Custom Handler placeholder.
# 所有 HTTP 请求通过 host.json 的 customHandler 配置直接转发到 hubproxy 二进制文件。
# 此文件仅为 Azure Functions 运行时要求，实际逻辑由 Go 程序处理。
