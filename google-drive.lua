dofile("table_show.lua")
dofile("urlcode.lua")
dofile("strict.lua")
local urlparse = require("socket.url")
local luasocket = require("socket") -- Used to get sub-second time
local http = require("socket.http")
JSON = assert(loadfile "JSON.lua")()

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

local GDRIVE_KEY = "AIzaSyC1qbk75NzWBvSaDh6KnsjjA9pIrP4lYIE"

local num_api_reqs_not_yet_fufilled = 0
local req_callbacks = {} -- Table from URLS of requests to callbacks on those requests

-- For binary file downloads
-- All integrity-checking
local num_downloads_remaining = 0 -- How many final downloads are expected
local expected_download_size = -1 -- File size in bytes of download
local download_chain = {} -- URLs in redirect chains to downloads


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
    
    assert(num_api_reqs_not_yet_fufilled == 0) -- Project-specific
    assert(num_downloads_remaining == 0) -- Project-specific - if this fails but all looks well, maybe you're on an octet-stream DL and both downloads go to the same ultimate loc?
    
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
  local protocol_and_domain_and_port = string.match(url, "^([a-zA-Z0-9]+://[^/]+)$")
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

-- Virtually everything in this project is done by pushing API calls directly to urls in download_child_p
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
  
  if string.match(url, "^https?://drive%.google%.com/[^_%?]") then
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
    return html
  end
  
  -- This function takes a table of requests (specifically, GET URLs), puts them together into the multipart format,
  -- and then queues that multipart to urls.
  -- Currently having more than 1 request is not done anyway, imitating the Google Drive web client.
  local function queue_multipart(requests)
    local post_body = ""
    
    -- Construct the boundry
    local boundry = "====="
    -- Add 12 random letters or numbers
    for _ = 0, 11, 1 do
      local newchar
      if math.random() > 10 / 36 then
        newchar = string.char(math.random(97, 122))
      else
        newchar = string.char(math.random(48, 57))
      end
      boundry = boundry .. newchar
    end
    boundry = boundry .. "====="
    
    for _, req in pairs(requests) do
      if post_body ~= "" then -- CRLF omitted on first part
        post_body = post_body .. "\r\n--" .. boundry
      else
        post_body = post_body .. "--" .. boundry
      end
      post_body = post_body .. "\r\n" .. req
    end
    
    post_body = post_body .. "\r\n--" .. boundry .. "--"
    
    table.insert(urls, {url="https://clients6.google.com/batch/drive/v2beta?" .. "%24ct=" .. urlparse.escape("multipart/mixed; boundary=\"" .. boundry .. "\"") .. "&key=" .. urlparse.escape(GDRIVE_KEY),
                        post_data=post_body,
                        headers={["Content-Type"]="text/plain; charset=UTF-8"}}) -- This is not what RFC 1341 wants, but it is what the web client does
  end
  
  -- The main function for queuing API requests. Give it a clients6.google.com URL (only the path part) as well as a callback function, and it
  -- will both queue the URL independently and as a 1-part multipart request (practical fetchability and hypothetical
  -- POST-capable WBM compatibility, respectively). callback will be called when the independent URL is fetched.
  -- Search req_callbacks[url] for the arguments the callback is given.
  local function queue_api_call_including_to_singular_multipart(req, callback)
    assert(string.match(req, "^/drive/v2beta/"), "You must use only the path part of the URL as req")
    local full_url = "https://clients6.google.com" .. req
    
    table.insert(urls, {url=full_url, headers={Referer="https://drive.google.com/folders/" .. current_item_value}})
    queue_multipart({"content-type: application/http\r\ncontent-transfer-encoding: binary\r\n\r\nGET ".. req .. " HTTP/1.1\r\nX-Goog-Drive-Client-Version: drive.web-frontend_20210812.00_p2\r\n"})
    
    req_callbacks[full_url] = callback
    num_api_reqs_not_yet_fufilled = num_api_reqs_not_yet_fufilled + 1
    print_debug("Now expect a callback on " .. full_url)
  end
  
  if req_callbacks[url] ~= nil and status_code == 200 then
    print_debug("Callback exists")
    req_callbacks[url](queue_api_call_including_to_singular_multipart, queue_multipart, check, urls, load_html)
    num_api_reqs_not_yet_fufilled = num_api_reqs_not_yet_fufilled - 1
  end
  
  
  if current_item_type == "folder" then
    -- Initial page
    if string.match(url, "^https?://drive%.google%.com/drive/folders/[0-9A-Za-z_%-]+/?$") and status_code == 200 then
      
      check("https://drive.google.com/folder/d/" .. current_item_value)
      check("https://drive.google.com/file/d/" .. current_item_value) -- It considers folders files, good for consistency
      
      local function folder_list_callback(queue_api_call_including_to_singular_multipart, _, _, _, load_html)
        local html = load_html()
        print_debug("This is the FLC")
        local json = JSON:decode(html)
        for _, child in pairs(json["items"]) do
          assert(child["kind"] == "drive#file", "Strange item: " .. JSON:encode(child)) -- Not using table.show because people might not realize that it's more than 1 line of error
          if child["mimeType"] == "application/vnd.google-apps.folder" then
            discover_item("folder", child["id"])
          else
            discover_item("file", child["id"])
          end
        end
        
        if json["nextPageToken"] then
          print_debug("Have NPT; it is " .. json["nextPageToken"])
          -- This is identical to the "Normal list request" except for the addition of the pageToken param
          queue_api_call_including_to_singular_multipart("/drive/v2beta/files?openDrive=false&reason=102&syncType=0&errorRecovery=false&q=trashed%20%3D%20false%20and%20'" .. current_item_value .. "'%20in%20parents&fields=kind%2CnextPageToken%2Citems(kind%2CmodifiedDate%2CmodifiedByMeDate%2ClastViewedByMeDate%2CfileSize%2Cowners(kind%2CpermissionId%2Cid)%2ClastModifyingUser(kind%2CpermissionId%2Cid)%2ChasThumbnail%2CthumbnailVersion%2Ctitle%2Cid%2CresourceKey%2Cshared%2CsharedWithMeDate%2CuserPermission(role)%2CexplicitlyTrashed%2CmimeType%2CquotaBytesUsed%2Ccopyable%2CfileExtension%2CsharingUser(kind%2CpermissionId%2Cid)%2Cspaces%2Cversion%2CteamDriveId%2ChasAugmentedPermissions%2CcreatedDate%2CtrashingUser(kind%2CpermissionId%2Cid)%2CtrashedDate%2Cparents(id)%2CshortcutDetails(targetId%2CtargetMimeType%2CtargetLookupStatus)%2Ccapabilities(canCopy%2CcanDownload%2CcanEdit%2CcanAddChildren%2CcanDelete%2CcanRemoveChildren%2CcanShare%2CcanTrash%2CcanRename%2CcanReadTeamDrive%2CcanMoveTeamDriveItem)%2Clabels(starred%2Ctrashed%2Crestricted%2Cviewed))%2CincompleteSearch&appDataFilter=NO_APP_DATA&spaces=drive&pageToken=" .. json["nextPageToken"] .. "&maxResults=50&supportsTeamDrives=true&includeItemsFromAllDrives=true&corpora=default&orderBy=folder%2Ctitle_natural%20asc&retryCount=0&key=" .. GDRIVE_KEY, folder_list_callback)
        end
      end
      
      
      -- Normal list request
      queue_api_call_including_to_singular_multipart("/drive/v2beta/files?openDrive=false&reason=102&syncType=0&errorRecovery=false&q=trashed%20%3D%20false%20and%20'" .. current_item_value .. "'%20in%20parents&fields=kind%2CnextPageToken%2Citems(kind%2CmodifiedDate%2CmodifiedByMeDate%2ClastViewedByMeDate%2CfileSize%2Cowners(kind%2CpermissionId%2Cid)%2ClastModifyingUser(kind%2CpermissionId%2Cid)%2ChasThumbnail%2CthumbnailVersion%2Ctitle%2Cid%2CresourceKey%2Cshared%2CsharedWithMeDate%2CuserPermission(role)%2CexplicitlyTrashed%2CmimeType%2CquotaBytesUsed%2Ccopyable%2CfileExtension%2CsharingUser(kind%2CpermissionId%2Cid)%2Cspaces%2Cversion%2CteamDriveId%2ChasAugmentedPermissions%2CcreatedDate%2CtrashingUser(kind%2CpermissionId%2Cid)%2CtrashedDate%2Cparents(id)%2CshortcutDetails(targetId%2CtargetMimeType%2CtargetLookupStatus)%2Ccapabilities(canCopy%2CcanDownload%2CcanEdit%2CcanAddChildren%2CcanDelete%2CcanRemoveChildren%2CcanShare%2CcanTrash%2CcanRename%2CcanReadTeamDrive%2CcanMoveTeamDriveItem)%2Clabels(starred%2Ctrashed%2Crestricted%2Cviewed))%2CincompleteSearch&appDataFilter=NO_APP_DATA&spaces=drive&maxResults=50&supportsTeamDrives=true&includeItemsFromAllDrives=true&corpora=default&orderBy=folder%2Ctitle_natural%20asc&retryCount=0&key=" .. GDRIVE_KEY, folder_list_callback)
      
      -- Not currently used
      local function print_debug_callback(_, _, _, _, load_html)
        print_debug("print_debug_callback")
        print_debug(load_html())
      end
      
      local function folder_info_callback(_, _, check, _, load_html)
        print_debug("Folder info callback called")
        local json = JSON:decode(load_html())
        if json["parents"] then
          for _, v in pairs(json["parents"]) do
            discover_item("folder", v["id"])
          end
        end
        
        if json["resourceKey"] then
          check("https://drive.google.com/drive/folders/" .. current_item_value .. "?resourcekey=" .. json["resourceKey"])
        end
        
        if json["owners"] then
          for _, v in pairs(json["owners"]) do
            discover_item("user", v["id"])
          end
        end
        
        if json["lastModifyingUser"] then
          discover_item("user", json["lastModifyingUser"]["id"])
        end
      end
      
      -- One of the info requests
      queue_api_call_including_to_singular_multipart("/drive/v2beta/files/" .. current_item_value .. "?openDrive=false&reason=310&syncType=0&errorRecovery=false&fields=kind%2CmodifiedDate%2CmodifiedByMeDate%2ClastViewedByMeDate%2CfileSize%2Cowners(kind%2CpermissionId%2Cid)%2ClastModifyingUser(kind%2CpermissionId%2Cid)%2ChasThumbnail%2CthumbnailVersion%2Ctitle%2Cid%2CresourceKey%2Cshared%2CsharedWithMeDate%2CuserPermission(role)%2CexplicitlyTrashed%2CmimeType%2CquotaBytesUsed%2Ccopyable%2CfileExtension%2CsharingUser(kind%2CpermissionId%2Cid)%2Cspaces%2Cversion%2CteamDriveId%2ChasAugmentedPermissions%2CcreatedDate%2CtrashingUser(kind%2CpermissionId%2Cid)%2CtrashedDate%2Cparents(id)%2CshortcutDetails(targetId%2CtargetMimeType%2CtargetLookupStatus)%2Ccapabilities(canCopy%2CcanDownload%2CcanEdit%2CcanAddChildren%2CcanDelete%2CcanRemoveChildren%2CcanShare%2CcanTrash%2CcanRename%2CcanReadTeamDrive%2CcanMoveTeamDriveItem)%2Clabels(starred%2Ctrashed%2Crestricted%2Cviewed)&supportsTeamDrives=true&retryCount=0&key=" .. GDRIVE_KEY, folder_info_callback)
      
      -- Other info request
      queue_api_call_including_to_singular_multipart("/drive/v2beta/files/" .. current_item_value .. "?openDrive=true&reason=1001&syncType=0&errorRecovery=false&fields=kind%2CmodifiedDate%2CmodifiedByMeDate%2ClastViewedByMeDate%2CfileSize%2Cowners(kind%2CpermissionId%2Cid)%2ClastModifyingUser(kind%2CpermissionId%2Cid)%2ChasThumbnail%2CthumbnailVersion%2Ctitle%2Cid%2CresourceKey%2Cshared%2CsharedWithMeDate%2CuserPermission(role)%2CexplicitlyTrashed%2CmimeType%2CquotaBytesUsed%2Ccopyable%2CfileExtension%2CsharingUser(kind%2CpermissionId%2Cid)%2Cspaces%2Cversion%2CteamDriveId%2ChasAugmentedPermissions%2CcreatedDate%2CtrashingUser(kind%2CpermissionId%2Cid)%2CtrashedDate%2Cparents(id)%2CshortcutDetails(targetId%2CtargetMimeType%2CtargetLookupStatus)%2Ccapabilities(canCopy%2CcanDownload%2CcanEdit%2CcanAddChildren%2CcanDelete%2CcanRemoveChildren%2CcanShare%2CcanTrash%2CcanRename%2CcanReadTeamDrive%2CcanMoveTeamDriveItem)%2Clabels(starred%2Ctrashed%2Crestricted%2Cviewed)&supportsTeamDrives=true&retryCount=0&key=" .. GDRIVE_KEY, folder_info_callback)
      
      -- Another info request, somethimes gets called when a child of the current folder is being viewed
      queue_api_call_including_to_singular_multipart("/drive/v2beta/files/" .. current_item_value .. "?openDrive=false&reason=1001&syncType=0&errorRecovery=false&fields=kind%2CmodifiedDate%2CmodifiedByMeDate%2ClastViewedByMeDate%2CfileSize%2Cowners(kind%2CpermissionId%2Cid)%2ClastModifyingUser(kind%2CpermissionId%2Cid)%2ChasThumbnail%2CthumbnailVersion%2Ctitle%2Cid%2CresourceKey%2Cshared%2CsharedWithMeDate%2CuserPermission(role)%2CexplicitlyTrashed%2CmimeType%2CquotaBytesUsed%2Ccopyable%2CfileExtension%2CsharingUser(kind%2CpermissionId%2Cid)%2Cspaces%2Cversion%2CteamDriveId%2ChasAugmentedPermissions%2CcreatedDate%2CtrashingUser(kind%2CpermissionId%2Cid)%2CtrashedDate%2Cparents(id)%2CshortcutDetails(targetId%2CtargetMimeType%2CtargetLookupStatus)%2Ccapabilities(canCopy%2CcanDownload%2CcanEdit%2CcanAddChildren%2CcanDelete%2CcanRemoveChildren%2CcanShare%2CcanTrash%2CcanRename%2CcanReadTeamDrive%2CcanMoveTeamDriveItem)%2Clabels(starred%2Ctrashed%2Crestricted%2Cviewed)&supportsTeamDrives=true&retryCount=0&key=" .. GDRIVE_KEY, folder_info_callback)
      
    end
  end
  
  if current_item_type == "file" then
    
    -- Start URL
    if string.match(url, "^https?://drive%.google%.com/file/d/.*/view$") then
      check("https://drive.google.com/file/d/" .. current_item_value .. "/edit")
      
      -- Downloads
      check("https://drive.google.com/uc?id=" .. current_item_value)
      check("https://drive.google.com/uc?id=" .. current_item_value .. "&export=download")
      num_downloads_remaining = num_downloads_remaining + 2
      download_chain["https://drive.google.com/uc?id=" .. current_item_value] = true
      download_chain["https://drive.google.com/uc?id=" .. current_item_value .. "&export=download"] = true
      
      local function file_info_callback(_, _, _, _, load_html)
        print_debug("This is file_info_callback")
        local json = JSON:decode(load_html())
        
        -- TODO abort based on mimetype
        -- If it has fileSize, it is directly downloadable
        if json["fileSize"] ~= nil then
          expected_download_size = tonumber(json["fileSize"])
        else
          assert(false, "Not implemented yet")
        end
      end
      
      -- Fields fixed by using the specification the folders use
      local good_info_req_url = "https://content.googleapis.com/drive/v2beta/files/" .. current_item_value .. "?fields=kind%2CmodifiedDate%2CmodifiedByMeDate%2ClastViewedByMeDate%2CfileSize%2Cowners(kind%2CpermissionId%2Cid)%2ClastModifyingUser(kind%2CpermissionId%2Cid)%2ChasThumbnail%2CthumbnailVersion%2Ctitle%2Cid%2CresourceKey%2Cshared%2CsharedWithMeDate%2CuserPermission(role)%2CexplicitlyTrashed%2CmimeType%2CquotaBytesUsed%2Ccopyable%2CfileExtension%2CsharingUser(kind%2CpermissionId%2Cid)%2Cspaces%2Cversion%2CteamDriveId%2ChasAugmentedPermissions%2CcreatedDate%2CtrashingUser(kind%2CpermissionId%2Cid)%2CtrashedDate%2Cparents(id)%2CshortcutDetails(targetId%2CtargetMimeType%2CtargetLookupStatus)%2Ccapabilities(canCopy%2CcanDownload%2CcanEdit%2CcanAddChildren%2CcanDelete%2CcanRemoveChildren%2CcanShare%2CcanTrash%2CcanRename%2CcanReadTeamDrive%2CcanMoveTeamDriveItem)%2Clabels(starred%2Ctrashed%2Crestricted%2Cviewed)&supportsTeamDrives=true&includeBadgedLabels=true&enforceSingleParent=true&key=" .. GDRIVE_KEY
      table.insert(urls, {url=good_info_req_url, headers={Referer="https://drive.google.com/folders/" .. current_item_value}})
      -- Manually doing the callback stuff
      req_callbacks[good_info_req_url] = file_info_callback
      num_api_reqs_not_yet_fufilled = num_api_reqs_not_yet_fufilled + 1
      
    end
  end
  
  -- Multiparts - basic check
  if string.match(url, "^https?://clients6%.google%.com/batch/drive/v2beta") and status_code == 200 then
    assert(string.match(load_html(), "200 OK"))
  end
  
  

  if status_code == 200 and not (string.match(url, "%.jpe?g$") or string.match(url, "%.png$")) then
    -- Completely disabled because I can't be bothered
    --[[load_html()
    
    for newurl in string.gmatch(string.gsub(html, "&quot;", '"'), '([^"]+)') do
      checknewurl(newurl)
    end
    for newurl in string.gmatch(string.gsub(html, "&#039;", "'"), "([^']+)") do
      checknewurl(newurl)
    end
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
    end]]
  end

  return urls
