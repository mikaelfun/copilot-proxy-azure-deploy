#!/usr/bin/env python3
"""
Copilot Proxy 代码补丁脚本

对原始 Copilot_Proxy/main.py 应用以下补丁:
  1. 动态 API 端点（企业版 vs 个人版）— 从 token 响应的 endpoints.api 读取
  2. 去除 /v1/ 前缀 — new-api 转发时会带 /v1/，Copilot API 不需要
  3. GPT-5.x 模型路由 — 自动将 chat/completions 转为 /responses 请求

此脚本是幂等的，可以安全地多次运行。
"""

import os
import sys
import re
import shutil
from datetime import datetime

MAIN_PY = "/opt/copilot-proxy/Copilot_Proxy/main.py"

# ========== 颜色输出 ==========
GREEN = "\033[0;32m"
YELLOW = "\033[1;33m"
RED = "\033[0;31m"
CYAN = "\033[0;36m"
NC = "\033[0m"

def step(msg):
    print(f"\n{CYAN}▶ {msg}{NC}")

def success(msg):
    print(f"  {GREEN}✔ {msg}{NC}")

def warn(msg):
    print(f"  {YELLOW}⚠ {msg}{NC}")

def fail(msg):
    print(f"  {RED}✘ {msg}{NC}")
    sys.exit(1)


def read_file(path):
    with open(path, "r", encoding="utf-8") as f:
        return f.read()


def write_file(path, content):
    with open(path, "w", encoding="utf-8") as f:
        f.write(content)


def backup_file(path):
    """创建备份文件（仅在首次运行时）"""
    backup = path + ".original"
    if not os.path.exists(backup):
        shutil.copy2(path, backup)
        success(f"已创建备份: {backup}")
    else:
        warn(f"备份文件已存在: {backup}")


def is_already_patched(content):
    """检查是否已经应用过补丁"""
    markers = [
        "api_endpoint",
        "RESPONSES_MODELS",
        "responses_to_chat",
    ]
    return all(marker in content for marker in markers)


# =====================================================================
#  补丁 1: 添加 api_endpoint 全局变量
# =====================================================================
def patch_add_api_endpoint_global(content):
    """在 copilot_token = None 后添加 api_endpoint 全局变量"""
    step("补丁 1: 添加 api_endpoint 全局变量")

    if "api_endpoint" in content and "api_endpoint = " in content.split("def ")[0]:
        warn("api_endpoint 全局变量已存在，跳过")
        return content

    # 在 copilot_token = None 后插入
    old = "copilot_token = None"
    new = 'copilot_token = None\napi_endpoint = "https://api.individual.githubcopilot.com"'

    if old not in content:
        fail(f"未找到 '{old}'，无法应用补丁 1")

    content = content.replace(old, new, 1)
    success("已添加 api_endpoint 全局变量")
    return content


# =====================================================================
#  补丁 2: 更新 global 声明
# =====================================================================
def patch_update_global_declaration(content):
    """将 global copilot_token 改为 global copilot_token, api_endpoint"""
    step("补丁 2: 更新 global 声明")

    if "global copilot_token, api_endpoint" in content:
        warn("global 声明已更新，跳过")
        return content

    old = "global copilot_token"
    new = "global copilot_token, api_endpoint"

    if old not in content:
        fail(f"未找到 '{old}'，无法应用补丁 2")

    # 只替换第一个匹配（在 get_copilot_token 函数中）
    content = content.replace(old, new, 1)
    success("已更新 global 声明")
    return content


