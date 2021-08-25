dofile("table_show.lua")
dofile("urlcode.lua")
dofile("strict.lua")
local urlparse = require("socket.url")
local luasocket = require("socket") -- Used to get sub-second time
local http = require("socket.http")
JSON = assert(loadfile "JSON.lua")()

local item_name_newline = os.getenv("item_name_newline")
local start_urls = JSON:decode(os.getenv("start_urls"))
local items_table = JSON:decode(os.getenv("item_names_table"))
local item_dir = os.getenv("item_dir")
local warc_file_base = os.getenv("warc_file_base")

local url_count = 0
local tries = 0
local downloaded = {}
local addedtolist = {}
local abortgrab = false


discovered_items = {}
local last_main_site_time = 0
local current_item_type = nil
local current_item_value = nil
local next_start_url_index = 1

dofile("fe.lua")


io.stdout:setvbuf("no") -- So prints are not buffered - http://lua.2524044.n2.nabble.com/print-stdout-and-flush-td6406981.html

if urlparse == nil or http == nil then
  io.stdout:write("socket not corrently installed.\n")
  io.stdout:flush()
  abortgrab = true
end

do_debug = true
print_debug = function(a)
  if do_debug then
    print(a)
  end
end
print_debug("This grab script is running in debug mode. You should not see this in production.")

local start_urls_inverted = {}
for _, v in pairs(start_urls) do
  start_urls_inverted[v] = true
end

set_new_item = function(url)
  if url == start_urls[next_start_url_index] then
    current_item_type = items_table[next_start_url_index][1]
    current_item_value = items_table[next_start_url_index][2]
    next_start_url_index = next_start_url_index + 1
    print_debug("Setting CIT to " .. current_item_type)
    print_debug("Setting CIV to " .. current_item_value)
  end
  assert(current_item_type)
  assert(current_item_value)
end

discover_item = function(item_type, item_name)
  assert(item_type)
  assert(item_name)
    
  if not discovered_items[item_type .. ":" .. item_name] then
    print_debug("Queuing for discovery " .. item_type .. ":" .. item_name)
  end
  discovered_items[item_type .. ":" .. item_name] = true
end

add_ignore = function(url)
  if url == nil then -- For recursion
    return
  end
  if downloaded[url] ~= true then
    downloaded[url] = true
  else
    return
  end
  add_ignore(string.gsub(url, "^https", "http", 1))
  add_ignore(string.gsub(url, "^http:", "https:", 1))
  add_ignore(string.match(url, "^ +([^ ]+)"))
  local protocol_and_domain_and_port = string.match(url, "^([a-zA-Z0-9]+://[^/]+)")
  if protocol_and_domain_and_port then
    add_ignore(protocol_and_domain_and_port .. "/")
  end
  add_ignore(string.match(url, "^(.+)/$"))
end

for ignore in io.open("ignore-list", "r"):lines() do
  add_ignore(ignore)
end

read_file = function(file)
  if file then
    local f = assert(io.open(file))
    local data = f:read("*all")
    f:close()
    return data
  else
    return ""
  end
end

allowed = function(url, parenturl)
  assert(parenturl ~= nil)

  if start_urls_inverted[url] then
    return false
  end
  
  local tested = {}
  for s in string.gmatch(url, "([^/]+)") do
    if tested[s] == nil then
      tested[s] = 0
    end
    if tested[s] == 6 then
      return false
    end
    tested[s] = tested[s] + 1
  end
  
  if string.match(url, "^https?://wordplay%.com/static/")
    or string.match(url, "^https?://wordplay%.com/fonts/") then
    return false
  end
  
  if string.match(url, "^https?://[^/]+%.wordplay%.com/")
    or string.match(url, "^https?://wordplay%.com/")
    or string.match(url, "^https?://d1ezai0lfl2usn%.cloudfront%.net/") -- Images on lessons
    or string.match(url, "^https?://d33ata18hf0t57%.cloudfront%.net/") then -- Audio on lessons
    return true
  end
  
  return false

  --return false


  --assert(false, "This segment should not be reachable")
