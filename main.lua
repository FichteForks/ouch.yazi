--- @since 25.12.29

local M = {}

-- Extract the tree prefix (if any) from a line
local function get_tree_prefix(line)
  local _, prefix_len = line:find("─ ", 1, true)
  if prefix_len then
    return line:sub(1, prefix_len)
  else
    return ""
  end
end

-- Add a filetype icon to a line
local function line_with_icon(line)
  line = line:gsub("[\r\n]+$", "") -- Trailing newlines mess with filetype detection

  local tree_prefix = get_tree_prefix(line)
  local url_str = line:sub(#tree_prefix + 1)
  local url = Url(url_str)
  local name = url.name
  local is_dir = url_str:sub(-1) == "/"
  local file = File({
    url = url,
    name = name,
    cha = Cha {
      mode = tonumber(is_dir and "40700" or "100644", 8),
    }
  })
  local icon = th.icon:match(file)
  local icon_span = icon and ui.Span(icon.text .. " "):style(icon.style) or ""
  local name_span = ui.Span(name)--.style(file:style()) -- TODO does not work
  return ui.Line { tree_prefix, icon_span, name_span }
end

function M:peek(job)
  local cmd = Command("ouch"):arg("l")
  if not job.args.list_view then
    cmd:arg("-t")
  end
  if job.args.format then
    cmd:arg({"-f", job.args.format})
  end
  cmd:arg({ "-y", tostring(job.file.url) })

  local child = cmd
    :stdout(Command.PIPED)
    :stderr(Command.PIPED)
    :spawn()

  local limit = job.area.h
  local num_skip = 0
  local lines = {}

  if job.args.show_file_icons then
      table.insert(lines, ui.Line({line_with_icon(job.file.name)}))
    else
      table.insert(lines, ui.Line({job.file.name}))
  end

  repeat
    local line, event = child:read_line()
    if event == 2 or line == nil then
      break
    end
    if event == 1 then
      -- line is from stderr
      local is_err_line = line:find ('[ERROR]', 1, true) == 1
      if is_err_line then
        ya.err("ouch error:", line)
        -- Disable file icons for the rest of the output.
        job.args.show_file_icons = false
      end
      -- Include line verbatim (with padding) and continue.
      table.insert(lines, ui.Line(line))
      goto next_line
    end

    if line:find('Archive:', 1, true) then
      goto next_line
    end

    if num_skip < job.skip then
      num_skip = num_skip + 1
      goto next_line
    end

    if job.args.show_file_icons then
      table.insert(lines, ui.Line({line_with_icon(line)}))
    else
      table.insert(lines, ui.Line(line))
    end
    ::next_line::
  until #lines >= limit

  child:start_kill()
  if job.skip > 0 and #lines < limit then
    ya.emit(
      "peek",
      { tostring(math.max(0, job.skip - (limit - #lines))), only_if = tostring(job.file.url), upper_bound = "" }
    )
  else
    ya.preview_widget(job, { ui.Text(lines):area(job.area) })
  end
end

function M:seek(job)
  local h = cx.active.current.hovered
  if h and h.url == job.file.url then
    local step = math.floor(job.units * job.area.h / 10)
    ya.emit("peek", {
      math.max(0, cx.active.preview.skip + step),
      only_if = tostring(job.file.url),
    })
  end
end

-- Check if file exists
local function file_exists(name)
  local f = io.open(name, "r")
  if f ~= nil then
    io.close(f)
    return true
  else
    return false
  end
end

-- Get the files that need to be compressed and infer a default archive name
local get_compression_target = ya.sync(function()
  local tab = cx.active
  local default_name
  local paths = {}
  if #tab.selected == 0 then
    if tab.current.hovered then
      local name = tab.current.hovered.name
      default_name = name
      table.insert(paths, name)
    else
      return
    end
  else
    default_name = tab.current.cwd.name
    for _, file in pairs(tab.selected) do
      table.insert(paths, tostring(file.url))
    end
    -- The compression targets are aquired, now unselect them
    ya.emit("escape", {})
  end
  return paths, default_name
end)

local function invoke_compress_command(paths, name)
  if name:sub(1, 1) == "-" then
    name = "./" .. name
  end

  local cmd_output, err_code = Command("ouch")
      :arg({ "c", "-y", "--" })
      :arg(paths)
      :arg(name)
      :stderr(Command.PIPED)
      :output()
  if err_code ~= nil then
    ya.notify({
      title = "Failed to run ouch command",
      content = "Status: " .. err_code,
      timeout = 5.0,
      level = "error",
    })
  elseif not cmd_output.status.success then
    ya.notify({
      title = "Compression failed: status code " .. cmd_output.status.code,
      content = cmd_output.stderr,
      timeout = 5.0,
      level = "error",
    })
  end
end

function M:entry(job)
  local default_fmt = job.args[1]
  if default_fmt == nil then
    default_fmt = "zip"
  end

  ya.emit("escape", { visual = true })

  -- Get the files that need to be compressed and infer a default archive name
  local paths, default_name = get_compression_target()

  -- Get archive name from user
  local output_name, name_event = ya.input({
    title = "Create archive:",
    value = default_name .. "." .. default_fmt,
    pos = { "top-center", y = 3, w = 40 },
  })
  if name_event ~= 1 then
    return
  end

  -- Get confirmation if file exists
  if file_exists(output_name) then
    local confirm, confirm_event = ya.input({
      title = "Overwrite " .. output_name .. "? (y/N)",
      pos = { "top-center", y = 3, w = 40 },
    })
    if not (confirm_event == 1 and confirm:lower() == "y") then
      return
    end
  end

  invoke_compress_command(paths, output_name)
end

return M