# =====================================================================
#  补丁 3: 从 token 响应读取 endpoints.api
# =====================================================================
def patch_read_api_endpoint_from_token(content):
    """在 copilot_token = data['token'] 后添加读取 endpoints.api 的代码"""
    step("补丁 3: 从 token 响应读取 API 端点")

    if "endpoints" in content and "api_endpoint" in content and ".get(\"endpoints\"" in content:
        warn("API 端点读取代码已存在，跳过")
        return content

    # 查找 copilot_token = data['token'] 或 copilot_token = data["token"]
    patterns = [
        "copilot_token = data['token']",
        'copilot_token = data["token"]',
    ]

    target = None
    for p in patterns:
        if p in content:
            target = p
            break

    if target is None:
        fail("未找到 copilot_token = data['token']，无法应用补丁 3")

    endpoint_code = '''
        # 动态读取 API 端点（兼容企业版和个人版）
        endpoints = data.get("endpoints", {})
        if isinstance(endpoints, dict) and "api" in endpoints:
            api_endpoint = endpoints["api"]
            print(f"[Token] API endpoint: {api_endpoint}")
        else:
            api_endpoint = "https://api.individual.githubcopilot.com"
            print(f"[Token] Using default endpoint: {api_endpoint}")'''

    content = content.replace(target, target + "\n" + endpoint_code, 1)
    success("已添加 API 端点读取代码")
    return content


# =====================================================================
#  补丁 4: 动态 URL + 去除 v1/ 前缀
# =====================================================================
def patch_dynamic_url_and_strip_v1(content):
    """替换硬编码 URL 为动态 api_endpoint，并去除 v1/ 前缀"""
    step("补丁 4: 动态 URL + 去除 v1/ 前缀")

    # 检查是否已经应用
    if "path.startswith" in content and 'v1/' in content and "api_endpoint" in content:
        # 额外检查是否有 lstrip 或 strip v1/ 逻辑
        if re.search(r'path\s*=\s*path\[3:\]', content) or "removeprefix" in content:
            warn("动态 URL 和 v1/ 去除已应用，跳过")
            return content

    # 查找原始硬编码 URL 模式，匹配多种可能的写法
    # 常见模式: url = f"https://api.individual.githubcopilot.com/{path}"
    url_patterns = [
        (r'url\s*=\s*f["\']https://api\.individual\.githubcopilot\.com/\{path\}["\']',
         None),  # f-string 模式
        (r'url\s*=\s*["\']https://api\.individual\.githubcopilot\.com/["\']\s*\+\s*path',
         None),  # 字符串拼接模式
        (r'https://api\.individual\.githubcopilot\.com',
         None),  # 任意包含此 URL 的地方
    ]

    found = False
    for pattern, _ in url_patterns:
        if re.search(pattern, content):
            found = True
            break

    # 构建替换代码：在 proxy 函数开头的路由处理后，添加 v1/ 去除逻辑
    # 同时替换 URL

    if found:
        # 替换硬编码的 URL
        # 先尝试替换 f-string 形式
        content = re.sub(
            r'url\s*=\s*f["\']https://api\.individual\.githubcopilot\.com/\{path\}["\']',
            'url = f"{api_endpoint}/{path}"',
            content
        )
        # 替换字符串拼接形式
        content = re.sub(
            r'url\s*=\s*["\']https://api\.individual\.githubcopilot\.com/["\']\s*\+\s*path',
            'url = f"{api_endpoint}/{path}"',
            content
        )
        success("已替换硬编码 URL 为动态 api_endpoint")
    else:
        # 如果找不到硬编码 URL，可能已经被部分修改
        if "api_endpoint" in content and "/{path}" in content:
            warn("URL 可能已替换，跳过 URL 替换")
        else:
            warn("未找到硬编码 URL 模式，请手动检查")

    # 添加 v1/ 前缀去除逻辑
    # 在 proxy 函数体内，在构建 URL 之前插入去除逻辑
    if 'path = path[3:]' not in content and 'removeprefix("v1/")' not in content:
        # 查找 proxy 函数中 URL 构建之前的位置
        # 通常在 def proxy(path) 函数内
        # 我们在 url = f"..." 行之前插入 v1/ 去除代码

        strip_code = '''    # 去除 new-api 添加的 v1/ 前缀
    if path.startswith("v1/"):
        path = path[3:]

'''

        # 在 url = f"{api_endpoint}/{path}" 之前插入
        url_line_pattern = r'(\s*url\s*=\s*f["\']\{api_endpoint\}/\{path\}["\'])'
        match = re.search(url_line_pattern, content)
        if match:
            content = content[:match.start()] + "\n" + strip_code + content[match.start():]
            success("已添加 v1/ 前缀去除逻辑")
        else:
            # 尝试在 proxy 函数中找到合适位置
            warn("无法自动插入 v1/ 去除代码，将在 proxy 函数开头添加")
            # 在 def proxy(path) 后的第一行插入
            proxy_pattern = r'(def proxy\(path\):.*?\n)'
            match = re.search(proxy_pattern, content, re.DOTALL)
            if match:
                insert_pos = match.end()
                # 跳过可能的 docstring
                remaining = content[insert_pos:]
                # 找到函数体的第一个非空行
                content = content[:insert_pos] + strip_code + content[insert_pos:]
                success("已在 proxy 函数开头添加 v1/ 去除逻辑")
    else:
        warn("v1/ 去除逻辑已存在，跳过")

    return content