end


wget.callbacks.download_child_p = function(urlpos, parent, depth, start_url_parsed, iri, verdict, reason)
  local url = urlpos["url"]["url"]
  --print_debug("DCP on " .. url)
  if downloaded[url] == true or addedtolist[url] == true then
    return false
  end
  if allowed(url, parent["url"]) then
    addedtolist[url] = true
    --set_derived_url(url)
    return true
  end

  return false
end

wget.callbacks.get_urls = function(file, url, is_css, iri)
  local urls = {}
  local html = nil

  downloaded[url] = true

  local function check(urla, force)
    assert(not force or force == true) -- Don't accidentally put something else for force
    local origurl = url
    local url = string.match(urla, "^([^#]+)")
    local url_ = string.match(url, "^(.-)%.?$")
    url_ = string.gsub(url_, "&amp;", "&")
    url_ = string.match(url_, "^(.-)%s*$")
    url_ = string.match(url_, "^(.-)%??$")
    url_ = string.match(url_, "^(.-)&?$")
    -- url_ = string.match(url_, "^(.-)/?$") # Breaks dl.
    if (downloaded[url_] ~= true and addedtolist[url_] ~= true)
      and (allowed(url_, origurl) or force) then
      table.insert(urls, { url=url_ })
      --set_derived_url(url_)
      addedtolist[url_] = true
      addedtolist[url] = true
    end
  end

  local function checknewurl(newurl)
    -- Being caused to fail by a recursive call on "../"
    if not newurl then
      return
    end
    if string.match(newurl, "\\[uU]002[fF]") then
      return checknewurl(string.gsub(newurl, "\\[uU]002[fF]", "/"))
    end
    if string.match(newurl, "^https?:////") then
      check((string.gsub(newurl, ":////", "://")))
    elseif string.match(newurl, "^https?://") then
      check(newurl)
    elseif string.match(newurl, "^https?:\\/\\?/") then
      check((string.gsub(newurl, "\\", "")))
    elseif string.match(newurl, "^\\/") then
      checknewurl(string.gsub(newurl, "\\", ""))
    elseif string.match(newurl, "^//") then
      check(urlparse.absolute(url, newurl))
    elseif string.match(newurl, "^/") then
      check(urlparse.absolute(url, newurl))
    elseif string.match(newurl, "^%.%./") then
      if string.match(url, "^https?://[^/]+/[^/]+/") then
        check(urlparse.absolute(url, newurl))
      else
        checknewurl(string.match(newurl, "^%.%.(/.+)$"))
      end
    elseif string.match(newurl, "^%./") then
      check(urlparse.absolute(url, newurl))
    end
  end

  local function checknewshorturl(newurl)
    if string.match(newurl, "^%?") then
      check(urlparse.absolute(url, newurl))
    elseif not (string.match(newurl, "^https?:\\?/\\?//?/?")
      or string.match(newurl, "^[/\\]")
      or string.match(newurl, "^%./")
      or string.match(newurl, "^[jJ]ava[sS]cript:")
      or string.match(newurl, "^[mM]ail[tT]o:")
      or string.match(newurl, "^vine:")
      or string.match(newurl, "^android%-app:")
      or string.match(newurl, "^ios%-app:")
      or string.match(newurl, "^%${")) then
      check(urlparse.absolute(url, "/" .. newurl))
    end
  end

  local function load_html()
    if html == nil then
      html = read_file(file)
    end
  end
  
  
  -- Same functionality as Pe in main.js
  -- Some of the weirdness of the original duplicated
  -- <thuban> (weird way to implement that)
  local function Pe(e)
    e = string.gsub(e, "[%z\1-\127\194-\244][\128-\191]*", Fe) -- Due to Lua being 8-bit clean this is done differently from the original. See https://stackoverflow.com/questions/22954073/lua-gmatch-odd-characters-slovak-alphabet#22954220 . Regex for 5.1 from https://stackoverflow.com/questions/24190608/lua-string-byte-for-non-ascii-characters#24196142
    e = string.lower(e)
    e = string.gsub(e, " *%([^)]*%) *", "") -- Original is a poor regex decision, but I am duplicating it anyway
    e = string.gsub(e, "[^A-Za-z]", "")
    return e
  end

  assert(Pe("(el) café") == "cafe")

  local function ze(e)
    local prefix = ""
    if string.match(e, "^%(el%)") or string.match(e, "^%(el/la%)") then
      prefix = "el"
    elseif string.match(e, "^%(los%)") or string.match(e, "^%(los/las%)") then
      prefix = "los"
    elseif string.match(e, "^%(la%)") then
      prefix = "la"
    elseif string.match(e, "^%(las%)") then
      prefix = "las"
    end
    return prefix .. Pe(e)
  end


  assert(ze("(la) casa") == "lacasa")
  
  
  
  local lesson = string.match(url, "^https://wordplay%.com/lesson/(.+)$")
  if lesson then
    assert(lesson == current_item_value)
    check("https://api3.wordplay.com/lessons/" .. lesson)
  end
  
  local lesson = string.match(url, "^https://api3%.wordplay%.com/lessons/(.+)$")
  if lesson and status_code == 200 then
    assert(lesson == current_item_value)
    load_html()
    local json = JSON:decode(html)["response"]
    discover_item("course", json["courseID"])
    for _, v in pairs(json["tiles"]) do
      -- Queue audio
      if v["targetVoiceover"] ~= nil and v["targetVoiceover"] ~= "" then
        check("https://d33ata18hf0t57.cloudfront.net/" .. v["targetVoiceover"])
      else
        check("https://d33ata18hf0t57.cloudfront.net/" .. ze(v["targetText"]) .. ".mp3")
      end
      
      -- Audio 2
      if v["nativeVoiceover"] ~= nil and v["nativeVoiceover"] ~= "" then
        check("https://d33ata18hf0t57.cloudfront.net/" .. v["nativeVoiceover"])
      end
      
      --print(table.show(v))
      -- Thumbnail
      if v["image"] ~= nil and v["image"] ~= "" then
        check("https://d1ezai0lfl2usn.cloudfront.net/" .. v["image"])
      else
        check("https://d1ezai0lfl2usn.cloudfront.net/" .. Pe(v["nativeText"]) .. ".jpg")
      end
      
    end
  end
  
  
  local course = string.match(url, "^https://wordplay%.com/course/(.+)$")
  if course then
    assert(course == current_item_value)
    check("https://api3.wordplay.com/courses/" .. course)
  end
  
  local course = string.match(url, "^https://api3%.wordplay%.com/courses/(.+)$")
  if course and status_code == 200 then
    assert(course == current_item_value)
    load_html()
    local json = JSON:decode(html)["response"]
    for _, v in pairs(json["lessons"]) do
      discover_item("lesson", v["lessonID"])
    end
  end
  
  

  if status_code == 200 and not (string.match(url, "%.jpe?g$") or string.match(url, "%.png$"))
    and not string.match(url, "^https?://[^/]%.cloudfront%.net/") then
    load_html()
    
    -- These two were extracting a lot of junk
    --[[for newurl in string.gmatch(string.gsub(html, "&quot;", '"'), '([^"]+)') do
      checknewurl(newurl)
    end
    for newurl in string.gmatch(string.gsub(html, "&#039;", "'"), "([^']+)") do
      checknewurl(newurl)
    end]]
    for newurl in string.gmatch(html, ">%s*([^<%s]+)") do
      checknewurl(newurl)
    end
    for newurl in string.gmatch(html, "[^%-]href='([^']+)'") do
      checknewshorturl(newurl)
    end
    for newurl in string.gmatch(html, '[^%-]href="([^"]+)"') do
      checknewshorturl(newurl)
    end
    for newurl in string.gmatch(html, ":%s*url%(([^%)]+)%)") do
      checknewurl(newurl)
    end
  end

  return urls
