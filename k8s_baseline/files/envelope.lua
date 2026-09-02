-- envelope.lua -- Fluent Bit Lua filter for the kck8s cluster log pipeline.
--
-- Rendered by Terraform templatefile() from main.tf; the ONLY template
-- variable is ${cluster_name}. Everything else is plain Lua 5.1 (Fluent Bit
-- embeds LuaJIT), so keep it free of 5.2+ syntax (goto, //, integer ops).
--
-- Job: turn every container log record (tail + cri parser + kubernetes
-- filter) into exactly one of the two Logstash envelopes from DESIGN.md §0
-- and stamp `flb_route` so the rewrite_tag filter that follows retags it
-- nginx.* or syslog.* for the matching tcp output.
--
-- `flb_route` never reaches Logstash: the nginx branch is rebuilt by the
-- parser filter (Reserve_Data Off drops everything but the decoded access
-- line) and the syslog branch has it removed by a modify filter.
--
-- The JSON decode of the access line is deliberately NOT done here: Fluent
-- Bit's embedded Lua ships no JSON library, and the parser filter's json
-- parser is both faster and battle-tested. This function only decides
-- which branch a record belongs to and builds the syslog envelope.

local CLUSTER_NAME = "${cluster_name}"
local NGINX_NAMESPACE = "ingress-nginx"

-- The ingress-nginx log-format-upstream in main.tf ends with this literal.
-- Anything from the ingress-nginx namespace that does not carry it (controller
-- stderr, admission webhook, nginx error log) is an ordinary syslog record.
local NGINX_ACCESS_MARK = '"nginx_access": true'

local function as_string(v)
  if type(v) == "string" then
    return v
  end
  if v == nil then
    return ""
  end
  return tostring(v)
end

local function is_nginx_access(log)
  return log:sub(1, 1) == "{"
    and log:sub(-1) == "}"
    and log:find(NGINX_ACCESS_MARK, 1, true) ~= nil
end

-- RFC 3339, UTC, millisecond precision. The record timestamp is the one the
-- cri parser took from the container runtime line, so this is the moment the
-- process wrote the line, not the moment Fluent Bit read it. Handles both the
-- time_as_table form ({sec=, nsec=}) and the plain double form.
local function rfc3339(timestamp)
  local sec, nsec
  if type(timestamp) == "table" then
    sec = timestamp.sec or 0
    nsec = timestamp.nsec or 0
  else
    sec = math.floor(timestamp)
    nsec = math.floor((timestamp - sec) * 1e9 + 0.5)
  end
  return string.format("%s.%03dZ", os.date("!%Y-%m-%dT%H:%M:%S", sec), math.floor(nsec / 1e6))
end

function build_envelope(tag, timestamp, record)
  local k = record["kubernetes"]
  if type(k) ~= "table" then
    k = {}
  end
  local ns, pod, container = k["namespace_name"], k["pod_name"], k["container_name"]
  if ns == nil or pod == nil or container == nil then
    -- kubernetes filter could not enrich (API hiccup, pod already gone). The
    -- tail tag still carries the identity:
    --   kube.var.log.containers.<pod>_<namespace>_<container>-<containerid>.log
    -- Pod and namespace names cannot contain "_", so the split is unambiguous.
    local p, n, c = tag:match("^kube%.var%.log%.containers%.(.-)_(.-)_(.-)%-%x+%.log$")
    ns = ns or n or "unknown"
    pod = pod or p or "unknown"
    container = container or c or "unknown"
  end

  local log = record["log"]
  if type(log) ~= "string" then
    log = as_string(record["message"])
  end

  if ns == NGINX_NAMESPACE and is_nginx_access(log) then
    -- Access line already carries every §0 key including "shipper"; hand it to
    -- the nginx.* parser filter untouched. Nothing else survives on purpose.
    return 2, timestamp, { log = log, flb_route = "nginx" }
  end

  local severity = "info"
  if record["stream"] == "stderr" then
    severity = "err"
  end

  return 2, timestamp, {
    timestamp   = rfc3339(timestamp),
    host        = CLUSTER_NAME,
    facility    = "local0",
    severity    = severity,
    programname = ns .. "/" .. container,
    procid      = "-",
    message     = "[" .. pod .. "] " .. log,
    stream      = "syslog",
    flb_route   = "syslog",
  }
end