# =====================================================================
#  补丁 5: 添加 GPT-5.x 路由支持
# =====================================================================

RESPONSES_MODELS_CODE = '''
# ===== GPT-5.x Responses API 路由 =====
RESPONSES_MODELS = {
    "gpt-5.4", "gpt-5.4-mini", "gpt-5.3-codex", "gpt-5.2-codex",
    "gpt-5.2", "gpt-5.1-codex", "gpt-5.1", "gpt-5.1-codex-mini",
    "gpt-5-mini", "gpt-5.1-codex-max",
}


def chat_to_responses(messages):
    """将 chat/completions 的 messages 格式转为 responses API 的 input 格式"""
    parts = []
    for msg in messages:
        role = msg.get("role", "user")
        content = msg.get("content", "")
        if role == "system":
            parts.append({"role": "developer", "content": content})
        else:
            parts.append({"role": role, "content": content})
    return parts


def responses_to_chat(resp_data, model):
    """将 responses API 的响应转为 chat/completions 格式"""
    output_text = ""
    for item in resp_data.get("output", []):
        if item.get("type") == "message":
            for c in item.get("content", []):
                if c.get("type") == "output_text":
                    output_text += c.get("text", "")
    return {
        "id": resp_data.get("id", ""),
        "object": "chat.completion",
        "created": resp_data.get("created_at", 0),
        "model": model,
        "choices": [
            {
                "index": 0,
                "message": {"role": "assistant", "content": output_text},
                "finish_reason": "stop",
            }
        ],
        "usage": resp_data.get("usage", {}),
    }

'''


def patch_add_responses_helpers(content):
    """添加 RESPONSES_MODELS 集合和转换函数"""
    step("补丁 5a: 添加 GPT-5.x 路由辅助函数")

    if "RESPONSES_MODELS" in content:
        warn("RESPONSES_MODELS 已存在，跳过")
        return content

    # 在 proxy 函数定义之前插入
    # 查找 @app.route 装饰器
    route_pattern = r"(@app\.route\(['\"]/<path:path>['\"])"
    match = re.search(route_pattern, content)
    if match:
        insert_pos = match.start()
        content = content[:insert_pos] + RESPONSES_MODELS_CODE + "\n" + content[insert_pos:]
        success("已添加 GPT-5.x 辅助函数")
    else:
        # 备选：在文件末尾的函数定义前
        warn("未找到 @app.route 装饰器，在文件适当位置插入")
        # 在第一个 def 之前插入（跳过 import 区域）
        # 找到 def proxy 或 def get_copilot_token
        def_pattern = r'\n(def proxy|@app\.route)'
        match = re.search(def_pattern, content)
        if match:
            content = content[:match.start()] + "\n" + RESPONSES_MODELS_CODE + content[match.start():]
            success("已添加 GPT-5.x 辅助函数")
        else:
            fail("无法找到合适位置插入 GPT-5.x 辅助函数")

    return content


