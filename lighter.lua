local vector = require 'libs.vector-light'
local Class = require 'libs.humpclass'
local shash = require 'libs.shash'

local defaultGradientImage = love.graphics.newImage('media/default_light.png')

local angleSortFunc = function(a, b)
  return a.angle < b.angle
end

local function getLineIntersectionPoint(Ax1, Ay1, Ax2, Ay2, Bx1, By1, Bx2, By2)
  local intersectX, intersectY
  local s1x, s1y = vector.sub(Ax2, Ay2, Ax1, Ay1)
  local s2x, s2y = vector.sub(Bx2, By2, Bx1, By1)

  local b = (-s2x * s1y + s1x * s2y)
  local s = ( -s1y * (Ax1 - Bx1) + s1x * (Ay1 - By1)) / b
  local t = ( s2x * (Ay1 - By1) - s2y * (Ax1 - Bx1)) / b

  -- There was an intersection
  if s >= 0 and s <= 1 and t >= 0 and t <= 1 then
    intersectX = Ax1 + (t * s1x)
    intersectY = Ay1 + (t * s1y)
  end

  return intersectX, intersectY
end

-- Warning: Mutates "polygons" (for optimization), adding the required
-- "surround polygon" at the end of it
local function calculateVisibilityPolygon(originX, originY, radius, polygons)
  local visibilityPolygon = {}

  local allPolygons = {}
  for _, polygon in ipairs(polygons) do
    table.insert(allPolygons, polygon)
  end

  -- Required for the lines to always have something to intersect
  local halfRadius = radius / 2
  local surroundPolygon = {
    originX - halfRadius, originY - halfRadius,
    originX + halfRadius, originY - halfRadius,
    originX + halfRadius, originY + halfRadius,
    originX - halfRadius, originY + halfRadius,
    originX - halfRadius, originY - halfRadius
  }

  table.insert(allPolygons, surroundPolygon)

  for _, polygon in ipairs(allPolygons) do
    -- Go through all points (x,y)
    for i=1,#polygon-2,2 do
      local x = polygon[i]
      local y = polygon[i+1]
      local a1, a2 = vector.sub(x, y, originX, originY)
      local angleA = math.atan2(a2, a1)
      local angleB = angleA + 0.0001
      local angleC = angleA - 0.0001

      -- Go through all 3 angles as rays cast from originX, originY
      for j=1,3 do
        local angle
        if j == 1 then angle = angleA end
        if j == 2 then angle = angleB end
        if j == 3 then angle = angleC end


        -- The ray we cast is originX, originY, rayX2, rayY2
        -- rayX2, rayY2 are origin + angle*radius
        local dirX, dirY = math.cos(angle), math.sin(angle)
        local rayX2, rayY2 = vector.add(originX, originY, vector.mul(radius, vector.normalize(dirX, dirY)))

        -- Next up we find the shortest intersection point for each ray.
        -- We store the shortest so far in the min* variables defined below
        local minX, minY, minAngle
        local minLength = math.huge
        local found = false

        -- Go through all the points as line segments (x1,y1,x2,y2).
        -- See where the ray intersects (if it does at all) with the line
        -- segment. If it does, check if it's the shortest length from
        -- origin so far. If it is, then that's the point we want to store
        -- in visibilityPolygon
        for _, polygon2 in ipairs(allPolygons) do
          for u=1,#polygon2-2,2 do
            local segmentX1 = polygon2[u]
            local segmentY1 = polygon2[u+1]
            local segmentX2 = polygon2[u+2]
            local segmentY2 = polygon2[u+3]

            -- Now check for actual intersection between
            -- the ray cast from the origin point and the line segment.
            local intersectX, intersectY = getLineIntersectionPoint(
            originX, originY, rayX2, rayY2,
            segmentX1, segmentY1, segmentX2, segmentY2
            )

            if intersectX and intersectY then
              local length = vector.len2(vector.sub(intersectX, intersectY, originX, originY))
              if length < minLength then
                minX, minY, minAngle = intersectX, intersectY, angle
                minLength = length
                found = true
              end
            end
          end
        end

        if found then
          table.insert(visibilityPolygon, {
            x = minX, y = minY, angle = minAngle
          })
        end
      end
    end
  end

  table.sort(visibilityPolygon, angleSortFunc)
  return visibilityPolygon
end