end

wget.callbacks.httploop_result = function(url, err, http_stat)
  status_code = http_stat["statcode"]

  url_count = url_count + 1
  io.stdout:write(url_count .. "=" .. status_code .. " " .. url["url"] .. "  \n")
  io.stdout:flush()


  if status_code >= 200 and status_code <= 399 then
    downloaded[url["url"]] = true
  end

  if abortgrab == true then
    io.stdout:write("ABORTING...\n")
    io.stdout:flush()
    return wget.actions.ABORT
  end
  
  -- If file is in download chain
  if current_item_type == "file" and download_chain[url["url"]] then
    if status_code >= 300 and status_code <= 399 then
        -- If it's a redirect, follow
        local newloc = urlparse.absolute(url["url"], http_stat["newloc"])
        if downloaded[newloc] == true or addedtolist[newloc] == true then
          print_debug("Exiting because " .. newloc .. " is already downloaded or addedtolist")
          return wget.actions.EXIT
        else
          addedtolist[newloc] = true
          download_chain[newloc] = true
          return wget.actions.NOTHING
      end
    elseif status_code == 200 then
      -- Do not bother checking the start URLs
      if not string.match(url["url"], "^https://drive%.google%.com/uc%?") then
        --assert(http_stat["len"] == http_stat["rd_size"] and http_stat["rd_size"] == http_stat["contlen"], tostring(http_stat["len"]) .. " " .. tostring(http_stat["rd_size"]) .. " " .. tostring(http_stat["contlen"]))
        assert(http_stat["len"] == http_stat["rd_size"]) -- contlen is -1 in final DL
        -- TODO maybe change this pending reply from arkiver
        if http_stat["len"] == expected_download_size then
          num_downloads_remaining = num_downloads_remaining - 1
        end
      end
    end
  end
  
  local do_retry = false
  local maxtries = 12
  local url_is_essential = true

  -- Whitelist instead of blacklist status codes
  local is_valid_404 = string.match(url["url"], "^https?://drive%.google%.com/drive/folders/[0-9A-Za-z_%-]+/?$") -- Start URL of folders
  local is_valid_302 = current_item_type == "folder" and
      (string.match(url["url"], "^https?://drive%.google%.com/file/d/[0-9A-Za-z_%-]+/?$") or string.match(url["url"], "^https?://drive%.google%.com/folder/d/[0-9A-Za-z_%-]+/?$"))
  if status_code ~= 200
    and not (status_code == 404 and is_valid_404)
    and not (status_code == 302 and is_valid_302) then
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