end

wget.callbacks.httploop_result = function(url, err, http_stat)
  status_code = http_stat["statcode"]

  url_count = url_count + 1
  io.stdout:write(url_count .. "=" .. status_code .. " " .. url["url"] .. "  \n")
  io.stdout:flush()


  if status_code >= 300 and status_code <= 399 then
    local newloc = urlparse.absolute(url["url"], http_stat["newloc"])
    if downloaded[newloc] == true or addedtolist[newloc] == true
      or not allowed(newloc, url["url"]) then
      tries = 0
      return wget.actions.EXIT
    end
  end

  if status_code >= 200 and status_code <= 399 then
    downloaded[url["url"]] = true
  end

  if abortgrab == true then
    io.stdout:write("ABORTING...\n")
    io.stdout:flush()
    return wget.actions.ABORT
  end
  
  local do_retry = false
  local maxtries = 12
  local url_is_essential = true

  -- Whitelist instead of blacklist status codes
  local is_valid_400 = string.match(url["url"], "^https://api3%.wordplay%.com/lessons/")
  local is_valid_403 = string.match(url["url"], "^https?://d1ezai0lfl2usn%.cloudfront%.net/")
    or string.match(url["url"], "^https?://d33ata18hf0t57%.cloudfront%.net/")
  if status_code ~= 200
    and not (status_code == 400 and is_valid_400)
    and not (status_code == 403 and is_valid_403)
    and not (status_code >= 300 and status_code <= 399) then
    print("Server returned " .. http_stat.statcode .. " (" .. err .. "). Sleeping.\n")
    do_retry = true
  end


  if do_retry then
    if tries >= maxtries then
      print("I give up...\n")
      tries = 0
      if not url_is_essential then
        return wget.actions.EXIT
      else
        print("Failed on an essential URL, aborting...")
        return wget.actions.ABORT
      end
    else
      sleep_time = math.floor(math.pow(2, tries))
      tries = tries + 1
    end
  end


  if do_retry and sleep_time > 0.001 then
    print("Sleeping " .. sleep_time .. "s")
    os.execute("sleep " .. sleep_time)
    return wget.actions.CONTINUE
  end

  tries = 0
  return wget.actions.NOTHING
