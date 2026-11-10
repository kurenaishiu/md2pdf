local function markerText(block)
  if block.t ~= "Para" then
    return nil
  end

  return pandoc.utils.stringify(block):match("^%s*(.-)%s*$")
end

function Pandoc(document)
  local blocks = document.blocks
  local output = pandoc.List()
  local markerClasses = {
    ["@column-header"] = "column-header-table",
    ["@no-header"] = "no-header-table"
  }

  local index = 1
  while index <= #blocks do
    local className = markerClasses[markerText(blocks[index])]
    local nextBlock = blocks[index + 1]

    if className and nextBlock and nextBlock.t == "Table" then
      output:insert(pandoc.Div({ nextBlock }, pandoc.Attr("", { className })))
      index = index + 2
    else
      output:insert(blocks[index])
      index = index + 1
    end
  end

  document.blocks = output
  return document
end

function Div(div)
  if div.classes:includes("column-header") or div.classes:includes("row-header") then
    div.classes:insert("column-header-table")
  elseif div.classes:includes("no-header") then
    div.classes:insert("no-header-table")
  elseif div.classes:includes("nextpage") then
    div.classes:insert("nextpage-break")
  end
  return div
end
