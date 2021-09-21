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
local num_downloads_remaining = 0 -- Num binary file downloads left
local expected_download_size = -1 -- File size in bytes of download
local download_chain = {} -- URLs in redirect chains to downloads

local file_does_not_exist = false -- Set if file_info_callback gets a 404

io.stdout:setvbuf("no") -- So prints are not buffered - http://lua.2524044.n2.nabble.com/print-stdout-and-flush-td6406981.html

if urlparse == nil or http == nil then
  io.stdout:write("socket not corrently installed.\n")
  io.stdout:flush()
  abortgrab = true
end

do_debug = false
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

-- Function to be called whenever an item's download ends.
end_of_item = function()
    assert(num_api_reqs_not_yet_fufilled == 0, table.show(req_callbacks)) -- Project-specific
    assert(num_downloads_remaining == 0)
    req_callbacks = {}
    file_does_not_exist = false
    expected_download_size = -1
    download_chain = {}
end

set_new_item = function(url)
  if url == start_urls[next_start_url_index] then
    end_of_item()
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

  if string.match(url, "^https?://drive%.google%.com/[^_%?]")
    or string.match(url, "^https?://docs%.google%.com/[^_%?]")
    or (string.match(url, "^https?://lh3%.googleusercontent%.com")
          and not string.match(parenturl, "^https?://lh3%.googleusercontent%.com")) then
    print_debug("allowing " .. url .. " from " .. parenturl)
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
        -- Set Accept-Language in order that the quota exceeded message is always in English (else it will just fail on an assert and alarm pipeline operators)
      table.insert(urls, { url=url_, headers={["Accept-Language"]="en-US,en;q=0.5"}})
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

  local function add_callback(url, callback)
    if req_callbacks[url] then
      print("WARNING: callback already exists for " .. url)
    end
    if downloaded[url] then
      print("WARNING: " .. url .. " already downloaded")
    end
    req_callbacks[url] = callback
    num_api_reqs_not_yet_fufilled = num_api_reqs_not_yet_fufilled + 1
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

    add_callback(full_url, callback)
    print_debug("Now expect a callback on " .. full_url)
  end

  if req_callbacks[url] ~= nil then
    print_debug("Callback exists")
    req_callbacks[url](queue_api_call_including_to_singular_multipart, queue_multipart, check, urls, load_html, status_code)
    num_api_reqs_not_yet_fufilled = num_api_reqs_not_yet_fufilled - 1
    req_callbacks[url] = nil
  end

  if current_item_type == "folder" then
    -- Initial page
    if string.match(url, "^https?://drive%.google%.com/drive/folders/[0-9A-Za-z_%-]+/?$") and status_code == 200 then

      check("https://drive.google.com/folder/d/" .. current_item_value)

      local function folder_list_callback(queue_api_call_including_to_singular_multipart, queue_multipart, check, urls, load_html, status_code)
        assert(status_code == 200)
        local html = load_html()
        print_debug("This is the FLC")
        local json = JSON:decode(html)
        for _, child in pairs(json["items"]) do
          assert(child["kind"] == "drive#file", "Strange item: " .. JSON:encode(child)) -- Not using table.show because people might not realize that it's more than 1 line of error
          if child["mimeType"] == "application/vnd.google-apps.folder" then
            discover_item("folder", child["id"])
          else
            -- It is a normal file
            discover_item("file", child["id"])
            
            -- Thumbnails
            if child["hasThumbnail"] then
              check("https://lh3.googleusercontent.com/u/0/d/" .. child["id"] .. "=w200-h190-p-k-nu-iv2")
              check("https://lh3.googleusercontent.com/u/0/d/" .. child["id"] .. "=w400-h380-p-k-nu-iv2")
              if child["resourceKey"] ~= nil then
                check("https://lh3.googleusercontent.com/u/0/d/" .. child["id"] .. "=w200-h190-p-k-nu-iv2?resourcekey=" .. child["resourceKey"])
                check("https://lh3.googleusercontent.com/u/0/d/" .. child["id"] .. "=w400-h380-p-k-nu-iv2?resourcekey=" .. child["resourceKey"])
              end
            end
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

      local function folder_info_callback(_, _, check, _, load_html, status_code)
        assert(status_code == 200)
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
      
      check("https://drive.google.com/folderview?id=" .. current_item_value)
    end
    
    -- Regardless of 200, except for 302 (login required)
    -- The 302 is scrutinized (and made sure that it is that kind of 302 instead of e.g. rate limiting) more heavily in download_child_p's non-DL chain redirect check structure
    if string.match(url, "^https?://drive%.google%.com/drive/folders/[0-9A-Za-z_%-]+/?$") and status_code ~= 302 then
      check("https://drive.google.com/open?id=" .. current_item_value)
    end
  end

  if current_item_type == "file" then

    -- Start URL
    -- I have discovered that for forms the /view page gets a 404; the info API request is a good indicator of whether it exists.
    -- But because that API request is very long (you can see it below) and requires some header manipulation, it's less ugly to queue everything from the API req callback
    --  than it is to make the request the start URL.
    if string.match(url, "^https?://drive%.google%.com/file/d/.*/view$") and (status_code == 200 or status_code == 404) then
      local function file_info_callback(queue_api_call_including_to_singular_multipart, queue_multipart, check, urls, load_html, status_code)
        print_debug("This is file_info_callback")
        
        -- If 404, we are done with the item
        if status_code == 404 then
          print("It appears the file does not exist, quitting.")
          file_does_not_exist = true
          return
        end
      
        -- If not, get on with the item

        -- Downloads
        local function get_downloads()
          check("https://drive.google.com/uc?id=" .. current_item_value)
          num_downloads_remaining = 2 -- Go ahead and set this for the one with &export=download as well - may end up catching a mistake that causes that never to be queued
          download_chain["https://drive.google.com/uc?id=" .. current_item_value] = true
        end

        
        local json = JSON:decode(load_html())


        if json["fileSize"] ~= nil
          and json["mimeType"] ~= "application/vnd.google-apps.document"
          and json["mimeType"] ~= "application/vnd.google-apps.spreadsheet" then
          if string.match(json["mimeType"], "^video/") then
            -- Video
            print("Only getting metadata for this video.")
          else
            -- Normal files
            get_downloads()
            expected_download_size = tonumber(json["fileSize"])
          end
        else
          print("Non-binary files are not implemented anytime")
          print("You do NOT need to report this.")
        end
        
        if json["lastModifyingUser"] ~= nil and json["lastModifyingUser"]["id"] ~= nil then
          discover_item("user", json["lastModifyingUser"]["id"])
        end

        for _, parent in pairs(json["parents"]) do
          discover_item("folder", parent["id"])
        end
      end

      -- Fields fixed by using the specification the folders use
      local good_info_req_url = "https://content.googleapis.com/drive/v2beta/files/" .. current_item_value .. "?fields=kind%2CmodifiedDate%2CmodifiedByMeDate%2ClastViewedByMeDate%2CfileSize%2Cowners(kind%2CpermissionId%2Cid)%2ClastModifyingUser(kind%2CpermissionId%2Cid)%2ChasThumbnail%2CthumbnailVersion%2Ctitle%2Cid%2CresourceKey%2Cshared%2CsharedWithMeDate%2CuserPermission(role)%2CexplicitlyTrashed%2CmimeType%2CquotaBytesUsed%2Ccopyable%2CfileExtension%2CsharingUser(kind%2CpermissionId%2Cid)%2Cspaces%2Cversion%2CteamDriveId%2ChasAugmentedPermissions%2CcreatedDate%2CtrashingUser(kind%2CpermissionId%2Cid)%2CtrashedDate%2Cparents(id)%2CshortcutDetails(targetId%2CtargetMimeType%2CtargetLookupStatus)%2Ccapabilities(canCopy%2CcanDownload%2CcanEdit%2CcanAddChildren%2CcanDelete%2CcanRemoveChildren%2CcanShare%2CcanTrash%2CcanRename%2CcanReadTeamDrive%2CcanMoveTeamDriveItem)%2Clabels(starred%2Ctrashed%2Crestricted%2Cviewed)&supportsTeamDrives=true&includeBadgedLabels=true&enforceSingleParent=true&key=" .. GDRIVE_KEY
      table.insert(urls, {url=good_info_req_url, headers={Referer="https://drive.google.com/folders/" .. current_item_value}})
      add_callback(good_info_req_url, file_info_callback)
    end

    -- Under normal circumstances these are the first in a "redirect chain" to the final download URL, and will give 3xx. They will 200 if the download needs a confirmation - usually a large file, but my test item is a small Javascript file that their virus scanner can't scan for whatever reason.
    -- It will also give a 200 if the file's quota (separate from the downloading IP address's quota, if it exists) has been exceeded - explicitly check for this, even though this causes the main part to fail anyway
    if string.match(url, "^https://drive%.google%.com/uc%?") and status_code == 200 then
      -- Check for quota exceeded
      if string.match(load_html(), " many users have viewed or downloaded this file recently") then
        print("Quota exceeded for file " .. current_item_value .. " - aborting")
        abortgrab = true
        return
      end

      -- The have-confirmed URL always has export=download, even if the parent URL doesn't
      local confirm_url = string.match(load_html(), 'href="(/uc%?export=download&amp;confirm=[a-zA-Z0-9%-_]+&amp;id=[a-zA-Z0-9%-_]+)">Download anyway')
      assert(confirm_url)
      print_debug("confirm_url raw is " .. confirm_url)
      confirm_url = confirm_url:gsub("&amp;", "&")
      local new_url = urlparse.absolute(url, confirm_url)
      check(new_url)
      download_chain[new_url] = true
    end

    -- Upon encountering the end of a good download redirect chain, queue the export=download variant (or don't queue it, if it's already been queued)
    -- This cannot run interweaved with the non-"export=download" process (without great difficulty) because they both depend on a cookie, but each sets it to a different particular value, which the next step relies on.
    -- This is a condensed version of a series of checks done in download_child_p, see there for explanations
    if current_item_type == "file" and download_chain[url] and status_code == 200 and not string.match(url, "^https://drive%.google%.com/uc%?") then
      print_debug("Adding &export=download from " .. url)
      check("https://drive.google.com/uc?id=" .. current_item_value .. "&export=download")
      download_chain["https://drive.google.com/uc?id=" .. current_item_value .. "&export=download"] = true
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

  assert(not (string.match(url["url"], "^https?://[^/]*google%.com/sorry") or string.match(url["url"], "^https?://consent%.google%.com/")))

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
          assert(download_chain[newloc])
          print_debug("Exiting because " .. newloc .. " is already downloaded or addedtolist")
          num_downloads_remaining = num_downloads_remaining - 1
          tries = 0
          assert(not (string.match(newloc, "^https?://[^/]*google%.com/sorry") or string.match(newloc, "^https?://consent%.google%.com/"))) -- Don't know what consent.google.com is, but I'm stealing from urls-grab and being cautious
          return wget.actions.EXIT
        else
          addedtolist[newloc] = true
          download_chain[newloc] = true
          tries = 0
          assert(not (string.match(newloc, "^https?://[^/]*google%.com/sorry") or string.match(newloc, "^https?://consent%.google%.com/")))
          return wget.actions.NOTHING
      end
    elseif status_code == 200 then
      -- Do not bother checking the start URLs - they will never have the final download
      if not string.match(url["url"], "^https://drive%.google%.com/uc%?") then
        assert(http_stat["len"] == http_stat["rd_size"], tostring(http_stat["len"]) .. " " .. tostring(http_stat["rd_size"]) .. " " .. tostring(expected_download_size) .. " - please notify OrIdow6 if this triggers") -- contlen is -1 in final DL
        -- TODO change this pending reply from arkiver - the above sometimes fails (which happened before the details were added)
        if http_stat["len"] == expected_download_size then
          num_downloads_remaining = num_downloads_remaining - 1
        end
      end
    end
  end

  -- Handle redirects not in download chains
  if status_code >= 300 and status_code <= 399 then
    local newloc = urlparse.absolute(url["url"], http_stat["newloc"])
    print_debug("newloc is " .. newloc)
    if downloaded[newloc] == true or addedtolist[newloc] == true then
      tries = 0
      print_debug("Already encountered newloc " .. newloc)
      assert(not (string.match(newloc, "^https?://[^/]*google%.com/sorry") or string.match(newloc, "^https?://consent%.google%.com/")))
      assert(not string.match(url["url"], "^https?://drive%.google%.com/file/d/.*/view$")) -- If this is a redirect, it will mess up initialization of file: items
      assert(not string.match(url["url"], "^https?://drive%.google%.com/drive/folders/[0-9A-Za-z_%-]+/?$")) -- Likewise for folder:

      tries = 0
      return wget.actions.EXIT
    -- Folders that are private but have somehow ended up in the item list
    elseif (current_item_type == "folder" or current_item_type == "file")
      and status_code == 302
      and (string.match(url["url"], "^https?://drive%.google%.com/drive/folders/[0-9A-Za-z_%-]+/?$") -- Folder start URL
           or string.match(url["url"], "^https?://drive%.google%.com/file/d/.*/view$")) -- File start URL
      and string.match(newloc, "^https://accounts%.google%.com/ServiceLogin%?") then
        print_debug("Private folder or file, exiting")
        tries = 0
        return wget.actions.EXIT
    -- Weird failure on file:1_3uGns8hH9MfT7dJSjVuAC1WlZmNzKnH where file_info_callback gives 404 but then open?id= redirects to a login page - perhaps a private file that was incompletedly deleted?
    elseif current_item_type == "file"
      and file_does_not_exist
      and string.match(url["url"], "^https://drive%.google%.com/open%?id=")
      and string.match(newloc, "^https://accounts%.google%.com/ServiceLogin%?") then
        return wget.actions.EXIT
    elseif not allowed(newloc, url["url"]) then
      print_debug("Disallowed URL " .. newloc)
      if string.match(newloc, "^https?://[^/]*google%.com/sorry") then
        print("You are being rate-limited.")
      end
      -- Continue on to the retry cycle
    else
      tries = 0
      print_debug("Following redirect to " .. newloc)
      assert(not (string.match(newloc, "^https?://[^/]*google%.com/sorry") or string.match(newloc, "^https?://consent%.google%.com/")))
      assert(not string.match(url["url"], "^https?://drive%.google%.com/file/d/.*/view$")) -- If this is a redirect, it will mess up initialization of file: items
      assert(not string.match(url["url"], "^https?://drive%.google%.com/drive/folders/[0-9A-Za-z_%-]+/?$")) -- Likewise for folder:

      addedtolist[newloc] = true
      return wget.actions.NOTHING
    end
  end


  local do_retry = false
  local maxtries = 12
  local url_is_essential = true

  -- Something related to quotas and caching that several people have encountered. My best guess is that the "not exceeded quota" version of a file gets served from a cache (with good uc?id= pages and everything before), but then they get the per-session download URL and in the processs of its generation some central service recognizes that the quota for the file was exceeded and gives a 403ing version.
  -- Search "RalliesSpoke" in channel logs for some more details
  if current_item_type == "file" and status_code == 403 and string.match(url["url"], "^https://doc%-[a-z0-9%-]+%.googleusercontent%.com/") then
    print("403ing DL url, maxtries to 3")
    print("You should only report this if you get it very frequently.")
    maxtries = 3
  end

  -- Whitelist instead of blacklist status codes
  local is_valid_404 = string.match(url["url"], "^https?://drive%.google%.com/drive/folders/[0-9A-Za-z_%-]+/?$") -- Start URL of folders - will end item if this happens
                  or string.match(url["url"], "^https?://drive%.google%.com/file/d/.*/view$") -- Start URL of files - will NOT end item if this happens
                  or string.match(url["url"], "^https://content%.googleapis%.com/drive/v2beta/files/") -- Files info request - will end item if this happens
                  or string.match(url["url"], "^https?://drive%.google%.com/open%?id=") -- Another indicator URL (file: and folder:) - not used for anything important
  local is_valid_400 = string.match(url["url"], "^https://lh3%.googleusercontent%.com/u/0/d/.*=w%d%d%d%-h%d%d%d%-p%-k%-nu%-iv2") -- Allow 400 on thumbnails - mysterious (i.e. not going to bother) failure in folder:0B7z5EDsKyEsGfkEybGh2Y0tuc0dpMTVCbDZ4N1RXTGZMbnhwWEZqcnJmMzVYcy10SEplSlE
  local is_valid_500 = string.match(url["url"], "^https://lh3%.googleusercontent%.com/u/0/d/.*=w%d%d%d%-h%d%d%d%-p%-k%-nu%-iv2") -- Allow 500s on thumbnails - happens in live version on folder:0B9UzADWnkrLHMnRsRHd0VWNWT1U
  local is_valid_403 = string.match(url["url"], "^https?://drive%.google%.com/file/d/.*/view$") -- Start URL of files, terms violations taken down - WILL end item in this case
  if status_code ~= 200
    and not (status_code == 404 and is_valid_404)
    and not (status_code == 400 and is_valid_400)
    and not (status_code == 403 and is_valid_403)
    and not (status_code == 500 and is_valid_500) then
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
  end_of_item()
  queue_list_to(discovered_items, "google-drive-hno3x9xu1hwk3an")
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