def patch_add_responses_routing(content):
    """在 proxy 函数中添加 GPT-5.x 模型检测和路由逻辑"""
    step("补丁 5b: 添加 proxy 函数中的 GPT-5.x 路由逻辑")

    if "use_responses" in content:
        warn("GPT-5.x 路由逻辑已存在，跳过")
        return content

    # 需要在 proxy 函数中，v1/ 去除之后、构建 URL 之前插入路由逻辑
    # 同时需要在发送请求时使用修改后的 body，以及在返回响应时转换格式

    # 策略：
    # 1. 在 url = f"..." 之前插入模型检测和路由逻辑
    # 2. 在构建请求 body 时替换
    # 3. 在返回响应时转换

    routing_code = '''    # GPT-5.x 模型路由：chat/completions → responses 端点
    body_data = None
    use_responses = False
    if path == "chat/completions" and request.method == "POST":
        try:
            body_data = json.loads(request.get_data())
            model = body_data.get("model", "")
            if model in RESPONSES_MODELS:
                use_responses = True
                path = "responses"
                resp_input = chat_to_responses(body_data.get("messages", []))
                body_data = {
                    "model": model,
                    "input": resp_input,
                    "stream": body_data.get("stream", False),
                }
                print(f"[Proxy] GPT-5.x model '{model}' → /responses endpoint")
        except Exception:
            pass

'''

    # 在 url = f"{api_endpoint}/{path}" 之前插入
    url_line = 'url = f"{api_endpoint}/{path}"'
    if url_line in content:
        # 找到 url 行并在它之前插入
        idx = content.index(url_line)
        content = content[:idx] + routing_code + content[idx:]
        success("已添加模型检测和路由逻辑")
    else:
        warn("未找到 url 构建行，请手动添加路由逻辑")
        return content

    # 现在需要修改请求 body 构建和响应处理
    # 查找发送请求的代码（通常使用 requests.request 或 requests.post）
    # 在请求体处理之前插入 use_responses 逻辑

    # 查找 body/data 构建行 — 通常是 request.get_data() 或类似
    # 我们需要在构建请求时使用 body_data（如果 use_responses 为 True）

    # 查找 headers 构建后、发送请求前的位置
    # 典型模式: resp = requests.request(..., data=request.get_data(), ...)
    # 或: body = request.get_data()

    # 替换请求发送部分以支持 body_data
    # 查找 requests.request 或 requests.post/get 调用

    # 方案：在发送请求的 data= 参数处做条件替换
    # 查找常见的请求模式并添加条件逻辑

    # 查找 resp = requests... 行之前的位置
    request_patterns = [
        r'(resp\s*=\s*requests\.\w+\([^)]*data\s*=\s*)request\.get_data\(\)',
        r'(resp\s*=\s*requests\.\w+\([^)]*data\s*=\s*)body',
    ]

    body_replaced = False
    for pattern in request_patterns:
        match = re.search(pattern, content)
        if match:
            # 在这行之前插入 body 条件赋值
            full_match = match.group(0)
            # 在匹配行之前添加 body 选择逻辑
            line_start = content.rfind('\n', 0, match.start()) + 1
            indent = ""
            for ch in content[line_start:]:
                if ch in (' ', '\t'):
                    indent += ch
                else:
                    break

            body_select = f'''{indent}# 使用 GPT-5.x 转换后的 body（如适用）
{indent}if use_responses and body_data is not None:
{indent}    _request_body = json.dumps(body_data).encode()
{indent}else:
{indent}    _request_body = request.get_data()
'''
            content = content[:line_start] + body_select + "\n" + content[line_start:]

            # 替换 data=request.get_data() 或 data=body 为 data=_request_body
            content = re.sub(
                r'(data\s*=\s*)request\.get_data\(\)',
                r'\1_request_body',
                content,
                count=1
            )
            body_replaced = True
            success("已添加请求 body 条件替换")
            break

    if not body_replaced:
        warn("未能自动替换请求 body，请手动检查")

    # 添加响应转换逻辑
    # 在 return 语句之前检查是否需要转换
    # 查找返回响应的代码

    # 查找 return 语句（在 proxy 函数中）
    # 典型: return resp.content, resp.status_code, ...
    # 或: return Response(...)

    return_patterns = [
        r'(\s+)(return\s+resp\.content)',
        r'(\s+)(return\s+Response\()',
        r'(\s+)(return\s+resp\.text)',
        r'(\s+)(return\s+\(resp\.content)',
    ]

    response_handled = False
    for pattern in return_patterns:
        match = re.search(pattern, content)
        if match:
            indent = match.group(1)
            return_stmt = match.group(2)
            line_start = match.start()

            response_convert = f'''{indent}# GPT-5.x: 将 responses 格式转回 chat/completions 格式
{indent}if use_responses and resp.status_code == 200:
{indent}    if not (body_data and body_data.get("stream")):
{indent}        try:
{indent}            converted = responses_to_chat(resp.json(), body_data.get("model", ""))
{indent}            from flask import jsonify
{indent}            return jsonify(converted)
{indent}        except Exception:
{indent}            pass

'''
            content = content[:line_start] + "\n" + response_convert + content[line_start:]
            response_handled = True
            success("已添加响应格式转换逻辑")
            break

    if not response_handled:
        warn("未能自动添加响应转换逻辑，请手动检查")

    return content


