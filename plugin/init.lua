--[[ This Plugin does the following:

1. Initialize the wezterm.GLOBAL.splitpaneinfo table.
   Detailed structure:  spi = wezterm.GLOBAL.splitpaneinfo[win_id][tab_id][pane_id] where
                        spi.parent     - stores the parent pane ID - string
                        spi.children   - stores a table of its children pane ID - string
                        spi.directions - stores a table of its children pane SplitPane direction
                        spi.vsplitedge - stores a string indicating the pane's vertical splitedge
                        spi.hsplitedge - stores a string indicating the pane's horizontal splitedge
   Note: win_id, tab_id, pane_id must be a string.

2. Provide 4 event handlers to performing the following task(s):
   1. window-config-reloaded: Update splitpaneinfo everytime config reloads
   2. sb-splitpane: Implement wezterm.action.SplitPane and update splitpaneinfo
   3. sb-closecurrentpane: Implement wezterm.action.CloseCurrentPane and update splitpaneinfo
   4. sb-equalize-panes: Uses wezterm.action.AdjustPaneSize and splitpaneinfo to equalize all panes
                         In addition, it considers the presence of panes with
                         non-adjustable-left-edge (naledge) within a group of panes in the
                         active tab and in pane(s) found in a subgroup of panes of a group of
                         panes amd how they affect the equalization width to be applied to a pane.

3. Provide the key bindings for WezTerm's config.keys to:
   1. Active pane by index
   2. Active adjacent pane on the left, right, above & below
   3. Adjust active pane size
   4. Create new pane on the left, right, top and bottom of currect pane
   5. Rotate pane sequence in a counterclockwise and clockwise manner
   6. Zoom in and out of pane
   7. Close active pane
   8. Equalize panes in the active tab

Written by: sunbearc22
Tested on: Ubuntu 24.04.3, wezterm 20251025-070338-b6e75fd7
]]
local M = {}

local wezterm = require("wezterm")
local act = wezterm.action

-- Initialize wezterm.GLOBAL.splitpaneinfo = {}
if not wezterm.GLOBAL.splitpaneinfo then
  wezterm.GLOBAL.splitpaneinfo = {}
  wezterm.log_info("[MPANES] Initialised wezterm.GLOBAL.splitpaneinfo")
end


---@param wgtable table A wezterm.GLOBAL table
---@return table
local function convert_weztermGLOBALtable_to_luatable(wgtable)
  local ltable = {}
  if wgtable then
    for i = 1, #wgtable do
      table.insert(ltable, wgtable[tostring(i)])
    end
  end
  return ltable
end


---@param name string Initial of event handler
---@param win_id string WezTerm's MuxWindow object ID
---@param tab_id string WezTerm's MuxTab object ID
---@param pane_id string WezTerm's Pane object ID
local function loginfo_pane_splitpaneinfo(name, win_id, tab_id, pane_id)
  local pane_spi = wezterm.GLOBAL.splitpaneinfo[win_id][tab_id][pane_id]
  local pid = pane_spi.parent
  local cids = pane_spi.children
  local dirs = pane_spi.directions
  local vse = pane_spi.vsplitedge
  local hse = pane_spi.hsplitedge
  local children = convert_weztermGLOBALtable_to_luatable(cids)
  local directions = convert_weztermGLOBALtable_to_luatable(dirs)
  wezterm.log_info(
    "[" .. name .. "] w:" .. win_id .. " t:" .. tab_id .. " p:" .. pane_id ..
    " : parent=" .. tostring(pid) ..
    " children={" .. table.concat(children, ',') .. "}" ..
    " directions={" .. table.concat(directions, ',') .. "}" ..
    " vsplitedge=" .. tostring(vse) ..
    " hsplitedge=" .. tostring(hse)
  )
end


---@param name string Initial of event handler
local function loginfo_splitpaneinfo(name)
  -- For debugging visualization of the fields of wezterm.GLOBAL.splitpaneinfo
  for win_id, _ in pairs(wezterm.GLOBAL.splitpaneinfo) do
    for tab_id, _ in pairs(wezterm.GLOBAL.splitpaneinfo[win_id]) do
      for pane_id, _ in pairs(wezterm.GLOBAL.splitpaneinfo[win_id][tab_id]) do
        loginfo_pane_splitpaneinfo(name, win_id, tab_id, pane_id)
      end
    end
  end
end


---@param window any A WezTerm Window object.
---@param name string Initial of event handler
local function update_splitpaneinfo(window, name)
  --[[ Function will:
  - 1. Initialize the window table of splitpaneinfo if it does not exist.
  - 2. Initialize the tab table of splitpaneinfo[win_id] if it does not exist and ensure that the
       ID of only existing tabs exist while expired tabs ID are removed.
  - 3. Initialize the pane table of splitpaneinfo[win_id][tab_id] if it does not exist and ensure
       that the ID of only existing panes exist while expired panes ID are removed. This pane table
       contains 5 elements (i.e. parent, children, directions, vsplitedge & hsplitedge) initially
       with nil value.
  - 4. Remove expired pane info from the parent, children & directions fields of each pane's
       splitpaneinfo.
  ]]
  -- 1. Initialize the window table of splitpaneinfo if it does not exist.
  local win_id = tostring(window:window_id())
  if not wezterm.GLOBAL.splitpaneinfo[win_id] then
    wezterm.GLOBAL.splitpaneinfo[win_id] = {}
    wezterm.log_info("[" .. name .. "] Initialized wezterm.GLOBAL.splitpaneinfo[" .. win_id .. "]")
  end

  -- 2. Extract all tab IDs from wezterm.GLOBAL.splitpaneinfo[win_id] which is not a sparse-table.
  local spi_tab_ids = {}
  local count = 0
  for tid, _ in pairs(wezterm.GLOBAL.splitpaneinfo[win_id]) do
    spi_tab_ids[tid] = true
    count = count + 1
  end
  -- wezterm.log_info("[MPANES] " ..
  --   count .. " spi_tab_ids elements in wezterm.GLOBAL.splitpaneinfo[" .. win_id .. "]")

  -- 3. Get Mux Window object from the active Window object
  local mwin = window:mux_window()

  -- 4. Get current tabs from the active Mux Window object and
  --    initialize tab table if it does not exist.
  local current_tab_ids = {}
  for _, mtab in ipairs(mwin:tabs()) do
    local tab_id = tostring(mtab:tab_id())
    current_tab_ids[tab_id] = true
    if not wezterm.GLOBAL.splitpaneinfo[win_id][tab_id] then
      wezterm.GLOBAL.splitpaneinfo[win_id][tab_id] = {}
      wezterm.log_info(
        "[" .. name .. "] Initialized wezterm.GLOBAL.splitpaneinfo[" .. win_id .. "][" .. tab_id .. "]"
      )
    end
  end

  -- 5. Remove old tabs that no longer exist in this window from wezterm.GLOBAL.splitpaneinfo
  for spi_tab_id, _ in pairs(spi_tab_ids) do
    if not current_tab_ids[spi_tab_id] then
      local win = wezterm.GLOBAL.splitpaneinfo[win_id]
      win[spi_tab_id] = nil
      wezterm.GLOBAL.splitpaneinfo[win_id] = win
      wezterm.log_info("[" .. name .. "] Removed old tab: " .. spi_tab_id .. " from window " .. win_id)
    end
  end

  -- Debug visualization
  -- for tab_id, _ in pairs(wezterm.GLOBAL.splitpaneinfo[win_id]) do
  --   wezterm.log_info("[MPANES] win_id=" .. win_id .. " tab_id=" .. tab_id)
  -- end

  -- 6. For each current tab, get its current panes and initialize its pane table if it does not
  --    exist. Also remove old panes that no longer exist.
  for _, mtab in ipairs(mwin:tabs()) do
    local tab_id = tostring(mtab:tab_id())

    -- 6.1 Get current panes from the actual tab
    local current_pane_ids = {}
    for _, jpane in ipairs(mtab:panes()) do
      local jpane_id = tostring(jpane:pane_id())
      current_pane_ids[jpane_id] = true

      -- 6.2 Initialize pane table if it does not exist.
      if not wezterm.GLOBAL.splitpaneinfo[win_id][tab_id][jpane_id] then
        wezterm.GLOBAL.splitpaneinfo[win_id][tab_id][jpane_id] = {
          parent = nil,     -- string
          children = nil,   -- sparse-table with string elements
          directions = nil, -- sparse-table with string elements
          vsplitedge = nil, -- string
          hsplitedge = nil, -- string
        }
        wezterm.log_info(
          "[" .. name .. "] Initialized wezterm.GLOBAL.splitpaneinfo["
          .. win_id .. "][" .. tab_id .. "][" .. jpane_id .. "]"
        )
      end
    end

    -- 6.3 Get panes ID in wezterm.GLOBAL.splitpaneinfo[win_id][tab_id]
    local spi_pane_ids = {}
    count = 0
    for pane_id, _ in pairs(wezterm.GLOBAL.splitpaneinfo[win_id][tab_id]) do
      spi_pane_ids[pane_id] = true
      count = count + 1
    end
    -- wezterm.log_info(
    --   "[MPANES] " .. count ..
    --   " spi_pane_ids elements in wezterm.GLOBAL.splitpaneinfo[" .. win_id .. "][" .. tab_id .. "]"
    -- )

    -- 6.4 Remove expired pane info from wezterm.GLOBAL.splitpaneinfo[win_id][tab_id]
    for spi_pane_id, _ in pairs(spi_pane_ids) do
      if not current_pane_ids[spi_pane_id] then
        local tab = wezterm.GLOBAL.splitpaneinfo[win_id][tab_id]
        tab[spi_pane_id] = nil
        wezterm.GLOBAL.splitpaneinfo[win_id][tab_id] = tab
        wezterm.log_info("[" .. name .. "] Removed old pane: " .. spi_pane_id .. " from tab " .. tab_id)
      end
    end
  end

  -- 7. Remove expired pane info from the parent, children & directions fields of each pane's
  --    splitpaneinfo.
  for win_id, _ in pairs(wezterm.GLOBAL.splitpaneinfo) do
    for tab_id, _ in pairs(wezterm.GLOBAL.splitpaneinfo[win_id]) do
      -- 7.1 Get existing panes
      local spi_panes = {}
      for jpane_id, _ in pairs(wezterm.GLOBAL.splitpaneinfo[win_id][tab_id]) do
        spi_panes[jpane_id] = true
      end
      -- 7.2 Update elements of splitpaneinfo
      for jpane_id, _ in pairs(wezterm.GLOBAL.splitpaneinfo[win_id][tab_id]) do
        local gspipid = wezterm.GLOBAL.splitpaneinfo[win_id][tab_id][jpane_id]
        local pid = gspipid.parent
        local cids = gspipid.children
        local dirs = gspipid.directions
        -- update parent
        if pid then
          if not spi_panes[pid] then
            pid = nil
          end
          gspipid.parent = pid
        end
        -- Update children & directions
        if cids then
          for i = 1, #cids do
            if not spi_panes[cids[tostring(i)]] then
              cids[tostring(i)] = nil
              dirs[tostring(i)] = nil
            end
          end
          gspipid.children = cids
          gspipid.directions = dirs
        end
      end
    end
  end

  loginfo_splitpaneinfo(name)
end


---@param window any A WezTerm Window object.
---@param pane any A WezTerm Pane object
wezterm.on('window-config-reloaded', function(window, pane)
  wezterm.log_info "[MPANES-WCR] updating wezterm.GLOBAL.splitpaneinfo ..."
  update_splitpaneinfo(window, "MPANES-WCR")
end)


