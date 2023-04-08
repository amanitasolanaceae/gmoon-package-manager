-- Libraries
local environment = gpm.environment
local paths = gpm.paths
local utils = gpm.utils
local string = string

-- Variables
local ErrorNoHaltWithStack = ErrorNoHaltWithStack
local debug_setfenv = debug.setfenv
local AddCSLuaFile = AddCSLuaFile
local type = type

-- Packages table
local pkgs = gpm.Packages
if type( pkgs ) ~= "table" then
    pkgs = {}; gpm.Packages = pkgs
end

TYPE_PACKAGE = 256

module( "gpm.packages", package.seeall )

-- Get all registered packages
function GetAll()
    return pkgs
end

-- Get one registered package
function Get( packageName )
    return pkgs[ packageName ]
end

function GetMetaData( source )
    if type( source ) == "table" then
        -- Package name, main file & author
        source.name = isstring( source.name ) and source.name or nil
        source.main = isstring( source.main ) and source.main or nil
        source.author = isstring( source.author ) and source.author or nil

        -- Version
        local version = source.version
        if isnumber( version ) then
            source.version = version
        else
            source.version = 1
        end

        -- Realms
        if ( source.client ~= false ) then
            source.client = true
        end

        if ( source.server ~= false ) then
            source.server = true
        end

        return source
    elseif type( source ) == "function" then
        local env = {}
        setfenv( source, env )

        local ok, result = xpcall( source, ErrorNoHaltWithStack )
        if not ok then return end
        result = result or env

        if type( result ) ~= "table" then return end
        result = utils.LowerTableKeys( result )

        if type( result.package ) ~= "table" then
            return GetMetaData( result )
        end

        return GetMetaData( result.package )
    end
end

-- Package Meta
do

    PACKAGE = PACKAGE or {}
    PACKAGE.__index = PACKAGE

    function PACKAGE:GetMetaData()
        return self.metadata
    end

    function PACKAGE:GetName()
        return self.metadata.name
    end

    function PACKAGE:GetVersion()
        return self.metadata.version
    end

    function PACKAGE:GetIdentifier( name )
        local identifier = string.format( "%s@%s", self:GetName(), utils.Version( self:GetVersion() ) )
        if name then
            if isstring( name ) then
                return identifier .. "::" .. name
            end

            return name
        end

        return identifier
    end

    PACKAGE.__tostring = PACKAGE.GetIdentifier

    function PACKAGE:GetEnvironment()
        return self.environment
    end

    function PACKAGE:GetLogger()
        return self.logger
    end

    function PACKAGE:GetResult()
        return self.result
    end

    function PACKAGE:GetFiles()
        return self.files
    end

    function PACKAGE:GetFileList()
        local fileList = {}

        for filePath in pairs( self.files ) do
            fileList[ #fileList + 1 ] = filePath
        end

        return fileList
    end

    function IsPackage( any )
        return getmetatable( any ) == PACKAGE
    end

    list.Set( "GPM - Type Names", TYPE_PACKAGE, "Package" )
    gpm.SetTypeID( TYPE_PACKAGE, IsPackage )

end

function Run( gPackage, func )
    debug_setfenv( func, gPackage:GetEnvironment() )
    return func()
end

function SafeRun( gPackage, func, errorHandler )
    return xpcall( Run, errorHandler, gPackage, func )
end

function FindFilePath( fileName, files )
    if type( fileName ) ~= "string" or type( files ) ~= "table" then return end

    local currentFile = utils.GetCurrentFile()
    if currentFile ~= nil then
        local folder = string.GetPathFromFilename( paths.Localize( currentFile ) )
        if type( folder ) == "string" then
            local path = paths.Join( folder, fileName )
            if files[ path ] then return path end
        end
    end

    return files[ fileName ] and fileName
end

function Initialize( metadata, func, files, parentPackage )
    ArgAssert( metadata, 1, "table" )
    ArgAssert( func, 2, "function" )
    ArgAssert( files, 3, "table" )

    local versions = pkgs[ metadata.name ]
    if versions ~= nil then
        local gPackage = versions[ metadata.version ]
        if IsPackage( gPackage ) then
            if IsPackage( parentPackage ) then
                environment.LinkMetaTables( parentPackage.environment, gPackage.environment )
            end

            return gPackage.result
        end
    end

    -- Measuring package startup time
    local stopwatch = SysTime()

    -- Creating environment for package
    local packageEnv = environment.Create( func )

    if IsPackage( parentPackage ) then
        environment.LinkMetaTables( parentPackage.environment, packageEnv )
    end

    -- Creating package object
    local gPackage = setmetatable( {}, PACKAGE )
    gPackage.environment = packageEnv
    gPackage.metadata = metadata
    gPackage.files = files

    gPackage.logger = gpm.logger.Create( gPackage:GetIdentifier(), metadata.color )

    -- Binding package object to gpm.Package
    environment.SetLinkedTable( packageEnv, "gpm", gpm )

    -- Globals
    table.SetValue( packageEnv, "gpm.Logger", gPackage.logger, true )
    table.SetValue( packageEnv, "gpm.Package", gPackage, true )
    table.SetValue( packageEnv, "_VERSION", metadata.version )
    table.SetValue( packageEnv, "promise", gpm.promise )
    table.SetValue( packageEnv, "TypeID", gpm.TypeID )
    table.SetValue( packageEnv, "type", gpm.type )

    environment.SetValue( packageEnv, "import", function( filePath, async, parentPackage )
        return gpm.Import( filePath, async, parentPackage or gpm.Package )
    end )

    do

        local packages = gpm.packages

        -- Include
        environment.SetValue( packageEnv, "include", function( fileName )
            local path = packages.FindFilePath( fileName, files )

            if path and files[ path ] then
                return packages.Run( gpm.Package, files[ path ] )
            end

            ErrorNoHaltWithStack( "Couldn't include file '" .. tostring( fileName ) .. "' - File not found" )
        end )

        -- AddCSLuaFile
        if SERVER then
            environment.SetValue( packageEnv, "AddCSLuaFile", function( fileName )
                if fileName == nil then fileName = paths.Localize( utils.GetCurrentFile() ) end
                local path = packages.FindFilePath( fileName, files )
                if path then return AddCSLuaFile( path ) end

                ErrorNoHaltWithStack( "Couldn't AddCSLuaFile file '" .. tostring( fileName ) .. "' - File not found" )
            end )
        end

    end

    -- Run
    local ok, result = SafeRun( gPackage, func, ErrorNoHaltWithStack )
    if not ok then
        gpm.Logger:Warn( "Package `%s` failed to load, see above for the reason, it took %.4f seconds.", gPackage, SysTime() - stopwatch )
        return
    end

    -- Saving result to gPackage
    gPackage.result = result

    -- Saving in global table & final log
    gpm.Logger:Info( "Package `%s` was successfully loaded, it took %.4f seconds.", gPackage, SysTime() - stopwatch )

    local packageName = gPackage:GetName()
    pkgs[ packageName ] = pkgs[ packageName ] or {}
    pkgs[ packageName ][ gPackage:GetVersion() ] = gPackage

    return result
end