end


queue_list_to = function(list, key)
  if do_debug then
    for item, _ in pairs(list) do
      print("Would have sent discovered item " .. item)
    end
  else
    local to_send = nil
    for item, _ in pairs(list) do
      assert(string.match(item, ":")) -- Message from EggplantN, #binnedtray (search "colon"?)
      if to_send == nil then
        to_send = item
      else
        to_send = to_send .. "\0" .. item
      end
      print("Queued " .. item)
    end

    if to_send ~= nil then
      local tries = 0
      while tries < 10 do
        local body, code, headers, status = http.request(
          "http://blackbird-amqp.meo.ws:23038/" .. key .. "/",
          to_send
        )
        if code == 200 or code == 409 then
          break
        end
        os.execute("sleep " .. math.floor(math.pow(2, tries)))
        tries = tries + 1
      end
      if tries == 10 then
        abortgrab = true
      end
    end
  end
end


wget.callbacks.finish = function(start_time, end_time, wall_time, numurls, total_downloaded_bytes, total_download_time)
  queue_list_to(discovered_items, "fill_me_in")
end

wget.callbacks.write_to_warc = function(url, http_stat)
  set_new_item(url["url"])
  return true
end

wget.callbacks.before_exit = function(exit_status, exit_status_string)
  if abortgrab == true then
    return wget.exits.IO_FAIL
  end
  return exit_status
end

