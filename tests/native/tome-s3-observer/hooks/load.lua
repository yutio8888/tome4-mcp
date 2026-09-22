-- TEST-ONLY explicit opt-in. This addon is loaded only when a test names it
-- (`-Eset_addons={...,"mcp-s3-observer"}`) and is excluded from the product
-- archive (tests/** is never packaged). `ToME:load` fires AFTER
-- modules/tome/load.lua defined /data/talents.lua, so the real T_VAULT action
-- already exists and can be observed in place.
class:bindHook('ToME:load', function()
    -- COORD-HARN-01: the installation line MUST be a valid JSON trace record.
    -- The frozen reader parses EVERY occurrence of the prefix as JSON, so a
    -- plain-text banner would be a parse error. `install()` itself only returns
    -- a plain table; wrap and emit it through the bounded encoder.
    local Trace = require('mod.S3NativeTrace')
    local result = Trace.install()
    Trace.emitRecord(Trace.observer or Trace.newObserver(),
        {kind = 'installation', installed = result.installed == true,
         reason = result.reason, observer = 'tome-s3-observer/v1'})
end)
