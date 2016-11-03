###
  termap - Terminal Map Viewer
  by Michael Strassburger <codepoet@cpan.org>

  The Console Vector Tile renderer - bäm!
###
x256 = require 'x256'
mercator = new (require('sphericalmercator'))()
tilebelt = require 'tilebelt'
MBTiles = require 'mbtiles'
Promise = require 'bluebird'

Canvas = require './Canvas'
LabelBuffer = require './LabelBuffer'
Styler = require './Styler'
Tile = require './Tile'
utils = require './utils'

module.exports = class Renderer
  cache: {}
  config:
    baseZoom: 4
    fillPolygons: true
    language: 'de'

    labelMargin: 5

    tileSize: 4096
    projectSize: 256

    #"poi_label", "water",
    drawOrder: [
      "admin"
      "building"

      "road"
      "water"
      "road:structure=bridge"

      "place_label"
      "poi_label"
      "housenum_label"
      "country_label"
      "state_label"
    ]

    icons:
      car: "🚗"
      school: "S" #{}"🏫"
      marker: "⭐"
      'art-gallery': "A" #"🎨"
      attraction: "❕"
      stadium: "🏈"
      toilet: "🚽"
      cafe: "☕"
      laundry: "👚"
      bus: "🚌"
      restaurant: "R" #🍛"
      lodging: "B" #🛏"
      'fire-station': "🚒"
      shop: "🛍"
      pharmacy: "💊"
      beer: "H" #"🍺"
      cinema: "C" #"🎦"

    layers:
      housenum_label:
        margin: 3
      poi_label:
        margin: 5
        cluster: true

  isDrawing: false
  lastDrawAt: 0

  labelBuffer: null
  tileSource: null

  constructor: (@output, @tileSource) ->
    @labelBuffer = new LabelBuffer()

  loadStyleFile: (file) ->
    @styler = new Styler file

  setSize: (@width, @height) ->
    @canvas = new Canvas @width, @height

  draw: (center, zoom, rotation) ->
    return Promise.reject() if @isDrawing
    @isDrawing = true

    @notify "rendering..."

    @labelBuffer.clear()

    if color = @styler.styleById['background']?.paint['background-color']
      @canvas.setBackground x256 utils.hex2rgb color

    @canvas.clear()

    # TODO: tiles = @_tilesInBBox @_getBBox()

    Promise
    .resolve @_visibleTiles center, zoom
    .map (tile) => @_getTile tile.xyz, tile
    .then (tiles) =>
      for tile in tiles
        @_renderTile tile.data, zoom, tile.meta.position

      @_writeFrame()

      @isDrawing = false
      @lastDrawAt = Date.now()

  _visibleTiles: (center, zoom) ->
    z = Math.max 0, Math.floor zoom
    xyz = tilebelt.pointToTileFraction center.lon, center.lat, z

    tiles = []
    tileSize = @config.tileSize / @_scaleAtZoom(zoom)
    for y in [Math.floor(xyz[1])-1..Math.floor(xyz[1])+1]
      for x in [Math.floor(xyz[0])-1..Math.floor(xyz[0])+1]
        tile = x: x, y: y, z: z

        position = [
          @width/2-(xyz[0]-tile.x)*tileSize
          @height/2-(xyz[1]-tile.y)*tileSize
        ]

        tile.x %= Math.pow 2, z
        tile.y %= Math.pow 2, z

        if position[0]+tileSize < 0 or
        position[1]+tileSize < 0 or
        position[0]>@width or
        position[1]>@height
          continue

        tiles.push xyz: tile, position: position

    tiles

  _getTile: (tile, meta = {}) ->
    @tileSource
    .getTile tile.z, tile.x, tile.y
    .then (data) =>
      data: data
      meta: meta

  _renderTile: (tile, zoom, position) ->
    @canvas.reset()
    @canvas.translate position[0], position[1]

    scale = @_scaleAtZoom zoom

    box =
      minX: -position[0]*scale
      minY: -position[1]*scale
      maxX: (@width-position[0])*scale
      maxY: (@height-position[1])*scale
    # console.log box
    # process.exit 0

    for layer in @config.drawOrder
      if layer.indexOf(':') isnt -1
        [layer, filter] = layer.split /:/
        [filterField, filterValue] = filter.split /=/
      else
        filter = false

      continue unless tile.layers?[layer]

      if @config.layers[layer]?.minZoom and zoom > @config.layers[layer].minZoom
        continue

      # TODO: reimplement tree based lookup
      #features = tile.layers[layer].tree.search box

      #@notify "rendering #{features.length} #{layer} features.."
      for feature in tile.layers[layer].features
        feature = data: feature
        if not filter or feature.data.properties[filterField] is filterValue
          @_drawFeature layer, feature, scale, zoom

  _writeFrame: ->
    unless @lastDrawAt
      @_clearScreen()

    @output.write "\x1B[?6h"
    @output.write @canvas.frame()

  featuresAt: (x, y) ->
    @labelBuffer.featuresAt x, y

  _tilesInBBox: (bbox, zoom) ->
    tiles = {}
    [tiles.minX, tiles.minY] = utils.ll2tile bbox[0], bbox[1], Math.floor zoom
    [tiles.maxX, tiles.maxY] = utils.ll2tile bbox[2], bbox[3], Math.floor zoom
    tiles

  _clearScreen: ->
    @output.write "\x1B[2J"

  _write: (output) ->
    @output.write output

  _scaleAtZoom: (zoom) ->
    baseZoom = Math.floor Math.max 0, zoom
    (@config.tileSize/@config.projectSize)/Math.pow(2, zoom-baseZoom)

  _drawFeature: (layer, data, scale, zoom) ->
    feature = data.data

    # TODO: this is ugly :) need to be fixed @style
    #return false if feature.properties.class is "ferry"
    feature.type = "LineString" if layer is "building" or layer is "road"

    # TODO: zoom level
    unless style = @styler.getStyleFor layer, feature, 19-zoom
      return false

    toDraw = (@_scaleAndReduce points, scale for points in feature.points)

    color = style.paint['line-color'] or style.paint['fill-color'] or style.paint['text-color']

    # TODO: zoom calculation todo for perfect styling
    if color instanceof Object
      color = color.stops[0][1]

    colorCode = x256 utils.hex2rgb color

    switch feature.type
      when "LineString"
        width = style.paint['line-width']?.base*1.4 or 1
        @canvas.polyline points, colorCode, width for points in toDraw

      when "Polygon"
        @canvas.polygon toDraw, colorCode

      when "Point"
        text = feature.properties["name_"+@config.language] or
          feature.properties["name"] or
          feature.properties.house_num or
          #@config.icons[feature.properties.maki] or
          "◉"

        # TODO: check in definition if points can actually own multiple geometries
        for points in toDraw
          for point in points
            x = point[0] - text.length
            margin = @config.layers[layer]?.margin or @config.labelMargin

            if @labelBuffer.writeIfPossible text, x, point[1], feature, margin
              @canvas.text text, x, point[1], colorCode
            else if @config.layers[layer]?.cluster and @labelBuffer.writeIfPossible "X", point[0], point[1], feature, 3
              @canvas.text "◉", point[0], point[1], colorCode

  _scaleAndReduce: (points, scale) ->
    lastX = null
    lastY = null
    scaled = []

    for point in points
      x = Math.floor point.x/scale
      y = Math.floor point.y/scale

      if lastX isnt x or lastY isnt y
        lastY = y
        lastX = x
        scaled.push [x, y]

    scaled


  notify: (text) ->
    @_write "\r\x1B[K"+text
