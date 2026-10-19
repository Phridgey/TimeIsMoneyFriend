module 'aux.core.shortcut'

local T = require 'T'
local aux = require 'aux'
local info = require 'aux.util.info'

do
    local orig = SetItemRef
    _G.SetItemRef = T.vararg-function(arg)
        if arg[3] ~= 'RightButton' or not aux.index(aux.get_tab(), 'CLICK_LINK') or not strfind(arg[1], '^item:%d+') then
            return orig(unpack(arg))
        end
        local item_info = info.item(tonumber(aux.select(3, strfind(arg[1], '^item:(%d+)'))))
        if item_info then
            return aux.get_tab().CLICK_LINK(item_info)
        end
    end
end

do
    local orig = UseContainerItem
    _G.UseContainerItem = T.vararg-function(arg)
        if aux.modified() or not aux.get_tab() then
            return orig(unpack(arg))
        end
        local item_info = info.container_item(arg[1], arg[2])
        if item_info and aux.get_tab().USE_ITEM then
            aux.get_tab().USE_ITEM(item_info)
        end
    end
end

-- Local addition: Shift + left-click an item in your bags while the window is open:
-- on the Search tab it searches for that item, on the Post tab it picks it for posting.
-- Hooks the game's own bag click handler, so it works with any bag addon that uses it
-- (the default bags, Bagshui). With the chat box open, Shift-click still links the item.
do
    local search_tab = require 'aux.tabs.search'
    local filter_util = require 'aux.util.filter'
    function aux.handle.LOAD2()
        local orig = ContainerFrameItemButton_OnClick
        if not orig then return end
        _G.ContainerFrameItemButton_OnClick = function(button, ignore_modifiers)
            if (button == nil or button == 'LeftButton') and not ignore_modifiers
                    and IsShiftKeyDown() and not IsControlKeyDown() and not IsAltKeyDown()
                    and aux.frame and aux.frame:IsVisible() and not CursorHasItem()
                    and not (ChatFrameEditBox and ChatFrameEditBox:IsVisible())
                    and this and this.GetID and this:GetParent() then
                local bag, slot = this:GetParent():GetID(), this:GetID()
                local tab = aux.get_tab()
                if tab and tab.name == 'Post' and tab.USE_ITEM then
                    local item_info = info.container_item(bag, slot)
                    if item_info then
                        tab.USE_ITEM(item_info)
                        return
                    end
                elseif tab and tab.name == 'Search' then
                    local _, _, name = strfind(GetContainerItemLink(bag, slot) or '', '|h%[(.-)%]|h')
                    if name then
                        search_tab.set_filter(filter_util.quote(strlower(name)) .. '/exact')
                        search_tab.execute(nil, false)
                        return
                    end
                end
            end
            return orig(button, ignore_modifiers)
        end
    end
end