local function getPolygonBoundingBox(polygon)
  local minX, minY = math.huge, math.huge
  local maxX, maxY = -math.huge, -math.huge

  for i=1,#polygon-1,2 do
    local x = polygon[i]
    local y = polygon[i+1]
    if x > maxX then maxX = x end
    if x < minX then minX = x end
    if y > maxY then maxY = y end
    if y < minY then minY = y end
  end

  return minX, minY, maxX - minX, maxY - minY
end

local function getLightBoundingBox(light)
  local halfRadius = light.radius/2
  return light.x - halfRadius, light.y - halfRadius, light.radius, light.radius
end

local function updateLight(self, light)
  self.lightHash:update(light, getLightBoundingBox(light))
  local polygons = {}

  local x,y,w,h = getLightBoundingBox(light)
  -- Get polygons only within the reach of the light
  self.polygonHash:each(x,y,w,h, function(polygon)
    table.insert(polygons, polygon)
  end)

  local visibilityPolygon = calculateVisibilityPolygon(light.x, light.y, light.radius, polygons)
  self.visibilityPolygons[light] = visibilityPolygon
  self.stencilFunctions[light] = function()
    self:drawVisibilityPolygon(light)
  end
end

local Lighter = Class{
  init = function(self)
    self.polygonHash = shash.new()
    self.lightHash = shash.new()
    self.lights = {}
    self.polygons = {}
    self.visibilityPolygons = {}
    self.stencilFunctions = {}
  end,
  addLight = function(self, x, y, radius, r, g, b, a, gradientImage)
    local light = {
      x = x, y = y, radius = radius,
      r = r or 1, g = g or 1, b = b or 1, a = a or 1,
      gradientImage = gradientImage or defaultGradientImage
    }
    table.insert(self.lights, light)
    self.lightHash:add(light, getLightBoundingBox(light))
    updateLight(self, light)

    return light
  end,
  updateLight = function(self, light, x, y, radius, r, g, b, a, gradientImage)
    light.x = x or light.x
    light.y = y or light.y
    light.radius = radius or light.radius
    light.r = r or light.r
    light.g = g or light.g
    light.b = b or light.b
    light.a = a or light.a
    light.gradientImage = gradientImage or light.gradientImage

    updateLight(self, light)
  end,
  removeLight = function(self, light)
    for i, existingLight in ipairs(self.lights) do
      if existingLight == light then
        table.remove(i)
        self.lightHash:remove(light)
        return
      end
    end
  end,
  addPolygon = function(self, polygon)
    table.insert(self.polygons, polygon)
    self.polygonHash:add(polygon, getPolygonBoundingBox(polygon))

    local x, y, w, h = getPolygonBoundingBox(polygon)
    self.lightHash:each(x, y, w, h, function(light)
      updateLight(self, light)
    end)
  end,
  removePolygon = function(self, polygon)
    local x, y, w, h = getPolygonBoundingBox(polygon)
    for i, existingPolygon in ipairs(self.polygons) do
      if existingPolygon == polygon then
        table.remove(i)
        self.polygonHash:remove(polygon)
        goto continue
      end
    end

    ::continue::

    self.lightHash:each(x, y, w, h, function(light)
      updateLight(self, light)
    end)
  end,
  drawVisibilityPolygon = function(self, light)
    local x, y, _ = light.x, light.y, light.radius
    local visibilityPolygon = self.visibilityPolygons[light]
    if #visibilityPolygon == 0 then return end

    love.graphics.setColor(1,1,1)

    for i=1,#visibilityPolygon-1 do
      local point1 = visibilityPolygon[i]
      local point2 = visibilityPolygon[i+1]
      love.graphics.polygon('fill', {
        x, y,
        point1.x, point1.y,
        point2.x, point2.y
      })
    end

    local firstPoint = visibilityPolygon[1]
    local lastPoint = visibilityPolygon[#visibilityPolygon]
    love.graphics.polygon('fill', {
      x, y,
      lastPoint.x, lastPoint.y,
      firstPoint.x, firstPoint.y
    })
  end,
  drawLights = function(self)
    for _, light in ipairs(self.lights) do
      love.graphics.stencil(self.stencilFunctions[light], "replace", 1)
      love.graphics.setStencilTest("greater", 0)
      local w, h = light.gradientImage:getDimensions()
      local scale = light.radius / w
      love.graphics.setColor(light.r, light.g, light.b, light.a)
      love.graphics.draw(light.gradientImage, light.x, light.y, 0, scale, scale, w/2, h/2)
      love.graphics.setStencilTest()
    end
  end
}

return Lighter
