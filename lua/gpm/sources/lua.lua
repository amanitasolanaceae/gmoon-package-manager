-- Libraries
local packages = gpm.packages
local promise = gpm.promise
local paths = gpm.paths
local string = string
local fs = gpm.fs

-- Variables
local CLIENT, SERVER = CLIENT, SERVER
local AddCSLuaFile = AddCSLuaFile
local setmetatable = setmetatable
local CompileFile = CompileFile
local luaRealm = gpm.LuaRealm
local logger = gpm.Logger
local ipairs = ipairs
local rawset = rawset
local pcall = pcall
local type = type

module( "gpm.sources.lua" )

function CanImport( filePath )
    return fs.Exists( filePath, luaRealm ) and string.EndsWith( filePath, ".lua" ) or fs.IsDir( filePath, luaRealm )
end

Files = setmetatable( {}, {
    ["__index"] = function( self, filePath )
        if type( filePath ) == "string" and string.EndsWith( filePath, ".lua" ) and fs.Exists( filePath, luaRealm ) then
            local ok, result = pcall( CompileFile, filePath )
            if ok then
                rawset( self, filePath, result )
                return result
            end
        end

        rawset( self, filePath, false )
        return false
    end
} )

Import = promise.Async( function( filePath, parentPackage, isAutorun )
    local packagePath = paths.Fix( filePath )

    local packageFilePath = packagePath

    local packagePathIsLuaFile = string.EndsWith( packagePath, ".lua" )
    if packagePathIsLuaFile then
        packagePath = string.GetPathFromFilename( packageFilePath )
    else
        packageFilePath = paths.Join( packagePath, "package.lua" )
    end

    local packageFile, metadata = Files[ packageFilePath ], nil
    if packageFile then
        metadata = packages.GetMetadata( packageFile )

        if not metadata then
            if not packagePathIsLuaFile then
                return promise.Reject( "package file is empty or does not exist (" .. packageFilePath .. ")" )
            end

            metadata = packages.GetMetadata( {
                ["name"] = string.match( filePath, "/(.+)%.lua" ),
                ["main"] = packageFilePath,
                ["autorun"] = true
            } )
        end
    else
        metadata = packages.GetMetadata( {
            ["name"] = string.match( filePath, "/(.+)%.lua" ),
            ["autorun"] = true
        } )
    end

    if SERVER and metadata.client and fs.Exists( packageFilePath, luaRealm ) then
        AddCSLuaFile( packageFilePath )
    end

    if CLIENT and not metadata.client then return end
    if not metadata.name then metadata.name = string.GetFileFromFilename( packagePath ) end

    local mainFile = metadata.main
    if not mainFile then
        mainFile = paths.Join( packagePath, "init.lua" )
    end

    local func = Files[ mainFile ]
    if not func then
        mainFile = paths.Join( packagePath, mainFile )
        func = Files[ mainFile ]
    end

    -- Legacy packages support
    if not func then
        mainFile = paths.Join( packagePath, "main.lua" )
        func = Files[ mainFile ]
    end

    if not func then
        return promise.Reject( "main file is missing (" .. metadata.name .. "@" .. metadata.version .. ")" )
    end

    if SERVER then
        if metadata.client then
            AddCSLuaFile( mainFile )

            local send = metadata.send
            if send ~= nil then
                for _, filePath in ipairs( send ) do
                    if not fs.Exists( filePath, luaRealm ) then
                        filePath = paths.Join( packagePath, filePath )
                    end

                    if fs.Exists( filePath, luaRealm ) then
                        AddCSLuaFile( filePath )
                    end
                end
            end
        end

        if not metadata.server then return end
    end

    if isAutorun and not metadata.autorun then
        logger:Debug( "package autorun restricted (%s)", metadata.name .. "@" .. metadata.version )
        return
    end

    return packages.Initialize( metadata, func, Files, parentPackage )
end )