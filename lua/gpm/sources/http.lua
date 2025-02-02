local gpm = gpm

-- Libraries
local package = gpm.package
local promise = promise
local http = gpm.http
local string = string
local gmad = gmad
local fs = gpm.fs
local util = util

-- Variables
local CompileString = CompileString
local table_Merge = table.Merge
local logger = gpm.Logger
local ipairs = ipairs
local pairs = pairs
local pcall = pcall
local type = type

local cacheLifetime = gpm.CacheLifetime
local cacheFolder = gpm.CachePath

module( "gpm.sources.http" )

function CanImport( filePath )
    return string.IsURL( filePath )
end

local allowedExtensions = {
    ["lua"] = true,
    ["zip"] = true,
    ["gma"] = true,
    ["json"] = true
}

Import = promise.Async( function( metadata )
    local url = metadata.import_path
    local extension = string.GetExtensionFromFilename( url )
    if not allowedExtensions[ extension ] then
        local wsid = string.match( url, "steamcommunity%.com/sharedfiles/filedetails/%?id=(%d+)" )
        if wsid ~= nil then
            return gpm.SourceImport( "workshop", wsid )
        end

        local gitHub = string.match( url, "^https?://(github.com/[^/]+/[^/]+)$" )
        if gitHub ~= nil then
            return gpm.SourceImport( "github", gitHub )
        end

        extension = "json"
    end

    -- Local cache
    local cachePath = cacheFolder .. "http_" .. util.MD5( url ) .. "."  .. ( extension == "json" and "gma" or extension ) .. ".dat"
    if fs.IsFile( cachePath, "DATA" ) and fs.Time( cachePath, "DATA" ) > ( 60 * 60 * cacheLifetime:GetInt() ) then
        if extension == "gma" or extension == "json" then
            return gpm.SourceImport( "gma", "data/" .. cachePath )
        elseif extension == "zip" then
            return gpm.SourceImport( "zip", "data/" .. cachePath )
        end

        local ok, result = fs.Compile( cachePath, "DATA" ):SafeAwait()
        if not ok then return promise.Reject( result ) end

        return package.Initialize( package.GetMetadata( metadata ), result )
    end

    -- Downloading
    logger:Info( "[%s] Package '%s' is downloading...", metadata.source, url )
    local ok, result = http.Fetch( url, nil, 120 ):SafeAwait()
    if not ok then return promise.Reject( result ) end

    if result.code ~= 200 then
        return promise.Reject( "invalid response code: " .. result.code )
    end

    -- Processing
    local body = result.body
    if extension ~= "json" then
        local ok, result = fs.AsyncWrite( cachePath, body ):SafeAwait()
        if not ok then
            logger:Warn( "[%s] Cache creation for package '%s' failed, error: %s", metadata.source, url, result )
        end

        if extension == "lua" then
            local ok, result = pcall( CompileString, body, url )
            if not ok then return promise.Reject( result ) end

            return package.Initialize( package.GetMetadata( metadata ), result )
        elseif extension == "gma" or extension == "zip" then
            return gpm.SourceImport( extension, "data/" .. cachePath )
        end

        return promise.Reject( "how you did it?!" )
    end

    local json = util.JSONToTable( body )
    if not json then return promise.Reject( "'.json' file is corrupted" ) end
    package.GetMetadata( table_Merge( metadata, json ) )
    metadata.import_path = url

    local urls = metadata.files
    if type( urls ) ~= "table" then return promise.Reject( "files list is nil ( no links to files ), download canceled" ) end

    metadata.files = nil

    local files = {}
    for filePath, fileURL in pairs( urls ) do
        logger:Debug( "[%s] Package '%s', file '%s' (%s) download has started.", metadata.source, url, filePath, fileURL )

        local ok, result = http.Fetch( fileURL, nil, 120 ):SafeAwait()
        if not ok then return promise.Reject( "file '" .. filePath .. "' download failed, " .. result ) end
        if result.code ~= 200 then return promise.Reject( "file '" .. filePath .. "' download failed, invalid response code: " .. result.code .. "." ) end
        files[ #files + 1 ] = { filePath, result.body }
    end

    if #files == 0 then return promise.Reject( "no files to compile, file list is empty" ) end

    if metadata.mount == false then
        local compiledFiles = {}
        for _, data in ipairs( files ) do
            local ok, result = pcall( CompileString, data[ 2 ], data[ 1 ] )
            if not ok then return promise.Reject( "file '" .. data[ 1 ] .. "' compile failed, " .. result .. "." ) end
            if not result then return promise.Reject( "file '" ..  data[ 1 ] .. "' compile failed, no result." ) end
            compiledFiles[ data[ 1 ] ] = result
        end

        local main = metadata.main
        if type( main ) ~= "string" then
            main = "init.lua"
        end

        local func = package.GetCompiledFile( main, compiledFiles )
        if not func then
            func = package.GetCompiledFile( "main.lua", compiledFiles )
        end

        if not func then
            return promise.Reject( "main file '" .. main .. "' is missing or compilation was failed" )
        end

        return package.Initialize( metadata, func, compiledFiles )
    end

    local gma = gmad.Write( cachePath )
    if not gma then
        return promise.Reject( "cache file '" .. cachePath .. "' construction error, mounting failed" )
    end

    gma:SetTitle( metadata.name )
    gma:SetDescription( util.TableToJSON( metadata ) )

    local author = metadata.author
    if author ~= nil then
        gma:SetAuthor( author )
    end

    for _, data in ipairs( files ) do
        gma:AddFile( data[ 1 ], data[ 2 ] )
    end

    gma:Close()

    return gpm.SourceImport( "gma", "data/" .. cachePath )
end )