---@param direction string The direction field of wezterm enum SplitPane.
---@return string
local function get_opposite_direction(direction)
  if direction == "Left" then
    return "Right"
  elseif direction == "Right" then
    return "Left"
  elseif direction == "Up" then
    return "Down"
  elseif direction == "Down" then
    return "Up"
  end
  return ""
end


---@param arraytable table
---@param target any
---@return boolean
local function contain(arraytable, target)
  --[[Function to check if arraytable contains element and it will return the corresponding
  boolean.]]
  for _, v in ipairs(arraytable) do
    if v == target then
      return true
    end
  end
  return false
end


---@param window any A WezTerm Window object.
---@param pane any A WezTerm Pane object
---@param direction string Specifies where the new pane will end up: "Left", "Right", "Up", "Down"
---@param size table Controls the size of the new pane. Can be {Cells=10} to specify eg: 10 cells or {Percent=50} to specify 50% of the available space. If omitted, {Percent=50} is the default.
wezterm.on("sb-splitpane", function(window, pane, direction, size)
  --[[Handler for the sb-splitpane event
  Key steps:
  1. Update wezterm.GLOBAL.splitpaneinfo.
  2. Get all the panes id and the max id value.
  3. Create the new pane via splitpane
  4. Get id of the new pane that is created by splitpane
  5. Update the children, directions, vsplitedge & hsplitedge fields of the active pane in
     wezterm.GLOBAL.splitpaneinfo
  6. Create new pane's wezterm.GLOBAL.splitpaneinfo
  ]]
  local name = "MPANES-SP"

  -- 1. Update wezterm.GLOBAL variables
  update_splitpaneinfo(window, name)

  local key, value = next(size)
  wezterm.log_info(
    "[" .. name .. "] Active Pane id:" .. pane:pane_id() ..
    "  SplitPane: direction=" .. direction ..
    " size=" .. key .. " " .. value
  )

  -- 2. Get id of all panes in active tab and the max id value.
  local atab = window:active_tab()
  local ids = {}    -- panes id : string type
  local max_ids = 0 -- max of of panes ids : number type
  for _, ipane in ipairs(atab:panes()) do
    table.insert(ids, tostring(ipane:pane_id()))
    max_ids = math.max(max_ids, ipane:pane_id())
  end
  -- wezterm.log_info("[" .. name .. "] #ids=" .. #ids .. " max_ids=" .. max_ids)

  -- 3. Create the new pane via splitpane
  window:perform_action(act.SplitPane { direction = direction, size = size, }, pane)

  -- 4. Get id of the new pane that is created by splitpane
  local new_pane_id = nil
  for _, ipane in ipairs(atab:panes()) do
    if ipane:pane_id() > max_ids then
      new_pane_id = tostring(ipane:pane_id()) -- string type
      break
    end
  end
  wezterm.log_info("[" .. name .. "] - New Pane id:" .. new_pane_id .. " is created.")

  -- 5. Update the children, directions & splitedge fields of the active pane in wezterm.GLOBAL.splitpaneinfo
  -- 5.1 Ensure all indexes to be used in wezterm.GLOBAL.splitpaneinfo are string type
  local w_id = tostring(window:window_id())
  local t_id = tostring(atab:tab_id())
  local p_id = tostring(pane:pane_id())
  local np_id = tostring(new_pane_id)

  -- 5.2 Update children field in wezterm.GLOBAL.splitpaneinfo of the original active pane
  local apane_spi = wezterm.GLOBAL.splitpaneinfo[w_id][t_id][p_id]
  if not apane_spi.children then
    apane_spi.children = {}
    apane_spi.children["1"] = np_id
    -- local children = convert_weztermGLOBALtable_to_luatable(apane_spi.children)
    -- wezterm.log_info("[" .. name .. "] - " .. p_id .. ": created children={" .. table.concat(children, ',') .. "}")
  else
    local cids = apane_spi.children
    local newsize = tostring(#cids + 1)
    apane_spi.children[newsize] = np_id
    -- local children = convert_weztermGLOBALtable_to_luatable(apane_spi.children)
    -- wezterm.log_info("[" .. name .. "] - " .. p_id .. ": updated children={" .. table.concat(children, ',') .. "}")
  end

  -- 5.3 Update directions field in wezterm.GLOBAL.splitpaneinfo of original active pane
  if not apane_spi.directions then
    apane_spi.directions = {}
    apane_spi.directions["1"] = direction
    -- local directions = convert_weztermGLOBALtable_to_luatable(apane_spi.directions)
    -- wezterm.log_info("[" .. name .. "] - " .. p_id .. ": created directions={" .. table.concat(directions, ',') .. "}")
  else
    local dirs = apane_spi.directions
    local newsize = tostring(#dirs + 1)
    apane_spi.directions[newsize] = direction
    -- local directions = convert_weztermGLOBALtable_to_luatable(apane_spi.directions)
    -- wezterm.log_info("[" .. name .. "] - " .. p_id .. ": updated directions={" .. table.concat(directions, ',') .. "}")
  end

  -- 5.4 Update vsplitedge & hsplitedge fields in wezterm.GLOBAL.splitpaneinfo of original active pane
  if direction == "Left" or direction == "Right" then
    apane_spi.vsplitedge = direction
    -- wezterm.log_info("[" .. name .. "] - " .. p_id .. ": change vsplitedge=" .. apane_spi.vsplitedge)
  elseif direction == "Up" or direction == "Down" then
    apane_spi.hsplitedge = direction
    -- wezterm.log_info("[" .. name .. "] - " .. p_id .. ": change hsplitedge=" .. apane_spi.hsplitedge)
  end

  -- 6. Create splitpaneinfo of New Pane
  local vsplitedge
  local hsplitedge
  if direction == "Left" or direction == "Right" then
    vsplitedge = get_opposite_direction(direction)
    hsplitedge = apane_spi.hsplitedge
  elseif direction == "Up" or direction == "Down" then
    vsplitedge = apane_spi.vsplitedge
    hsplitedge = get_opposite_direction(direction)
  end
  wezterm.GLOBAL.splitpaneinfo[w_id][t_id][np_id] = {
    parent = p_id,
    children = {},
    directions = {},
    vsplitedge = vsplitedge,
    hsplitedge = hsplitedge
  }
  -- wezterm.log_info("[" .. name .. "] - " .. np_id .. ": created splitpaneinfo")

  -- Show splitpaneinfo of original active pane and new pane
  wezterm.log_info("[" .. name .. "] - Updated wezterm.GLOBAL.splitpaneinfo[" .. w_id .. "][" .. t_id .. "][pane_id]")
  local affected_ids = { p_id, np_id }
  for _, id in ipairs(affected_ids) do
    local gspipid = wezterm.GLOBAL.splitpaneinfo[w_id][t_id][id]
    local c_ids = gspipid.children
    local dirs = gspipid.directions
    local children = convert_weztermGLOBALtable_to_luatable(c_ids)
    local directions = convert_weztermGLOBALtable_to_luatable(dirs)
    wezterm.log_info(
      "[" .. name .. "]  - " .. id ..
      ": parent=" .. tostring(gspipid.parent) ..
      " children={" .. table.concat(children, ',') .. "}" ..
      " directions={" .. table.concat(directions, ',') .. "}" ..
      " vsplitedge=" .. tostring(gspipid.vsplitedge) ..
      " hsplitedge=" .. tostring(gspipid.hsplitedge)
    )
  end
end)


---@param window any A WezTerm Window object.
---@return table
local function map_pane_id_to_paneinfo(window)            -- changed argument to window instead of panesinfo
  local panesinfo = window:active_tab():panes_with_info() -- create new panesinfo everytime this function is called
  local pane_id_info_map = {}
  for _, paneinfo in ipairs(panesinfo) do
    pane_id_info_map[paneinfo.pane:pane_id()] = paneinfo
  end
  -- local pane_id_info_map_keys = {}
  -- for k, _ in pairs(pane_id_info_map) do
  --   table.insert(pane_id_info_map_keys, k)
  -- end
  -- wezterm.log_info("[MPANES-EP] - pane_id_info_map_keys={" .. table.concat(pane_id_info_map_keys, ',') .. "}")
  return pane_id_info_map
end


---@param window any A WezTerm Window object.
---@param pane any A WezTerm Pane object
wezterm.on("sb-closecurrentpane", function(window, pane, confirm)
  --[[ Event handler to close the current pane and update the corresponding splitpaneinfo
  ]]
  local name = "MPANES-CCP"

  -- 1. Update wezterm.GLOBAL variables
  update_splitpaneinfo(window, name)

  -- 2. Get active window, tab & pane ids
  local win_id = tostring(window:window_id())
  local tab_id = tostring(window:active_tab():tab_id())
  local pane_id = tostring(pane:pane_id())
  wezterm.log_info(
    "[" .. name ..
    "] Close Current Pane win_id:" .. win_id .. " tab_id:" .. tab_id .. " pane_id:" .. pane_id
  )

  -- 3. Get the splitpaneinfo of the current pane and its parent pane
  local pane_spi = wezterm.GLOBAL.splitpaneinfo[win_id][tab_id][pane_id]
  local parent_spi = wezterm.GLOBAL.splitpaneinfo[win_id][tab_id][tostring(pane_spi.parent)]
  wezterm.log_info("[" .. name .. "] - parent pane id:" .. tostring(pane_spi.parent))

  -- 4. Update the splitpaneinfo of the current pane's children panes.
  --    Make these children panes adopt the current pane's parent pane as their parent pane
  local children = convert_weztermGLOBALtable_to_luatable(pane_spi.children)
  wezterm.log_info("[" .. name .. "] - " .. pane_id .. ": children={" .. table.concat(children, ',') .. "}")
  if pane_spi.children and #pane_spi.children > 0 then -- pane has children
    if pane_spi.parent then                            -- pane parent
      for k, _ in pairs(pane_spi.children) do
        local id = pane_spi.children[k]
        wezterm.GLOBAL.splitpaneinfo[win_id][tab_id][tostring(id)].parent = pane_spi.parent
        wezterm.log_info(
          "[" .. name .. "] -  updated children's wezterm.GLOBAL.splitpaneinfo[" ..
          win_id .. "][" .. tab_id .. "][" .. tostring(id) .. "].parent = " ..
          tostring(wezterm.GLOBAL.splitpaneinfo[win_id][tab_id][tostring(id)].parent)
        )
      end
    else -- pane has no parent
      for i, id in ipairs(children) do
        if i == 1 then
          wezterm.GLOBAL.splitpaneinfo[win_id][tab_id][tostring(id)].parent = pane_spi.parent
        else
          local previous_index = i - 1
          wezterm.GLOBAL.splitpaneinfo[win_id][tab_id][tostring(id)].parent = tostring(children[previous_index])
          local p_children = wezterm.GLOBAL.splitpaneinfo[win_id][tab_id][tostring(children[previous_index])].children
          p_children[tostring(#p_children + 1)] = tostring(id)
          wezterm.GLOBAL.splitpaneinfo[win_id][tab_id][tostring(children[previous_index])].children = p_children
        end
      end
      for _, id in ipairs(children) do
        wezterm.log_info(
          "[" .. name .. "] -  updated children's wezterm.GLOBAL.splitpaneinfo[" ..
          win_id .. "][" .. tab_id .. "][" .. tostring(id) .. "].parent = " ..
          tostring(wezterm.GLOBAL.splitpaneinfo[win_id][tab_id][tostring(id)].parent)
        )
      end
      for _, id in ipairs(children) do
        local c = wezterm.GLOBAL.splitpaneinfo[win_id][tab_id][tostring(id)].children
        local cc = convert_weztermGLOBALtable_to_luatable(c)
        wezterm.log_info(
          "[" .. name .. "] -  updated children's wezterm.GLOBAL.splitpaneinfo[" ..
          win_id .. "][" .. tab_id .. "][" .. tostring(id) .. "].children = {" ..
          table.concat(cc) .. "}"
        )
      end
    end
  end

  -- 5. Update current pane's parent pane splitpaneinfo.
  --    Make parent pane's children and directions fields remove/replace current pane info
  --    with the current pane's children pane's info.
  --    - Remove if current pane's children pane's children and directions fields is empty.
  --    - Replace if current pane's children pane's children and directions fields is not empty.
  --      Use first element for replacement.
  --      Subsequent elements are appended to the end of parent pane's children and directions fields.
  if parent_spi then
    for k, _ in pairs(parent_spi.children) do
      if parent_spi.children[tostring(k)] == pane_id then
        parent_spi.children[tostring(k)] = nil   -- remove
        parent_spi.directions[tostring(k)] = nil -- remove
      end
      break
    end
    if #pane_spi.children > 1 then
      wezterm.log_info("[" .. name .. "] - #pane_spi.children > 1 ")
      for i = 1, #pane_spi.children do
        parent_spi.children[tostring(#parent_spi.children + i - 1)] = pane_spi.children[tostring(i)]
        parent_spi.directions[tostring(#parent_spi.directions + i - 1)] = pane_spi.directions[tostring(i)]
      end
    end

    --- Debug visualization
    local pchildren = convert_weztermGLOBALtable_to_luatable(parent_spi.children)
    local pdirections = convert_weztermGLOBALtable_to_luatable(parent_spi.directions)
    wezterm.log_info(
      "[" .. name .. "] -  updated wezterm.GLOBAL.splitpaneinfo[" ..
      win_id .. "][" .. tab_id .. "][" .. tostring(pane_spi.parent) .. "].children = {" ..
      table.concat(pchildren, ',') .. "}"
    )
    wezterm.log_info(
      "[" .. name .. "] -  updated wezterm.GLOBAL.splitpaneinfo[" ..
      win_id .. "][" .. tab_id .. "][" .. tostring(pane_spi.parent) .. "].directions = {" ..
      table.concat(pdirections, ',') .. "}")
  end

  -- 6. Update the vsplitedge field of its parent pane splitpaneinfo -- TO DO
  local lpane = window:active_tab():get_pane_direction("Left")
  local lpane_id, lpane_spi
  if lpane then
    lpane_id = tostring(lpane:pane_id())
    lpane_spi = wezterm.GLOBAL.splitpaneinfo[win_id][tab_id][lpane_id]
    wezterm.log_info(
      "[" .. name .. "] - left pane id:" .. lpane_id ..
      " vsplitedge=" .. lpane_spi.vsplitedge .. " parent=" .. tostring(lpane_spi.parent)
    )
  end
  local rpane = window:active_tab():get_pane_direction("Right")
  local rpane_id, rpane_spi
  if rpane then
    rpane_id = tostring(rpane:pane_id())
    rpane_spi = wezterm.GLOBAL.splitpaneinfo[win_id][tab_id][rpane_id]
    wezterm.log_info(
      "[" .. name .. "] - right pane id:" .. rpane_id ..
      " vsplitedge=" .. rpane_spi.vsplitedge .. " parent=" .. tostring(rpane_spi.parent)
    )
  end
  wezterm.log_info("pane_spi.children = " .. tostring(pane_spi.children))
  wezterm.log_info("#pane_spi.children = " .. tostring(#pane_spi.children))
  wezterm.log_info("pane_spi.vsplitedge = " .. tostring(pane_spi.vsplitedge))
  if parent_spi then
    wezterm.log_info("parent_spi.vsplitedge = " .. tostring(parent_spi.vsplitedge))
  end

  -- Known conditions needing a change of vsplitedge
  local pane_id_to_paneinfo_map = map_pane_id_to_paneinfo(window)
  if lpane and lpane_spi.vsplitedge == "Right" and pane_spi.vsplitedge == "Left" and not rpane then
    -- change lpane's vsplitedge
    wezterm.log_info(" change lpane's vsplitedge")
    wezterm.GLOBAL.splitpaneinfo[win_id][tab_id][lpane_id].vsplitedge = pane_spi.vsplitedge
  elseif (not lpane and pane_spi.vsplitedge == "Right" and rpane and rpane_spi.vsplitedge == "Left") or
      (lpane and lpane_spi.vsplitedge == "Left" and pane_spi.vsplitedge == "Right" and rpane and rpane_spi.vsplitedge == "Left") then
    -- change rpane's vsplitedge
    wezterm.log_info(" change rpane's vsplitedge")
    wezterm.GLOBAL.splitpaneinfo[win_id][tab_id][rpane_id].vsplitedge = pane_spi.vsplitedge
  end

  -- 7. Remove active pane table from wezterm.GLOBAL.splitpaneinfo
  local spi_atab = wezterm.GLOBAL.splitpaneinfo[win_id][tab_id]
  spi_atab[pane_id] = nil
  wezterm.GLOBAL.splitpaneinfo[win_id][tab_id] = spi_atab

  -- 8. Close current pane
  window:perform_action(act.CloseCurrentPane { confirm = confirm }, pane)
  wezterm.log_info("[" .. name .. "] - current pane id:" .. pane_id .. " closed.")

  if #window:active_tab():panes() == 1 then
    local apane = window:active_tab():active_pane()
    local apane_id = tostring(apane:pane_id())
    local apane_spi = wezterm.GLOBAL.splitpaneinfo[win_id][tab_id][apane_id]
    apane_spi.parent = nil
    apane_spi.children = {}
    apane_spi.directions = {}
    apane_spi.vsplitedge = nil
    apane_spi.hsplitedge = nil
    wezterm.GLOBAL.splitpaneinfo[win_id][tab_id][apane_id] = apane_spi
  end

  loginfo_splitpaneinfo(name)
end)


---@param atab any A WezTerm MuxTab object of the active tab.
local function get_rows_in_active_tab(atab)
  --[[Function to get the height of the active tab in terms of cell rows.
  It is obtained by adding the height of all paned with left=0.]]
  local nrows = 0
  local panesinfo = atab:panes_with_info()
  for _, paneinfo in ipairs(panesinfo) do
    if paneinfo.left == 0 then
      local height = paneinfo.height
      -- wezterm.log_info("pane_id=" .. tostring(paneinfo.pane:pane_id()) .. " height=" .. height)
      nrows = nrows + height
    end
  end
  wezterm.log_info("[MPANES-EP] - tab cell rows = " .. tostring(nrows))
  return nrows
end


---@param window any A WezTerm Window object.
---@return table
local function get_panes_groups(window)
  --[[This function returns the 'groups' array-table which can consist of multiple 'group'
  array-table that consist of WezTerm's PaneInformation object(s).

  Procedure for creating 'groups' and 'group':
  The WezTerm's PaneInformation sequence returned by wezterm Muxtab:panes_with_info() is used to
  group panes according to their column sequence from left to right of the viewport.
  - If a pane's height is greater than or equal to its tab's height (in terms of cell rows) that
    pane is treated a group.
  - Otherwise, smaller panes within a column are grouped together. The criteria to transit to
    creating the next group is when the next pane's height is greater than or equal to its tab's
    height or its next pane's top is less than the current pane's top and its next pane's top
    equals 0.
  ]]
  local groups = {}
  local group = {}
  local atab = window:active_tab()
  local panesinfo = atab:panes_with_info()
  local nrows = get_rows_in_active_tab(atab)

  for i, ipaneinfo in ipairs(panesinfo) do
    local top = ipaneinfo.top
    local height = ipaneinfo.height
    -- local id = ipaneinfo.pane:pane_id()
    -- -- wezterm.log_info(
    -- --   "[EPanes] ipaneinfo: pane_id=" .. tostring(id) ..
    -- --   " top=" .. tostring(top) ..
    --   " height=" .. tostring(height)
    -- )
    table.insert(group, ipaneinfo)

    if height >= nrows then
      -- pane's rows is same as or greater than tab's rows : group has only one element
      table.insert(groups, group)
      -- wezterm.log_info("[EPanes] #group = " .. tostring(#group))
      group = {}
    else
      -- pane's row is less than the tab's rows : group has more than one element
      if i + 1 <= #panesinfo then -- not last pane
        local next_paneinfo = panesinfo[i + 1]
        -- local next_pane_id = next_paneinfo.pane:pane_id()
        local next_pane_top = next_paneinfo.top
        local next_pane_height = next_paneinfo.height
        -- wezterm.log_info(
        --   "[EPanes] npaneinfo: pane_id=" .. tostring(next_pane_id) ..
        --   " top=" .. tostring(next_pane_top) ..
        --   " rows=" .. tostring(next_pane_height)
        -- )
        -- Two conditions to transit to next group creation
        if next_pane_height == nrows then
          table.insert(groups, group)
          -- wezterm.log_info("[EPanes] #group = " .. tostring(#group))
          group = {}
        elseif next_pane_top < top and next_pane_top == 0 then
          table.insert(groups, group)
          -- wezterm.log_info("[EPanes] #group = " .. tostring(#group))
          group = {}
        end
      elseif i == #panesinfo then -- last pane
        table.insert(groups, group)
        -- wezterm.log_info("[EPanes] #group = " .. tostring(#group))
        group = {}
      end
    end
  end
  -- wezterm.log_info("[EPanes] #groups = " .. tostring(#groups))
  return groups
end

---@param groups table[]  An array-table with array-tables of WezTerm PaneInformation objects.
---@param win_id string WezTerm's MuxWindow object ID
---@param tab_id string WezTerm's MuxTab object ID
local function get_group_with_non_adjustable_left_edge(groups, win_id, tab_id)
  --[[ Check if there is/are any group with non_adjustable_left_edge. If so, the group's index
  will be stored in an array-table and returned. If not, an empty table will be returned.
  Non_adjustable_left_edge occurs when a group splitedge is Left and its right group neighbour
  splitedge is Right. When this situation occurs, that group's right edge(or its right group
  neighbour left edge) cannot be shifted by WezTerm's AdjustPaneSize. To move this edge, a
  mouse pointer has to be used to shift it manually. That is, such vsplitedge is unmovable and
  has to be treated as a datum to work out the average no. of column cells of each pane, i.e.
  equalization width or ewidth. See https://github.com/wezterm/wezterm/issues/7401 for a visual
  description of what is a non_adjustable_left_edge.
  ]]
  local group_with_non_adjustable_left_edge = {}
  local groups_vsplitedge = {}
  for i, group in ipairs(groups) do
    if i ~= #groups then -- Exclude last group
      -- Get current group's rightmost pane with top=0
      local cg_pane_id = nil
      local cg_vsplitedge = nil
      local ng_pane_id = nil
      local ng_vsplitedge = nil
      if #group == 1 then -- group has only 1 element
        cg_pane_id = tostring(group[1].pane:pane_id())
        cg_vsplitedge = wezterm.GLOBAL.splitpaneinfo[win_id][tab_id][cg_pane_id].vsplitedge
      else                   -- group has more than 1 element
        if i ~= #groups then -- not the last group
          local jmaxleft = 0
          for j, jpaneinfo in ipairs(group) do
            if jpaneinfo.top == 0 then
              jmaxleft = math.max(jmaxleft, jpaneinfo.left)
              if jpaneinfo.left == jmaxleft then
                cg_pane_id = tostring(jpaneinfo.pane:pane_id())
              end
            end
          end
        else -- last group
          cg_pane_id = tostring(group[1].pane:pane_id())
        end
        cg_vsplitedge = wezterm.GLOBAL.splitpaneinfo[win_id][tab_id][cg_pane_id].vsplitedge
      end
      -- wezterm.log_info("[EPanes] " .. i .. " cg_pane_id=" .. cg_pane_id .. " cg_vsplitedge=" .. cg_vsplitedge)
      table.insert(groups_vsplitedge, cg_vsplitedge)

      -- Get next group's leftmost pane with top=0, i.e 1st element of each group
      local next_group = groups[i + 1]
      ng_pane_id = tostring(next_group[1].pane:pane_id())
      ng_vsplitedge = wezterm.GLOBAL.splitpaneinfo[win_id][tab_id][ng_pane_id].vsplitedge
      -- wezterm.log_info("[EPanes] " .. i .. " ng_pane_id=" .. ng_pane_id .. " ng_vsplitedge=" .. ng_vsplitedge)

      -- Check for group_with_non_adjustable_left_edge
      if cg_vsplitedge == "Left" and ng_vsplitedge == "Right" then
        table.insert(group_with_non_adjustable_left_edge, i + 1)
      end
    end
  end

  -- This last section does not affect group_with_non_adjustable_left_edge
  -- It is intended to complete insert the vsplitedge of the last group of groups into groups_vsplitedge
  local lastgroup_pane_id = nil
  local lastgroup_vsplitedge = nil
  if #groups[#groups] == 1 then -- last group has only 1 element
    lastgroup_pane_id = tostring(groups[#groups][1].pane:pane_id())
    lastgroup_vsplitedge = wezterm.GLOBAL.splitpaneinfo[win_id][tab_id][lastgroup_pane_id].vsplitedge
  else -- group has more than 1 element
    local minleft = 0
    for _, jpaneinfo in ipairs(groups[#groups]) do
      if jpaneinfo.top == 0 then
        minleft = math.max(minleft, jpaneinfo.left)
        if jpaneinfo.left == minleft then
          lastgroup_pane_id = tostring(jpaneinfo.pane:pane_id())
        end
      end
    end
    lastgroup_vsplitedge = wezterm.GLOBAL.splitpaneinfo[win_id][tab_id][lastgroup_pane_id].vsplitedge
  end
  table.insert(groups_vsplitedge, lastgroup_vsplitedge)
  wezterm.log_info("[MPANES-EP] - groups vsplitedge={" .. table.concat(groups_vsplitedge, ',') .. "}")

  return group_with_non_adjustable_left_edge
end


---@param panesinfo table  An array-table of WezTerm's PaneInformation Objects
---@param groups table[]  An array-table with array-tables of WezTerm PaneInformation objects.
---@return number group_ewidth Equlization width
local function get_group_equalization_width_default(panesinfo, groups)
  -- Assumes each group will have the same averaged number of column cells.
  local atab_last_pane_left = panesinfo[#panesinfo].left
  local atab_last_pane_width = panesinfo[#panesinfo].pane:get_dimensions().cols
  local atab_column_cells = atab_last_pane_left + atab_last_pane_width
  local group_ewidth = math.floor(atab_column_cells / #groups)
  -- wezterm.log_info("[EPanes] atab_last_pane_left=" .. atab_last_pane_left)
  -- wezterm.log_info("[EPanes] atab_last_pane_width=" .. atab_last_pane_width)
  -- wezterm.log_info("[EPanes] atab_column_cells=" .. atab_column_cells)
  -- wezterm.log_info("[EPanes] group_ewidth=" .. group_ewidth)
  return group_ewidth
end


---@param groups table[] An array-table with array-tables of WezTerm PaneInformation objects.
---@param pane_id number WezTerm's Pane Object ID
---@return number|nil
local function get_pane_groupindex(groups, pane_id)
  for groupindex, group in ipairs(groups) do
    for _, paneinfo in ipairs(group) do
      if paneinfo.pane:pane_id() == pane_id then
        return groupindex
      end
    end
  end
end

---@param group table[] An array-table of WezTerm's PaneInformation objects
---@return number[]
local function get_top_of_group(group)
  --[[Get the unique PaneInformation.top values from a group, i.e. an array-table of
  PaneInformation.]]
  local tops = {}
  for _, jpaneinfo in ipairs(group) do
    if not contain(tops, jpaneinfo.top) then
      table.insert(tops, jpaneinfo.top)
    end
  end
  return tops
end


---@param win_id string WezTerm's MuxWindow object ID
---@param tab_id string WezTerm's MuxTab object ID
---@return number[]
local function get_panes_creation_sequence(win_id, tab_id)
  --[[Returns an array-table of pane_ids in the sequence of its creation]]
  local panes_creation_sequence = {} -- according to creation sequence
  for jpane_id, _ in pairs(wezterm.GLOBAL.splitpaneinfo[win_id][tab_id]) do
    table.insert(panes_creation_sequence, tonumber(jpane_id))
  end
  table.sort(panes_creation_sequence)
  -- wezterm.log_info("panes_creation_sequence={" .. table.concat(panes_creation_sequence, ', ') .. "}")
  return panes_creation_sequence
end

---@param group any[]  An array-table of WezTerm's PaneInformation Objects
---@return table
local function get_subgroups_of_group(group)
  --[[Function to get the subgroups of PaneInformation from a group of PaneInformation.
  subgroups is a table where its key is PaneInformation.top and value is an array-table of
  PaneInformation.
  ]]
  local tops = get_top_of_group(group)
  local subgroups = {}
  for _, top in ipairs(tops) do
    subgroups[top] = {}
  end
  for _, jpaneinfo in ipairs(group) do
    table.insert(subgroups[jpaneinfo.top], jpaneinfo)
  end
  -- For debugging
  -- for i, subgroup in pairs(subgroups) do
  --   for j, sg_paneinfo in ipairs(subgroup) do
  --     local sg_pane_id = sg_paneinfo.pane:pane_id()
  --     wezterm.log_info("subgroups: i=" .. i .. " j=" .. j .. " sg_pane_id=" .. sg_pane_id)
  --   end
  -- end
  return subgroups
end


local function get_pane_equalization_width_map_for_no_naledge(window, groups)
  --[[This functions returns a map of the pane_id and its equalization width of the active tab.
  ]]
  -- 1. Get group's equalization width for no non_adjustable_left_edge condition
  local panesinfo = window:active_tab():panes_with_info()
  local group_ewidth = get_group_equalization_width_default(panesinfo, groups)
  -- 2. Create a map of pane_id and its equalizing width
  local pane_ewidth_map = {}
  for _, ipaneinfo in ipairs(panesinfo) do
    local id = ipaneinfo.pane:pane_id()
    local ipane_groupindex = get_pane_groupindex(groups, id)
    if #groups[ipane_groupindex] == 1 then -- when group has only one pane
      pane_ewidth_map[id] = group_ewidth
    else                                   -- when group has more than 1 pane
      local subgroups = get_subgroups_of_group(groups[ipane_groupindex])
      for _, subgroup in pairs(subgroups) do
        for _, sg_paneinfo in ipairs(subgroup) do
          if sg_paneinfo.pane:pane_id() == id then
            pane_ewidth_map[id] = math.floor(group_ewidth / #subgroup)
            break
          end
        end
      end
    end
  end
  return pane_ewidth_map
end


---@param pane_id number WezTerm Pane object's ID.
---@param subgroups table A sparse-table of the subgroup of panes in the active tab.
---@return table
local function get_pane_subgroup_info(pane_id, subgroups)
  local pane_subgroup_top
  local pane_subgroup
  local pane_subgroup_index
  for top, subgroup in pairs(subgroups) do
    for index, paneinfo in ipairs(subgroup) do
      if paneinfo.pane:pane_id() == pane_id then
        pane_subgroup_top = top
        pane_subgroup = subgroup
        pane_subgroup_index = index
        break
      end
    end
  end
  return { pane_subgroup, pane_subgroup_top, pane_subgroup_index }
end


local function get_pane_equalization_width_map_for_naledge(window, groups, gwnaledge)
  --[[ This functions returns a map of the pane_id and its equalization width of the active tab with
  pane group(s) that has non_adjustable_left_edge.
  Procedure:
  1. Get the equalization width(ewidth) of each group bounded by non_adjustable_left_edge(naledge).
  2. Create a map to store each of these groups and their ewidth, i.e groups_ewidth
  3. Get the ewidth of the group(s) beyond the bound of non_adjustable_left_edge(naledge) and store
     them in groups_ewidth too.
  4. Create a map to store each pane and their ewidth using the info from groups_ewidth
     - There are separate algorithm to do this for when a group has only one pane and multiple panes.
     - The latter further considers when the group has multiple subgroup and when each subgroup has
       only one pane or multiple panes.
  ]]
  -- 1. Get the equalization width(ewidth) of each group bounded by naledge.
  local panesinfo = window:active_tab():panes_with_info()
  local gwnaledge_ewidths = {}
  local ewidth_between_gwnaledge
  for i, group_index in ipairs(gwnaledge) do
    -- wezterm.log_info(" groups[group_index][1].left=" .. groups[group_index][1].left)
    if i == 1 then -- first gwnaledge
      local col_cells = groups[group_index][1].left - 1
      ewidth_between_gwnaledge = math.floor(col_cells / (group_index - 1))
      -- wezterm.log_info(" " .. i .. " first gwnaledge  ewidth_between_gwnaledge=" .. ewidth_between_gwnaledge)
    else -- subsequent gwnaledge
      local col_cells_between_gwnaledge = groups[group_index][1].left - groups[gwnaledge[i - 1]][1].left
      local ngroups_between_gwnaledge = group_index - gwnaledge[i - 1]
      ewidth_between_gwnaledge = math.floor(
        col_cells_between_gwnaledge / ngroups_between_gwnaledge
      )
      -- wezterm.log_info(" " .. i .. " subsequent gwnaledge  ewidth_between_gwnaledge=" .. ewidth_between_gwnaledge)
    end
    table.insert(gwnaledge_ewidths, ewidth_between_gwnaledge)
  end
  -- wezterm.log_info(
  --   " gwnaledge_ewidths={" .. table.concat(gwnaledge_ewidths, ', ') .. "}"
  -- )

  -- 2. Create a table to store these equlization width of each group
  local groups_ewidth = {}
  for group_index, _ in ipairs(groups) do
    for j, gwnaledge_index in ipairs(gwnaledge) do
      if group_index < gwnaledge_index then
        groups_ewidth[group_index] = gwnaledge_ewidths[j]
        break
      end
    end
  end

  -- 3. Get the equalization width of groups out of the range of gwnaledge and store them in groups_ewidth
  local ls_start_group = groups[gwnaledge[#gwnaledge]]
  local ls_end_group = groups[#groups]
  local ls_1st_col_cell = ls_start_group[1].left
  local ls_last_col_cell = ls_end_group[#ls_end_group].left + ls_end_group[#ls_end_group].width
  local ls_width = ls_last_col_cell - ls_1st_col_cell
  local ls_ngroups = #groups - gwnaledge[#gwnaledge] + 1
  local ls_ewidth = math.floor(ls_width / ls_ngroups)
  -- wezterm.log_info(" gwnaledge[#gwnaledge]=" .. gwnaledge[#gwnaledge])
  -- wezterm.log_info(" gwnaledge[" .. #gwnaledge .. "]=" .. gwnaledge[#gwnaledge] .. " #groups=" .. #groups)
  -- wezterm.log_info(" ls_1st_col_cell=" .. ls_1st_col_cell .. " ls_last_col_cell=" .. ls_last_col_cell)
  -- wezterm.log_info(" ls_width=" .. ls_width)
  -- wezterm.log_info(" ls_ngroups=" .. ls_ngroups)
  -- wezterm.log_info(" ls_ewidth=" .. ls_ewidth)
  -- Include the equalization width of group(s) out of the range of gwnaledge into groups_ewidth
  for group_index = gwnaledge[#gwnaledge], #groups do
    groups_ewidth[group_index] = ls_ewidth
  end

  -- 4. Create a map of pane_id and its equalizing width
  local paneid_ewidth_map = {}
  local win_id = tostring(window:window_id())
  local tab_id = tostring(window:active_tab():tab_id())
  for _, ipaneinfo in ipairs(panesinfo) do
    local id = ipaneinfo.pane:pane_id()
    local ipane_groupindex = get_pane_groupindex(groups, id)

    if #groups[ipane_groupindex] == 1 then -- when group has only one pane
      -- 4.1 Update pane's id-ewidth map using groups_ewidth
      paneid_ewidth_map[id] = groups_ewidth[ipane_groupindex]
    else -- when group has more than 1 pane
      -- 4.1 Get subgroups of group
      local subgroups = get_subgroups_of_group(groups[ipane_groupindex])

      -- 4.2 Determine pane's subgroup
      local pane_subgroup_info = get_pane_subgroup_info(id, subgroups)
      local pane_subgroup = pane_subgroup_info[1]
      -- local pane_subgroup_top = pane_subgroup_info[2]
      -- wezterm.log_info(id .. " pane_subgroup_top=" .. pane_subgroup_top)

      -- 4.3 Store the id and vsplitedge of panes in subgroup in array-tables
      local sg_panes_id = {}
      local sg_panes_vsplitedge = {}
      for _, sg_paneinfo in ipairs(pane_subgroup) do
        local sg_pane_id = sg_paneinfo.pane:pane_id()
        local vsplitedge = wezterm.GLOBAL.splitpaneinfo[win_id][tab_id][tostring(sg_pane_id)].vsplitedge
        table.insert(sg_panes_id, sg_pane_id)
        table.insert(sg_panes_vsplitedge, vsplitedge)
      end
      -- wezterm.log_info(id .. " " .. pane_subgroup_top .. " sg_panes_id={" .. table.concat(sg_panes_id, ',') .. "}")
      -- wezterm.log_info(id ..
      --   " " .. pane_subgroup_top .. " sg_panes_vsplitedge={" .. table.concat(sg_panes_vsplitedge, ',') .. "}")

      -- 4.4 Check for the presence of naledge in subgroup
      local sg_naledge = {}
      for i, vsplitedge in ipairs(sg_panes_vsplitedge) do
        if i + 1 <= #sg_panes_vsplitedge then
          if vsplitedge == "Left" and sg_panes_vsplitedge[i + 1] == "Right" then
            table.insert(sg_naledge, i + 1)
          end
        end
      end
      -- wezterm.log_info(id .. " " .. pane_subgroup_top .. " sg_naledge={" .. table.concat(sg_naledge, ',') .. "}")

      -- 4.5 Create ewidth map
      if #sg_naledge == 0 then -- when naledge does not exist
        -- 4.5.a  Use the ewidth in groups_ewidth to update pane's id-ewidth map
        for _, sg_paneinfo in ipairs(pane_subgroup) do
          if sg_paneinfo.pane:pane_id() == id then
            paneid_ewidth_map[id] = math.floor(groups_ewidth[ipane_groupindex] / #pane_subgroup)
          end
        end
      else -- when naledge exist
        -- Cannot use the ewidth in groups_ewidth
        -- Must recalculate the ewidth for panes bounded by naledge and out of the bound of naledge
        -- 4.5.b.1 Calculate the span and the ewidth for panes on the left of each naledge
        local subgroup_ewidths = {}
        for i, nindex in ipairs(sg_naledge) do
          local npanes
          local span_ewidth
          local span
          if i == 1 then
            -- wezterm.log_info("if i == 1 then")
            npanes = nindex - 1
            span = pane_subgroup[nindex].left - 1
          elseif i > 1 then
            -- wezterm.log_info("if i > 1 then")
            npanes = nindex - sg_naledge[i - 1]
            span = pane_subgroup[nindex].left - pane_subgroup[sg_naledge[i - 1]].left
          end
          span_ewidth = math.floor(span / npanes)
          -- wezterm.log_info(
          --   id .. " " .. pane_subgroup_top .. " nindex=" .. nindex .. " npanes=" .. npanes ..
          --   " span=" .. span .. " span_ewidth=" .. span_ewidth
          -- )
          for _ = 1, npanes do
            table.insert(subgroup_ewidths, span_ewidth)
          end
          -- wezterm.log_info(id ..
          --   " " .. pane_subgroup_top .. " subgroup_ewidths={" .. table.concat(subgroup_ewidths, ',') .. "}")
        end

        -- 4.5.b.2 Calculate the span and the ewidth for panes on the right of the last naledge
        if sg_naledge[#sg_naledge] < #sg_panes_id then
          local npanes = #sg_panes_id - sg_naledge[#sg_naledge] + 1
          local sg_last_pane_right_edge_x = pane_subgroup[#pane_subgroup].left +
              pane_subgroup[#pane_subgroup].pane:get_dimensions().cols
          local span = sg_last_pane_right_edge_x - pane_subgroup[sg_naledge[#sg_naledge]].left
          local span_ewidth = math.floor(span / npanes)
          -- wezterm.log_info(
          --   id .. " " .. pane_subgroup_top .. " npanes=" .. npanes ..
          --   " span=" .. span .. " span_ewidth=" .. span_ewidth
          -- )
          for _ = 1, npanes do
            table.insert(subgroup_ewidths, span_ewidth)
          end
        end
        -- wezterm.log_info(id ..
        --   " " .. pane_subgroup_top .. " subgroup_ewidths={" .. table.concat(subgroup_ewidths, ',') .. "}")

        -- 4.5.b.3 Update pane's id-ewidth map
        for j, sg_paneinfo in ipairs(pane_subgroup) do
          if sg_paneinfo.pane:pane_id() == id then
            paneid_ewidth_map[id] = subgroup_ewidths[j]
          end
        end
      end
    end
  end
  -- local elements = {}
  -- for k, v in pairs(paneid_ewidth_map) do
  --   table.insert(elements, k .. ":" .. v)
  -- end
  -- wezterm.log_info(" paneid_ewidth_map={" .. table.concat(elements, ', ') .. "}")
  return paneid_ewidth_map
end


---@param name string Initial of event handler
---@param panes_creation_sequence table[]
---@param win_id string WezTerm's MuxWindow object ID
---@param tab_id string WezTerm's MuxTab object ID
---@return table
local function get_panes_with_children_sequence(name, panes_creation_sequence, win_id, tab_id)
  --[[ Function to return a arraytable of panes ID indicating the panes with children panes according
to following their creation sequence.
]]
  local panes_with_children = {}
  local panes_with_children_sequence = {}
  for _, id in ipairs(panes_creation_sequence) do
    local spi = wezterm.GLOBAL.splitpaneinfo[win_id][tab_id][tostring(id)]
    if spi.children then
      -- wezterm.log_info("#spi.children=" .. #spi.children)
      if #spi.children > 0 then
        local children = convert_weztermGLOBALtable_to_luatable(spi.children)
        panes_with_children[id] = children
        wezterm.log_info(
          "[" .. name .. "]     - " ..
          id .. " children={" .. table.concat(panes_with_children[id], ',') .. "}"
        )
        table.insert(panes_with_children_sequence, id)
      end
    end
  end
  wezterm.log_info(
    "[" .. name .. "]     - panes_with_children_sequence={" ..
    table.concat(panes_with_children_sequence, ',') .. "}"
  )
  return { panes_with_children_sequence, panes_with_children }
end


---@param groupindex number Index of an element of the groups array-table
---@param groups table[] An array-table with array-tables of WezTerm PaneInformation objects.
---@return number[]
local function get_panes_id_of_group(groupindex, groups)
  local panes_id = {}
  for _, paneinfo in ipairs(groups[groupindex]) do
    table.insert(panes_id, paneinfo.pane:pane_id())
  end
  table.sort(panes_id)
  -- wezterm.log_info("[MPANES-EP]     - group " .. groupindex .. ": panes_id={" .. table.concat(panes_id, ',') .. "}")
  return panes_id
end


---@param pane_id number WezTerm's Pane Object ID
---@param groups table[] An array-table with array-tables of WezTerm PaneInformation objects.
---@return number
local function get_group_index_of_pane(pane_id, groups)
  local group_index_of_pane
  for i = 1, #groups do
    local group_panes_id = get_panes_id_of_group(i, groups)
    if contain(group_panes_id, pane_id) then
      group_index_of_pane = i
      break
    end
  end
  return group_index_of_pane
end


---@param group table[] An array-table of WezTerm's PaneInformation objects
---@param groupindex number Index of an element of the groups array-table
---@return number
local function get_group_top_right_pane_id(group, groupindex)
  local pane_id
  if #group == 1 then -- group has only one pane
    pane_id = group[1].pane:pane_id()
    -- wezterm.log_info(
    --   "[MPANES-EP]     - " .. groupindex .. " " .. " #group=" .. #group .. "  top_right_pane_id=" .. pane_id
    -- )
  else -- group has more than 1 pane
    local subgroups = get_subgroups_of_group(group)
    for top, subgroup in pairs(subgroups) do
      if top == 0 then
        pane_id = subgroup[#subgroup].pane:pane_id()
        -- wezterm.log_info(
        --   "[MPANES-EP]     - " .. groupindex .. " " .. " #subgroup=" .. #subgroup .. "  top_right_pane_id=" .. pane_id
        -- )
        break
      end
    end
  end
  return pane_id
end


---@param group table[] An array-table of WezTerm's PaneInformation objects
---@param groupindex number Index of an element of the groups array-table
---@return number
local function get_group_top_left_pane_id(group, groupindex)
  local pane_id
  if #group == 1 then -- group has only one pane
    pane_id = group[1].pane:pane_id()
    -- wezterm.log_info(string.format(
    --   "[MPANES-EP]     - %d #group=%d top_left_pane_id=%d", groupindex, #group, pane_id
    -- ))
  else -- group has more than 1 pane
    local subgroups = get_subgroups_of_group(group)
    for top, subgroup in pairs(subgroups) do
      if top == 0 then
        pane_id = subgroup[1].pane:pane_id()
        -- wezterm.log_info(string.format(
        --   "[MPANES-EP]     - %d #subgroup=%d top_left_pane_id=%d", groupindex, #subgroup, pane_id
        -- ))
        break
      end
    end
  end
  return pane_id
end


---@param name string Initial of event handler
---@param win_id string WezTerm's MuxWindow object ID
---@param tab_id string WezTerm's MuxTab object ID
---@param groups table[] An array-table with array-tables of WezTerm PaneInformation objects.
---@param window any A WezTerm Window object.
---@return number[]
local function get_group_adjust_sequence(name, win_id, tab_id, groups, window)
  --[[This function determines the sequence to adjust the group of panes in groups. It returns an
  array-table of group index.

  How it get this sequence, i.e. the group_adjust_sequence array-table?
  1. It the sequence of pane ID per the creation sequence of all panes in the active tab. This
     sequence is stored as an array-table.
  2. Using this array-table, the panes having children panes are then deduced. An array-table of
     pane id these panes with children panes per creation sequence and a sparse-table of these
     panes with children panes are returned.
  3. Using a for-loop of the array-table of panes_with_children_sequence, the following tasks are
     done to create group_adjust_sequence:
     a. For each of these panes, get the current group of the pane and the vsplitedge of the this
        group's top-left and top right panes.
     b. Get the vsplitedge of the current group's previous group's top-right pane
     c. Get the vsplitedge of the current group's next group's top-left pane
     d. Either store the current group's index or the next-current-previous groups indexes per
        an empirically observed criteria based on the vsplitedge parameters. Once stored, all panes
        of those stored group(s) are stored (i.e. regarded as processed and will not need to be
        processed by the for-loop).
  4. Finally, those groups that are not captured in the previous step are considered next. If these
     group(s) happened to be the first or last group of groups, their index will be inserted to
     the front of group_adjust_sequence. Else all other groups are appended to the end of
     group_adjust_sequence.
  ]]
  wezterm.log_info("[" .. name .. "] - get_group_adjust_sequence")
  -- 1. Get panes_creation_sequence of active tab from wezterm.GLOBAL.splitpaneinfo
  local panes_creation_sequence = get_panes_creation_sequence(win_id, tab_id)
  wezterm.log_info("[" .. name .. "]   - panes_creation_sequence={" .. table.concat(panes_creation_sequence, ',') .. "}")

  -- 2. Get the ID of panes with children panes following their creation sequence
  local sequence = get_panes_with_children_sequence(name, panes_creation_sequence, win_id, tab_id)
  local panes_with_children_sequence = sequence[1] -- array-table
  local panes_with_children = sequence[2]          -- sparse-table

  -- 3. Determine the sequence to adjust each group of groups
  local group_adjust_sequence = {}
  local processed_panes = {}
  local atab = window:active_tab()
  local pane_id_info_map = map_pane_id_to_paneinfo(window)
  for _, id in ipairs(panes_with_children_sequence) do
    if not contain(processed_panes, id) and panes_with_children then
      local children = panes_with_children[id]

      -- GET CURRENT GROUP TOP-LEFT PANE & TOP-RIGHT PANES VSPLITEDGE
      -- Define current group index and the id & vsplitedge of its top-left and top-right panes.
      wezterm.log_info("[" .. name .. "]   - Get vsplitedge of current, previous & next groups using pane:" .. id)
      local cg_index, cg_top_left_pane_id, cg_top_right_pane_id
      if #children == 1 then
        wezterm.log_info("[" .. name .. "]     - Pane:" .. id .. " #children == 1")
        -- Register id if id is in group
        for i = 1, #groups do
          local group_panes_id = get_panes_id_of_group(i, groups)
          if contain(group_panes_id, id) then
            cg_index = i
            break
          end
        end
        cg_top_left_pane_id = id
        cg_top_right_pane_id = id
      else
        wezterm.log_info("[" .. name .. "]     - Pane:" .. id .. " #children > 1")
        cg_index = get_group_index_of_pane(id, groups)
        cg_top_left_pane_id = get_group_top_left_pane_id(groups[cg_index], cg_index)
        cg_top_right_pane_id = get_group_top_right_pane_id(groups[cg_index], cg_index)
      end
      local cg_top_left_pane_vsplitedge =
          wezterm.GLOBAL.splitpaneinfo[win_id][tab_id][tostring(cg_top_left_pane_id)].vsplitedge
      local cg_top_right_pane_vsplitedge =
          wezterm.GLOBAL.splitpaneinfo[win_id][tab_id][tostring(cg_top_right_pane_id)].vsplitedge
      wezterm.log_info(string.format(
        "[%s]     - pane:%d cg=%d  top-left-pane:%d %s  top-right-pane:%d %s",
        name, id, cg_index, cg_top_left_pane_id, cg_top_left_pane_vsplitedge,
        cg_top_right_pane_id, cg_top_right_pane_vsplitedge
      ))
      local cg_top_left_paneinfo = pane_id_info_map[cg_top_left_pane_id]
      local cg_top_right_paneinfo = pane_id_info_map[cg_top_right_pane_id]

      -- GET PREVIOUS GROUP TOP RIGHT PANE VSPLITEDGE
      -- activate group's top left pane
      cg_top_left_paneinfo.pane:activate()
      wezterm.sleep_ms(1)
      -- Get the vsplitedge of left pane that is adjacent to the current group's top left pane.
      -- This is the top right most pane of the previous group of the current group.
      local pg_top_right_pane = atab:get_pane_direction("Left")
      local pg_top_right_pane_vsplitedge
      local pg_top_right_pane_id
      local pg_index
      if pg_top_right_pane then
        pg_top_right_pane_id = pg_top_right_pane:pane_id()
        pg_top_right_pane_vsplitedge =
            wezterm.GLOBAL.splitpaneinfo[win_id][tab_id][tostring(pg_top_right_pane_id)].vsplitedge
        pg_index = get_group_index_of_pane(pg_top_right_pane_id, groups)
        wezterm.log_info(string.format(
          "[%s]     - pane:%d pg=%d  top-right-pane:%d %s",
          name, id, pg_index, pg_top_right_pane_id, pg_top_right_pane_vsplitedge
        ))
      else
        wezterm.log_info("[" .. name .. "]     - pane:" .. id .. " pg=nil")
      end

      -- GET NEXT GROUP TOP LEFT PANE VSPLITEDGE
      -- activate group's top right pane
      cg_top_right_paneinfo.pane:activate()
      wezterm.sleep_ms(1)
      -- Get the vsplitedge of the right pane that is adjacent to the group's top right pane.
      -- This is the top left most pane of the next group of the current group.
      local ng_top_left_pane = atab:get_pane_direction("Right")
      local ng_top_left_pane_vsplitedge
      local ng_top_left_pane_id
      local ng_index
      if ng_top_left_pane then
        ng_top_left_pane_id = ng_top_left_pane:pane_id()
        ng_top_left_pane_vsplitedge =
            wezterm.GLOBAL.splitpaneinfo[win_id][tab_id][tostring(ng_top_left_pane_id)].vsplitedge
        ng_index = get_group_index_of_pane(ng_top_left_pane_id, groups)
        wezterm.log_info(string.format(
          "[%s]     - pane:%d ng=%d  top-left-pane:%d %s",
          name, id, ng_index, ng_top_left_pane_id, ng_top_left_pane_vsplitedge
        ))
      else
        wezterm.log_info("[" .. name .. "]     - pane:" .. id .. " ng:nil")
      end

      -- Criteria to store currentgroup, previousgroup or nextgroup index
      if pg_top_right_pane == nil or                                                                                                          -- 1st group of groups
          ng_top_left_pane == nil or                                                                                                          -- Last group of groups
          (pg_top_right_pane_vsplitedge == "Right" and cg_top_right_pane_vsplitedge == "Right" and ng_top_left_pane_vsplitedge == "Left") or  -- Right Right Left
          (pg_top_right_pane_vsplitedge == "Right" and cg_top_right_pane_vsplitedge == "Right" and ng_top_left_pane_vsplitedge == "Right") or -- Right Right Right
          (pg_top_right_pane_vsplitedge == "Right" and cg_top_right_pane_vsplitedge == "Left" and ng_top_left_pane_vsplitedge == "Right") or  -- Right Right Right
          (pg_top_right_pane_vsplitedge == "Left" and cg_top_right_pane_vsplitedge == "Right" and ng_top_left_pane_vsplitedge == "Right") or  -- Left Right Right
          (pg_top_right_pane_vsplitedge == "Left" and cg_top_right_pane_vsplitedge == "Left" and ng_top_left_pane_vsplitedge == "Left") or    -- Left Left Left
          (pg_top_right_pane_vsplitedge == "Left" and cg_top_right_pane_vsplitedge == "Right" and ng_top_left_pane_vsplitedge == "Left")      -- Left Right Left
      then
        if not contain(group_adjust_sequence, cg_index) then
          wezterm.log_info("[" .. name .. "]     - store current group index")
          table.insert(group_adjust_sequence, cg_index)
          local group_panes_id = get_panes_id_of_group(cg_index, groups)
          for _, pid in ipairs(group_panes_id) do
            table.insert(processed_panes, pid)
          end
        end
      elseif pg_top_right_pane_vsplitedge == "Right" and cg_top_right_pane_vsplitedge == "Left" and ng_top_left_pane_vsplitedge == "Left" then -- Right Left Left
        wezterm.log_info(
          "[" .. name .. "]     - Right Left Left  -- ng_index=" .. ng_index ..
          " cg_index=" .. cg_index .. " pg_index=" .. pg_index
        )
        if not contain(group_adjust_sequence, ng_index) then
          wezterm.log_info("[" .. name .. "]      - store next group index")
          table.insert(group_adjust_sequence, ng_index)
          local group_panes_id = get_panes_id_of_group(ng_index, groups)
          for _, pid in ipairs(group_panes_id) do
            table.insert(processed_panes, pid)
          end
        end
        if not contain(group_adjust_sequence, cg_index) then
          wezterm.log_info("[" .. name .. "]      - store current group index")
          table.insert(group_adjust_sequence, cg_index)
          local group_panes_id = get_panes_id_of_group(cg_index, groups)
          for _, pid in ipairs(group_panes_id) do
            table.insert(processed_panes, pid)
          end
        end
        if not contain(group_adjust_sequence, pg_index) then
          wezterm.log_info("[" .. name .. "]      - store previous group index")
          table.insert(group_adjust_sequence, pg_index)
          local group_panes_id = get_panes_id_of_group(pg_index, groups)
          for _, pid in ipairs(group_panes_id) do
            table.insert(processed_panes, pid)
          end
        end
      else
        wezterm.log_warn(
          "[" .. name ..
          "]      - Detected unanticipated PREVIOUS, CURRENT, NEXT GROUPS vsplitedge combiniation"
        )
      end
    end
  end
  wezterm.log_info("[" .. name .. "]   - a group_adjust_sequence={" .. table.concat(group_adjust_sequence, ',') .. "}")

  -- Includes remaining groups into group_adjust_sequence
  if #group_adjust_sequence ~= #groups then
    for i, _ in ipairs(groups) do
      if not contain(group_adjust_sequence, i) then
        if i == 1 or i == #groups then -- adjust first and last groups first
          table.insert(group_adjust_sequence, 1, i)
        else
          table.insert(group_adjust_sequence, i)
        end
        local group_panes_id = get_panes_id_of_group(i, groups)
        for _, pid in ipairs(group_panes_id) do
          table.insert(processed_panes, pid)
        end
      end
    end
    wezterm.log_info("[" .. name .. "]   - b group_adjust_sequence={" .. table.concat(group_adjust_sequence, ',') .. "}")
  end
  return group_adjust_sequence
end


---@param window any A WezTerm Window object.
---@param ewidth number Equalization width
---@param name string Initial of event handler
local function adjust_right_slit(window, ewidth, name)
  local apane = window:active_pane()
  local id = apane:pane_id()
  local width = apane:get_dimensions().cols
  local diff = width - ewidth
  local win_id = tostring(window:window_id())
  local tab_id = tostring(window:active_tab():tab_id())
  local apane_vsplitedge = wezterm.GLOBAL.splitpaneinfo[win_id][tab_id][tostring(id)].vsplitedge
  wezterm.log_info(
    "[" .. name .. "]   - pane:" .. id .. " ewidth=" .. ewidth .. " width=" .. width ..
    " diff=" .. diff .. " vsplitedge=" .. apane_vsplitedge
  )
  if diff < 0 then -- pane cols is lesser than ewidth
    window:perform_action(act.AdjustPaneSize({ "Right", math.abs(diff) }), apane)
    wezterm.log_info(
      "[" .. name .. "]     - right edge adjusted in the Right direction by " ..
      math.abs(diff) .. " column cells."
    )
  elseif diff > 0 then -- pane cols is greater than ewidth
    window:perform_action(act.AdjustPaneSize({ "Left", math.abs(diff) }), apane)
    wezterm.log_info(
      "[" .. name .. "]     - right edge adjusted in the Left direction by " ..
      math.abs(diff) .. " column cells."
    )
  end
end


---@param window any A WezTerm Window object.
---@param ewidth number Equalization width
---@param name string Initial of event handler
local function adjust_left_slit(window, ewidth, name)
  local apane = window:active_pane()
  local id = apane:pane_id()
  local width = apane:get_dimensions().cols
  local diff = width - ewidth
  local win_id = tostring(window:window_id())
  local tab_id = tostring(window:active_tab():tab_id())
  local apane_vsplitedge = wezterm.GLOBAL.splitpaneinfo[win_id][tab_id][tostring(id)].vsplitedge
  wezterm.log_info(
    "[" .. name .. "]   - pane:" .. id .. " ewidth=" .. ewidth .. " width=" .. width ..
    " diff=" .. diff .. " vsplitedge=" .. apane_vsplitedge
  )
  if diff < 0 then -- pane cols is lesser than ewidth
    window:perform_action(act.AdjustPaneSize({ "Left", math.abs(diff) }), apane)
    wezterm.log_info(
      "[" .. name .. "]     - left edge adjusted in the Left direction by " ..
      math.abs(diff) .. " column cells."
    )
  elseif diff > 0 then -- pane cols is greater than ewidth
    window:perform_action(act.AdjustPaneSize({ "Right", math.abs(diff) }), apane)
    wezterm.log_info(
      "[" .. name .. "]     - left edge adjusted in the Right direction by " ..
      math.abs(diff) .. " column cells."
    )
  end
end


---@param id number WezTerm Pane object ID
---@param window any WezTerm Window object
---@return any|nil
local function get_pane(id, window)
  local pane = nil
  for _, ipane in ipairs(window:active_tab():panes()) do
    if ipane:pane_id() == id then
      pane = ipane
      break
    end
  end
  return pane
end


---@param window any A WezTerm Window object.
---@param win_id string WezTerm's MuxWindow object ID
---@param tab_id string WezTerm's MuxTab object ID
---@param group table[] An array-table of WezTerm's PaneInformation objects
---@param paneid_ewidth_map table A sparse-table of the pane's id and ewidth.
---@param name string Initial of event handler
local function equalize_group_with_one_pane(window, win_id, tab_id, group, paneid_ewidth_map, name)
  -- get pane's info, id, vsplitedge & ewith
  local paneinfo = group[1]
  local pane_id = tostring(paneinfo.pane:pane_id())
  local vsplitedge = wezterm.GLOBAL.splitpaneinfo[win_id][tab_id][pane_id].vsplitedge
  local ewidth = paneid_ewidth_map[tonumber(pane_id)]
  -- Activate pane
  paneinfo.pane:activate()
  wezterm.sleep_ms(10)
  -- adjust pane's vertical edge
  if vsplitedge == "Left" then
    adjust_left_slit(window, ewidth, name)
  elseif vsplitedge == "Right" then
    adjust_right_slit(window, ewidth, name)
  end
end


---@param window any A WezTerm Window object.
---@param win_id string WezTerm's MuxWindow object ID
---@param tab_id string WezTerm's MuxTab object ID
---@param group table[] An array-table of WezTerm's PaneInformation objects
---@param paneid_ewidth_map table A sparse-table of the pane's id and ewidth.
---@param name string Initial of event handler
local function equalize_group_with_multuple_panes(window, win_id, tab_id, group, paneid_ewidth_map, name)
  local subgroups = get_subgroups_of_group(group)
  -- Get pane id of panes in subgroup according to creation sequence
  for _, subgroup in pairs(subgroups) do
    -- Get subgroup's panes id according to creation sequence
    local sg_panes_id = {}
    for _, paneinfo in ipairs(subgroup) do
      local sgp_id = paneinfo.pane:pane_id()
      table.insert(sg_panes_id, sgp_id)
    end
    local sg_panes_id_sorted = { table.unpack(sg_panes_id) }
    table.sort(sg_panes_id_sorted)
    -- wezterm.log_info("sg_panes_id_sorted={" .. table.concat(sg_panes_id_sorted, ',') .. "}")

    -- Get of pane's adjustment sequence for subgroup
    local adjust_sequence = {}
    local sequence = get_panes_with_children_sequence(name, sg_panes_id_sorted, win_id, tab_id)
    for _, id in ipairs(sequence[1]) do
      if id == sg_panes_id[1] or id == sg_panes_id[#sg_panes_id] then
        table.insert(adjust_sequence, 1, id) -- Insert to front of array-table
      else
        table.insert(adjust_sequence, id)    -- Append to rear of array-table
      end
    end
    for _, id in ipairs(sg_panes_id_sorted) do
      if not contain(adjust_sequence, id) then
        table.insert(adjust_sequence, id) -- Append to rear of array-table
      end
    end
    -- wezterm.log_info("adjust_sequence={" .. table.concat(adjust_sequence, ',') .. "}")

    -- Equalize panes in subgroup
    for _, id in ipairs(adjust_sequence) do
      local pane = get_pane(id, window)
      local pane_id = tostring(id)
      local vsplitedge = wezterm.GLOBAL.splitpaneinfo[win_id][tab_id][pane_id].vsplitedge
      local ewidth = paneid_ewidth_map[tonumber(pane_id)]
      pane:activate()
      wezterm.sleep_ms(10)
      if vsplitedge == "Left" then
        adjust_left_slit(window, ewidth, name)
      elseif vsplitedge == "Right" then
        adjust_right_slit(window, ewidth, name)
      end
    end
  end
end


---@param window any A WezTerm Window object.
---@param pane any A WezTerm Pane object
wezterm.on("sb-equalize-panes", function(window, pane)
  --[[ Handler for the sb-equalize-pane event
  1. Get ids of active window and tab
  2. Group panes in active tab from left to right according to column
  3. Get sequence to adjust each pane group
  4. Get group with non_adjustable_left_edge.
  5. Create a sparse-table map of each pane's ID and ther equalization width (i.e. ewidth)
  6. Perform the adjustment of panes according to group_adjust_sequence
  7. Refocus/reactivate original pane
  Note: The presence of non_adjustable_left_edge or naledge are considered at the group and
        subgroup level.
  ]]
  --  1. Get ids of active window and tab
  local name = "MPANES-EP"
  local win_id = tostring(window:window_id())
  local tab_id = tostring(window:active_tab():tab_id())
  wezterm.log_info("[" .. name .. "] 'sb-equalize-panes' event handler activated...")
  wezterm.log_info("[" .. name .. "] Equalize Panes in window:" .. win_id .. " tab:" .. tab_id)

  -- 2. Group panes in active tab from left to right according to their column sequence
  local groups = get_panes_groups(window)
  wezterm.log_info("[" .. name .. "] - #groups = " .. tostring(#groups))

  -- 3. Get sequence to adjust each pane group
  local group_adjust_sequence = get_group_adjust_sequence(name, win_id, tab_id, groups, window)

  -- 4. Get group with non_adjustable_left_edge.
  local gwnaledge = get_group_with_non_adjustable_left_edge(groups, win_id, tab_id)
  wezterm.log_info("[" .. name .. "] - gwnaledge = {" .. table.concat(gwnaledge, ',') .. "}")

  -- 5. Create a sparse-table map of each pane's ID and ther equalization width (i.e. ewidth).
  local paneid_ewidth_map
  if #gwnaledge == 0 then -- group_with_non_adjustable_left_edge is empty
    paneid_ewidth_map = get_pane_equalization_width_map_for_no_naledge(window, groups)
  else                    -- group_with_non_adjustable_left_edge is not empty
    paneid_ewidth_map = get_pane_equalization_width_map_for_naledge(window, groups, gwnaledge)
  end
  local elements = {}
  for k, v in pairs(paneid_ewidth_map) do
    table.insert(elements, k .. ":" .. v)
  end
  wezterm.log_info("[" .. name .. "] - paneid_ewidth_map={" .. table.concat(elements, ',') .. "}")

  -- 6. Equalize panes according to group_adjust_sequence
  for _, index in ipairs(group_adjust_sequence) do
    wezterm.log_info("[" .. name .. "] - group:" .. index .. " has " .. #groups[index] .. " panes(s):")
    if #groups[index] == 1 then    -- group has only 1 pane
      equalize_group_with_one_pane(window, win_id, tab_id, groups[index], paneid_ewidth_map, name)
    elseif #groups[index] > 1 then -- group has multiple panes
      equalize_group_with_multuple_panes(window, win_id, tab_id, groups[index], paneid_ewidth_map, name)
    end
  end

  -- 7. Refocus/reactivate original pane
  pane:activate()
end)


-- Module function to apply to config
---@param config unknown
---@param opts {
---activatepanebyindex_mods: string?,
---activatepanebyindex_key0: string?,
---activatepanebyindex_key1: string?,
---activatepanebyindex_key2: string?,
---activatepanebyindex_key3: string?,
---activatepanebyindex_key4: string?,
---activatepanebyindex_key5: string?,
---activatepanebyindex_key6: string?,
---activatepanebyindex_key7: string?,
---activatepanebyindex_key8: string?,
---activatepanebyindex_key9: string?,
---activatepanedirection_mods: string?,
---activatepanedirection_left_key: string?,
---activatepanedirection_right_key: string?,
---activatepanedirection_up_key: string?,
---activatepanedirection_down_key: string?,
---paneselect_mods: string?,
---paneselect_key: string?,
---paneselect_num_key: string?,
---paneselect_swapwithactive_key: string?,
---adjustpanesize_mods: string?,
---adjustpanesize_left_key: string?,
---adjustpanesize_right_key: string?,
---adjustpanesize_up_key: string?,
---adjustpanesize_down_key: string?,
---splitpane_mods: string?,
---splitpane_left_key: string?,
---splitpane_right_key: string?,
---splitpane_up_key: string?,
---splitpane_down_key: string?,
---rotatepanes_mods: string?,
---rotatepanes_counterclockwise_key: string?,
---rotatepanes_clockwise_key: string?,
---togglepanezoomstate_mods: string?,
---togglepanezoomstate_key: string?,
---closecurrentpane_mods: string?,
---closecurrentpane_key: string?,
---closecurrenttab_mods: string?,
---closecurrenttab_key: string?,
---equalize_panes_mods: string?,
---equalize_panes_key: string?}
function M.apply_to_config(config, opts)
  -- Active pane by index
  local activatepanebyindex_mods = opts.activatepanebyindex_mods or "SHIFT|ALT|CTRL"
  local activatepanebyindex_key0 = opts.activatepanebyindex_key0 or ")"
  local activatepanebyindex_key1 = opts.activatepanebyindex_key1 or "!"
  local activatepanebyindex_key2 = opts.activatepanebyindex_key2 or "@"
  local activatepanebyindex_key3 = opts.activatepanebyindex_key3 or "#"
  local activatepanebyindex_key4 = opts.activatepanebyindex_key4 or "$"
  local activatepanebyindex_key5 = opts.activatepanebyindex_key5 or "%"
  local activatepanebyindex_key6 = opts.activatepanebyindex_key6 or "^"
  local activatepanebyindex_key7 = opts.activatepanebyindex_key7 or "&"
  local activatepanebyindex_key8 = opts.activatepanebyindex_key8 or "*"
  local activatepanebyindex_key9 = opts.activatepanebyindex_key9 or "("
  -- Active adjacent pane on the left, right, above & below
  local activatepanedirection_mods = opts.activatepanedirection_mods or "SHIFT|CTRL"
  local activatepanedirection_left_key = opts.activatepanedirection_left_key or "LeftArrow"
  local activatepanedirection_right_key = opts.activatepanedirection_right_key or "RightArrow"
  local activatepanedirection_up_key = opts.activatepanedirection_up_key or "UpArrow"
  local activatepanedirection_down_key = opts.activatepanedirection_down_key or "DownArrow"
  -- Activate pane via PaneSelect
  local paneselect_mods = opts.paneselect_mods or "LEADER"
  local paneselect_key = opts.paneselect_key or "8"
  local paneselect_num_key = opts.paneselect_num_key or "9"
  local paneselect_swapwithactive_key = opts.paneselect_swapwithactive_key or "0"
  -- Adjust active pane size
  local adjustpanesize_mods = opts.adjustpanesize_mods or "CTRL"
  local adjustpanesize_left_key = opts.adjustpanesize_left_key or "LeftArrow"
  local adjustpanesize_right_key = opts.adjustpanesize_right_key or "RightArrow"
  local adjustpanesize_up_key = opts.adjustpanesize_up_key or "UpArrow"
  local adjustpanesize_down_key = opts.adjustpanesize_down_key or "DownArrow"
  -- Create new pane on the left, right, top and bottom of currect pane
  local splitpane_mods = opts.splitpane_mods or "LEADER"
  local splitpane_left_key = opts.splitpane_left_key or "h"
  local splitpane_right_key = opts.splitpane_right_key or "l"
  local splitpane_up_key = opts.splitpane_up_key or "k"
  local splitpane_down_key = opts.splitpane_down_key or "j"
  -- Rotate pane sequence in a counterclockwise and clockwise manner
  local rotatepanes_mods = opts.rotatepanes_mods or "LEADER"
  local rotatepanes_counterclockwise_key = opts.rotatepanes_counterclockwise_key or "b"
  local rotatepanes_clockwise_key = opts.rotatepanes_clockwise_key or "n"
  -- Zoom in and out of pane
  local togglepanezoomstate_mods = opts.togglepanezoomstate_mods or "LEADER"
  local togglepanezoomstate_key = opts.togglepanezoomstate_key or "z"
  -- Close active pane
  local closecurrentpane_mods = opts.closecurrentpane_mods or "LEADER"
  local closecurrentpane_key = opts.closecurrentpane_key or "c"
  -- Equalize panes in active tab
  local equalize_panes_mods = opts.equalize_panes_mods or "LEADER"
  local equalize_panes_key = opts.equalize_panes_key or "e"

  -- Key bindings
  local keys = {
    -- Activates pane using the specified index
    { key = activatepanebyindex_key0,        mods = activatepanebyindex_mods,   action = act.ActivatePaneByIndex(0) },
    { key = activatepanebyindex_key1,        mods = activatepanebyindex_mods,   action = act.ActivatePaneByIndex(1) },
    { key = activatepanebyindex_key2,        mods = activatepanebyindex_mods,   action = act.ActivatePaneByIndex(2) },
    { key = activatepanebyindex_key3,        mods = activatepanebyindex_mods,   action = act.ActivatePaneByIndex(3) },
    { key = activatepanebyindex_key4,        mods = activatepanebyindex_mods,   action = act.ActivatePaneByIndex(4) },
    { key = activatepanebyindex_key5,        mods = activatepanebyindex_mods,   action = act.ActivatePaneByIndex(5) },
    { key = activatepanebyindex_key6,        mods = activatepanebyindex_mods,   action = act.ActivatePaneByIndex(6) },
    { key = activatepanebyindex_key7,        mods = activatepanebyindex_mods,   action = act.ActivatePaneByIndex(7) },
    { key = activatepanebyindex_key8,        mods = activatepanebyindex_mods,   action = act.ActivatePaneByIndex(8) },
    { key = activatepanebyindex_key9,        mods = activatepanebyindex_mods,   action = act.ActivatePaneByIndex(9) },

    -- Activate an adjacent pane in the specified direction
    { key = activatepanedirection_left_key,  mods = activatepanedirection_mods, action = act.ActivatePaneDirection 'Left', },
    { key = activatepanedirection_right_key, mods = activatepanedirection_mods, action = act.ActivatePaneDirection 'Right', },
    { key = activatepanedirection_up_key,    mods = activatepanedirection_mods, action = act.ActivatePaneDirection 'Up', },
    { key = activatepanedirection_down_key,  mods = activatepanedirection_mods, action = act.ActivatePaneDirection 'Down', },

    -- Activate pane using PaneSelect with default (labels are "a", "s", "d", "f" and so on)
    { key = paneselect_key,                  mods = paneselect_mods,            action = act.PaneSelect },
    -- Activate pane using PaneSelect with numeric labels
    { key = paneselect_num_key,              mods = paneselect_mods,            action = act.PaneSelect { alphabet = '0123456789', }, },
    -- Activate pane using PaneSelect, but have it swap the active and selected panes
    { key = paneselect_swapwithactive_key,   mods = paneselect_mods,            action = act.PaneSelect { mode = 'SwapWithActive', }, },

    -- Adjust active pane size
    { key = adjustpanesize_left_key,         mods = adjustpanesize_mods,        action = act.AdjustPaneSize { 'Left', 1 }, },
    { key = adjustpanesize_right_key,        mods = adjustpanesize_mods,        action = act.AdjustPaneSize { 'Right', 1 }, },
    { key = adjustpanesize_up_key,           mods = adjustpanesize_mods,        action = act.AdjustPaneSize { 'Up', 1 }, },
    { key = adjustpanesize_down_key,         mods = adjustpanesize_mods,        action = act.AdjustPaneSize { 'Down', 1 }, },

    -- Remove default SplitPane keybindings
    { key = "LeftArrow",                     mods = "SHIFT|ALT|CTRL",           action = act.DisableDefaultAssignment },
    { key = "RightArrow",                    mods = "SHIFT|ALT|CTRL",           action = act.DisableDefaultAssignment },
    { key = "UpArrow",                       mods = "SHIFT|ALT|CTRL",           action = act.DisableDefaultAssignment },
    { key = "DownArrow",                     mods = "SHIFT|ALT|CTRL",           action = act.DisableDefaultAssignment },
    -- Remove default SplitVertical(SpawnCommand domain=CurrentPaneDomain) keybindings
    { key = '"',                             mods = "ALT|CTRL",                 action = act.DisableDefaultAssignment },
    { key = '"',                             mods = "SHIFT|ALT|CTRL",           action = act.DisableDefaultAssignment },
    { key = "'",                             mods = "SHIFT|ALT|CTRL",           action = act.DisableDefaultAssignment },
    -- Remove default SplitHorizontal(SpawnCommand domain=CurrentPaneDomain) keybindings
    { key = "5",                             mods = "SHIFT|ALT|CTRL",           action = act.DisableDefaultAssignment },
    { key = "%",                             mods = "ALT|CTRL",                 action = act.DisableDefaultAssignment },
    -- Create new pane on the left, right, top and bottom of the active pane using SplitPane
    -- { key = splitpane_left_key,              mods = splitpane_mods,             action = act.SplitPane { direction = 'Left', size = { Percent = 50 }, }, },
    -- { key = splitpane_right_key,              mods = splitpane_mods,             action = act.SplitPane { direction = 'Right', size = { Percent = 50 }, }, },
    -- { key = splitpane_up_key,                mods = splitpane_mods,             action = act.SplitPane { direction = 'Up', size = { Percent = 50 }, }, },
    -- { key = splitpane_down_key,              mods = splitpane_mods,             action = act.SplitPane { direction = 'Down', size = { Percent = 50 }, }, },
    {
      key = splitpane_left_key,
      mods = splitpane_mods,
      action = wezterm.action_callback(function(window, pane)
        wezterm.emit("sb-splitpane", window, pane, "Left", { Percent = 50 })
      end),
    },
    {
      key = splitpane_right_key,
      mods = splitpane_mods,
      action = wezterm.action_callback(function(window, pane)
        wezterm.emit("sb-splitpane", window, pane, "Right", { Percent = 50 })
      end),
    },
    {
      key = splitpane_up_key,
      mods = splitpane_mods,
      action = wezterm.action_callback(function(window, pane)
        wezterm.emit("sb-splitpane", window, pane, "Up", { Percent = 50 })
      end),
    },
    {
      key = splitpane_down_key,
      mods = splitpane_mods,
      action = wezterm.action_callback(function(window, pane)
        wezterm.emit("sb-splitpane", window, pane, "Down", { Percent = 50 })
      end),
    },

    -- Rotates the sequence of panes within the active tab
    { key = rotatepanes_counterclockwise_key, mods = rotatepanes_mods,         action = act.RotatePanes 'CounterClockwise', },
    { key = rotatepanes_clockwise_key,        mods = rotatepanes_mods,         action = act.RotatePanes 'Clockwise', },

    -- Toggles the zoom state of the active pane.
    { key = togglepanezoomstate_key,          mods = togglepanezoomstate_mods, action = act.TogglePaneZoomState, },
    -- Remove default TogglePaneZoomState keybindings
    { key = "z",                              mods = "SHIFT|CTRL",             action = act.DisableDefaultAssignment },
    { key = "Z",                              mods = "SHIFT|CTRL",             action = act.DisableDefaultAssignment },
    { key = "Z",                              mods = "CTRL",                   action = act.DisableDefaultAssignment },

    -- Close active pane
    -- { key = closecurrentpane_key,             mods = closecurrentpane_mods,    action = act.CloseCurrentPane { confirm = true }, },
    {
      key = closecurrentpane_key,
      mods = closecurrentpane_mods,
      action = wezterm.action_callback(function(window, pane)
        wezterm.emit("sb-closecurrentpane", window, pane, true)
      end),
    },

    -- Equalize the number of column cells in panes
    {
      key = equalize_panes_key,
      mods = equalize_panes_mods,
      action = wezterm.action_callback(function(window, pane)
        wezterm.emit("sb-equalize-panes", window, pane)
      end),
    },
  }

  -- Load keys into config.keys:w
  if not config.keys then
    config.keys = {}
  end
  for _, key in ipairs(keys) do
    table.insert(config.keys, key)
  end
end

return M