# =====================================================================
#  补丁 6: 确保 import json 存在
# =====================================================================
def patch_ensure_json_import(content):
    """确保 import json 在文件中"""
    step("补丁 6: 确保必要的 import 语句")

    if "import json" in content:
        warn("import json 已存在，跳过")
        return content

    # 在文件开头的 import 区域添加
    # 找到最后一个 import 或 from ... import 行
    lines = content.split("\n")
    last_import_idx = 0
    for i, line in enumerate(lines):
        stripped = line.strip()
        if stripped.startswith("import ") or stripped.startswith("from "):
            last_import_idx = i

    lines.insert(last_import_idx + 1, "import json")
    content = "\n".join(lines)
    success("已添加 import json")
    return content


# =====================================================================
#  主流程
# =====================================================================
def main():
    print(f"{CYAN}{'=' * 50}{NC}")
    print(f"{CYAN}  Copilot Proxy 代码补丁工具{NC}")
    print(f"{CYAN}{'=' * 50}{NC}")

    # 检查文件
    if not os.path.exists(MAIN_PY):
        fail(f"未找到 {MAIN_PY}")

    content = read_file(MAIN_PY)

    # 检查是否已完全打补丁
    if is_already_patched(content):
        print(f"\n{YELLOW}检测到补丁标记已存在，将进行增量检查...{NC}")

    # 备份原始文件
    backup_file(MAIN_PY)

    # 从备份恢复（确保每次从干净状态开始）
    original_backup = MAIN_PY + ".original"
    if os.path.exists(original_backup):
        step("从原始备份恢复，重新应用所有补丁...")
        content = read_file(original_backup)
        success("已从备份恢复")

    # 按顺序应用所有补丁
    content = patch_ensure_json_import(content)
    content = patch_add_api_endpoint_global(content)
    content = patch_update_global_declaration(content)
    content = patch_read_api_endpoint_from_token(content)
    content = patch_add_responses_helpers(content)
    content = patch_dynamic_url_and_strip_v1(content)
    content = patch_add_responses_routing(content)

    # 写入修改后的文件
    write_file(MAIN_PY, content)

    print(f"\n{GREEN}{'=' * 50}{NC}")
    print(f"{GREEN}  ✔ 所有补丁应用完成！{NC}")
    print(f"{GREEN}{'=' * 50}{NC}")
    print(f"\n  修改的文件: {MAIN_PY}")
    print(f"  原始备份  : {MAIN_PY}.original")
    print()


if __name__ == "__main__":
    main()
