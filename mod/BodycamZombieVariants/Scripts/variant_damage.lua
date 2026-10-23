-- Current firearm path: edit the pure bone calculation OUT value before the
-- caller constructs GE_WeaponDamage; observe its native GAS pre-apply boundary.
local M={}
local FIRE='/Game/BodycamCore/AbilitySystem/Abilities/Weapons/Fire/GA_Fire_Base.GA_Fire_Base_C'
local BONE=FIRE..':GetBoneDamageMultiplier'
local APPLY='/Script/GameplayAbilities.GameplayAbility:K2_ApplyGameplayEffectSpecToTarget'
local COMPONENT_APPLY='/Script/GameplayAbilities.AbilitySystemComponent:BP_ApplyGameplayEffectSpecToTarget'
local ASSIGN='/Script/GameplayAbilities.AbilitySystemBlueprintLibrary:AssignTagSetByCallerMagnitude'
local WEAPON='/Game/BodycamCore/AbilitySystem/GameplayEffects/GE_WeaponDamage.GE_WeaponDamage_C'
local KNIFE='/Game/BodycamCore/AbilitySystem/GameplayEffects/Knifes/GE_Knife_Damage.GE_Knife_Damage_C'
local GRENADE='/Game/BodycamCore/AbilitySystem/GameplayEffects/Grenades/GE_Grenade_Damage.GE_Grenade_Damage_C'
local LIB='/Script/GameplayAbilities.Default__AbilitySystemBlueprintLibrary'
local BODYLIB='/Script/Bodycam.Default__BodycamAbilitySystemLibrary'
local RETURN_METHODS={'GetEffectContext','EffectContextGetHitResult','AbilityTargetDataFromHitResult','CloneSpecHandle'}
local RETURN_ROOT='/Script/GameplayAbilities.AbilitySystemBlueprintLibrary:'
M.BONE_PATH=BONE;M.APPLY_PATH=APPLY;M.COMPONENT_APPLY_PATH=COMPONENT_APPLY;M.ASSIGN_PATH=ASSIGN
M.RETURN_PATHS={};for _,method in ipairs(RETURN_METHODS)do M.RETURN_PATHS[method]=RETURN_ROOT..method end
local function get(o,k)if o~=nil then local ok,v=pcall(function()return o[k]end);if ok then return v end end end
local function call(o,k,...)
    if o==nil then return false end
    local args=table.pack(...);local f=get(o,k)
    if f~=nil then return pcall(f,o,table.unpack(args,1,args.n))end
    local ok,mt=pcall(getmetatable,o);f=ok and type(mt)=='table'and rawget(mt,k)
    if type(f)=='function'then return pcall(f,o,table.unpack(args,1,args.n))end
    return false
end
local function unwrap(v)local ok,o=call(v,'get');if ok then return o end;return v end
local function finite(n)return type(n)=='number'and n==n and n~=math.huge and n~=-math.huge end
local function string_value(v)
    v=unwrap(v);if type(v)=='string'then return v end
    local ok,s=call(v,'ToString');return ok and type(s)=='string'and s or nil
end
local function bone_name(v)
    local s=string_value(v);if not s or s==''or s:lower()=='none'then return nil end;return s:lower()
end
function M.new(runtime,api,options)
    assert(type(runtime)=='table','Runtime is required')
    api,options=api or {},options or {}
    local self={};local hooks={};local active=false;local token=0;local cleanup_failed=false
    local pending={};local radial={};local return_frames={};local world_key;local generation;local multiplier_tag
    local info={ready=false,body_factor=1.0,head_factor=1.0,damage_pre_apply=false,
        native_original_instigator=true,native_damage_replication_verified=false,
        body_scaled=0,head_preserved=0,gas_hits=0,body_rush_events=0,errors=0,knife_scaled=0,grenade_scaled=0,
        startup_attempts=0,startup_failures=0,startup_phase='idle',native_returns_observed=0,
        method='calculation_out_and_native_inputs_before_gas_commit',coverage='GA_Fire_Base firearms, native knife hits, grenade radial falloff'}
    local function startup_failure(phase,message)
        info.ready=false;info.damage_pre_apply=false;info.startup_phase=phase
        info.startup_failures=info.startup_failures+1
        info.startup_error=tostring(message):sub(1,360);info.last_error=info.startup_error
        -- Menu classes can become available on a subsequent tick. Preserve the
        -- reason for readiness reporting without latching a runtime-hit failure.
        return false,info.startup_error
    end
    local function report_error(message)
        info.errors=info.errors+1;info.last_error=tostring(message):sub(1,220)
        if options.on_error then pcall(options.on_error,info.last_error)end
    end
    local function live(o)return o~=nil and runtime.live(o)==true end
    local function find(path)return runtime.find(path)end
    local function libcall(path,method,...)
        return call(find(path),method,...)
    end
    -- Normal UFunction returns use GetNonTrivialLocal in this UE4SS build.
    -- Opaque GAS handles then become tables without their native shared pointer.
    -- A native post hook exposes GetParam instead. Consume that borrowed return
    -- synchronously while its native frame is alive; never return or retain it.
    local function with_return(method,consume,...)
        local frames=return_frames[method]or {};return_frames[method]=frames
        if #frames>=16 then return false,'Native return continuation depth exceeded: '..method end
        local frame={consume=consume};frames[#frames+1]=frame
        local ok,reason=libcall(LIB,method,...)
        frames[#frames]=nil;frame.consume=nil
        if not ok then return false,'Native return call failed: '..method..' | '..tostring(reason)end
        if not frame.delivered then return false,'Native return observer was not delivered: '..method end
        if frame.error then return false,frame.error end
        return true
    end
    local function on_native_return(method,result)
        local frames=return_frames[method];local frame=frames and frames[#frames]
        if not frame or frame.delivered then return end
        frame.delivered=true
        info.native_returns_observed=info.native_returns_observed+1
        local read,value=call(result,'get')
        if not read or value==nil then frame.error='Native return parameter unavailable: '..method;return end
        local ok,reason=pcall(frame.consume,value)
        if not ok then frame.error='Native return continuation failed: '..method..' | '..tostring(reason)end
    end
    local function context()
        local c
        if options.get_context then c=options.get_context()else c=runtime.context()end
        if not c or c.authority~=true or not live(c.world)then return nil end
        local id=c.world_key or c.world_id
        if type(id)~='string'or not finite(c.generation)then return nil end
        if world_key~=id or generation~=c.generation then
            pending={};radial={};world_key=id;generation=c.generation
        end
        return c
    end
    local function owned(actor,c)
        if not live(actor)or not runtime.belongs(actor,c.world)or runtime.is_owned_zombie(actor)~=true then return nil end
        local ok,authority=call(actor,'HasAuthority');if not ok or authority~=true then return nil end
        return runtime.owned_id(actor)
    end
    local function actor_for_component(component,c)
        if not live(component)then return nil end
        local ok,actor=call(component,'GetOwner');if not ok or not owned(actor,c)then return nil end
        -- The exact component passed by the actual firearm target, not a nearby pawn.
        if runtime.key(get(actor,'WW_RagdollSystem'))~=runtime.key(component)then return nil end
        return actor
    end
    local function on_bone(ability_arg,bone_arg,disable_headshot,ragdoll_arg,out_multiplier)
        if not active then return end
        local c=context();if not c then return end
        local ability=unwrap(ability_arg);if not live(ability)then return end
        local actor=actor_for_component(unwrap(ragdoll_arg),c);if not actor then return end
        local bone=bone_name(bone_arg);local original=unwrap(out_multiplier)
        if not bone or not finite(original)or original<0 then report_error('Invalid native bone calculation output');return end
        local factor=bone=='head'and 1.0 or 1.0
        if bone~='head'then
            local changed=call(out_multiplier,'set',original*factor)
            local actual=unwrap(out_multiplier)
            if not changed or not finite(actual)or math.abs(actual-original*factor)>1e-9 then
                report_error('Native bone calculation OUT value could not be changed');return
            end
            info.body_scaled=info.body_scaled+1
        else info.head_preserved=info.head_preserved+1 end
        local ability_id=runtime.key(ability);local target_id=owned(actor,c)
        if ability_id and target_id then
            -- A single synchronous ProcessHitEvent computes then applies this
            -- value. The native pre-hook consumes it; no UObjects are retained.
            local count=0;for _ in pairs(pending)do count=count+1 end
            if count>=256 and not pending[ability_id]then pending={} end
            pending[ability_id]={zombie_id=target_id,bone=bone,factor=factor,
                world_key=world_key,generation=generation}
        end
    end
    local function single_target(data)
        local ok,n=libcall(LIB,'GetDataCountFromTargetData',data)
        if not ok or n~=1 then return nil end
        local got,actors=libcall(LIB,'GetActorsFromTargetData',data,0)
        if not got then return nil end
        if type(actors)=='table'and get(actors,'GetArrayNum')==nil then
            -- Returned arrays are Lua tables of element parameter wrappers.
            -- Reject holes/extra entries instead of relying on ambiguous # length.
            local first=rawget(actors,1);if first==nil then return nil end
            for index in pairs(actors)do if index~=1 then return nil end end
            return unwrap(first)
        end
        local counted,count=call(actors,'GetArrayNum')
        if not counted or count~=1 then return nil end
        local actor;local visited=0
        local read=call(actors,'ForEach',function(_,v)visited=visited+1;actor=unwrap(v)end)
        if not read or visited~=1 then return nil end
        return actor
    end
    local function effect_class(spec)
        local typed,class=libcall(BODYLIB,'GetSpecHandleClass',spec)
        if not typed or not live(class)then return nil end
        local named,name=call(class,'GetFullName')
        return named and name or nil
    end
    local function with_context_hit(spec,consume)
        return with_return('GetEffectContext',function(ctx)
            local got,why=with_return('EffectContextGetHitResult',function(hit)
                local made,reason=with_return('AbilityTargetDataFromHitResult',function(data)
                    consume(single_target(data),bone_name(get(hit,'BoneName')),ctx,hit)
                end,hit)
                if not made then error(reason)end
            end,ctx)
            if not got then error(why)end
        end,spec)
    end
    local function emit_with_instigator(id,bone,c,instigator,source)
        info.gas_hits=info.gas_hits+1
        if options.on_interaction then
            local delivered,err=pcall(options.on_interaction,{zombie_id=id,hit_bone=bone,
                world_key=world_key,generation=generation})
            if not delivered then report_error('Hit interaction callback: '..tostring(err))end
        end
        if bone=='head'then return end
        local player=live(instigator)and runtime.resolve_player(instigator)or nil
        if player and(player.alive~=true or not live(player.pawn)or not runtime.belongs(player.pawn,c.world)
            or get(get(player.pawn,'WW_SurvivorStatus'),'Death?')==true)then player=nil end
        if player then
            local controller=player.controller
            -- Controller exposes K2_GetPawn to reflection; GetPawn is only
            -- reflected on PlayerState in this exact installed build.
            local linked,pawn=call(controller,'K2_GetPawn')
            local controlled,pc=call(player.pawn,'GetController')
            local actual=runtime.key(instigator)
            if not live(controller)or not runtime.belongs(controller,c.world)
                or not linked or runtime.key(pawn)~=runtime.key(player.pawn)
                or not controlled or runtime.key(pc)~=runtime.key(controller)
                or(actual~=runtime.key(player.pawn)and actual~=runtime.key(controller))then player=nil end
        end
        local event={zombie_id=id,hit_bone=bone,world_key=world_key,generation=generation,
            shooter_key=player and player.key or nil,shooter_life=player and player.life or nil,
            native_original_instigator=true,source=source}
        if options.on_body_hit then
            local delivered,err=pcall(options.on_body_hit,event)
            if not delivered then report_error('Body-hit callback: '..tostring(err))else info.body_rush_events=info.body_rush_events+1 end
        end
    end
    local function emit_hit(id,bone,c,spec,source)
        if bone=='head'then emit_with_instigator(id,bone,c,nil,source);return end
        local ok,why=with_return('GetEffectContext',function(ctx)
            local resolved,instigator=libcall(LIB,'EffectContextGetOriginalInstigatorActor',ctx)
            if not resolved then error('Native original instigator query failed')end
            emit_with_instigator(id,bone,c,instigator,source)
        end,spec)
        if not ok then report_error(why)end
    end
    local function on_apply(ability_arg,spec_arg,target_arg)
        if not active then return end
        local c=context();if not c then return end
        local ability=unwrap(ability_arg);if not live(ability)then return end
        local ability_id=runtime.key(ability);local calculated=ability_id and pending[ability_id]
        if ability_id then pending[ability_id]=nil end
        local spec,data=unwrap(spec_arg),unwrap(target_arg)
        if effect_class(spec)~='BlueprintGeneratedClass '..WEAPON then return end
        local actor=single_target(data);local id=owned(actor,c);if not id then return end
        local got,hit=libcall(LIB,'GetHitResultFromTargetData',data,0)
        local bone=got and bone_name(get(hit,'BoneName'))or nil
        if not bone then report_error('Native firearm target data lacks a real hit bone');return end
        if not calculated or calculated.zombie_id~=id or calculated.bone~=bone
            or calculated.world_key~=world_key or calculated.generation~=generation then
            report_error('Native firearm application lacks its matching scaled calculation');return
        end
        emit_hit(id,bone,c,spec,APPLY)
        -- No return override: the same native effect applies and replicates health.
    end
    local function on_assign(_,spec_arg,tag_arg,magnitude_arg)
        if not active then return end
        local c=context();if not c then return end
        local spec=unwrap(spec_arg)
        if effect_class(spec)~='BlueprintGeneratedClass '..GRENADE
            or string_value(get(unwrap(tag_arg),'TagName'))~='SetByCaller.DamageMultiplier'then return end
        local matched,why=with_context_hit(spec,function(actor,bone,ctx)
            local id=owned(actor,c);if not id then return end
            -- Current BFL_Explosion explicitly creates this per-target radial body hit.
            if bone~='spine_03'then error('Grenade context differs from the verified radial body path')end
            local amount=unwrap(magnitude_arg)
            if not finite(amount)or amount<0 then error('Invalid native grenade falloff magnitude')end
            local changed=call(magnitude_arg,'set',amount*1.0);local actual=unwrap(magnitude_arg)
            if not changed or not finite(actual)or math.abs(actual-amount*1.0)>math.max(1,math.abs(amount*1.0))*1e-6 then
                error('Grenade native magnitude could not be changed')
            end
            local ok,instigator=libcall(LIB,'EffectContextGetOriginalInstigatorActor',ctx)
            if not ok then error('Grenade native original instigator query failed')end
            local count=0;for _ in pairs(radial)do count=count+1 end
            if count>=256 and not radial[id]then radial={}end
            radial[id]={bone=bone,instigator=runtime.key(instigator),world_key=world_key,generation=generation}
            info.grenade_scaled=info.grenade_scaled+1
        end)
        if not matched then report_error(why)end
    end
    local function on_component_apply(_,spec_arg,target_arg)
        if not active then return end
        local c=context();if not c then return end
        local spec=unwrap(spec_arg);local name=effect_class(spec)
        if name~='BlueprintGeneratedClass '..KNIFE and name~='BlueprintGeneratedClass '..GRENADE then return end
        local target=unwrap(target_arg);if not live(target)then return end
        local linked,actor=call(target,'GetOwner');local id=linked and owned(actor,c)or nil;if not id then return end
        local got,asc=libcall(LIB,'GetAbilitySystemComponent',actor)
        if not got or runtime.key(asc)~=runtime.key(target)then return end
        local matched,why=with_context_hit(spec,function(hit_actor,bone,ctx,hit)
            if runtime.key(hit_actor)~=runtime.key(actor)or not bone then error('Native projectile context lacks the exact target hit')end
            local resolved,instigator=libcall(LIB,'EffectContextGetOriginalInstigatorActor',ctx)
            if not resolved then error('Native projectile original instigator query failed')end
            if name=='BlueprintGeneratedClass '..GRENADE then
                local record=radial[id];radial[id]=nil
                if not record or record.world_key~=world_key or record.generation~=generation or record.bone~=bone
                    or record.instigator~=runtime.key(instigator)then
                    error('Grenade native application lacks its matching scaled falloff')
                end
            elseif bone~='head'then
                -- Clone while both the real hit and cloned spec are borrowed from
                -- live native return frames. Never round-trip either via a table.
                local got,causer=libcall(LIB,'EffectContextGetEffectCauser',ctx)
                if not got then error('Knife original effect context unavailable')end
                local new_instigator=live(instigator)and instigator or nil
                if not live(causer)then causer=nil end
                local cloned,reason=with_return('CloneSpecHandle',function(copy)
                    local contextual,detail=with_return('GetEffectContext',function(new_context)
                        if not libcall(LIB,'EffectContextAddHitResult',new_context,hit,true)then
                            error('Knife isolated effect context could not be created')
                        end
                    end,copy)
                    if not contextual then error(detail)end
                    local assigned=libcall(LIB,'AssignTagSetByCallerMagnitude',copy,multiplier_tag,1.0)
                    if not assigned or effect_class(copy)~=name or not call(spec_arg,'set',copy)then
                        error('Knife native application spec could not be replaced')
                    end
                end,new_instigator,causer,spec)
                if not cloned then error(reason)end
                -- The original native input now owns its reflected handle copy.
                spec=unwrap(spec_arg)
                local verified,detail=with_context_hit(spec,function(actual,bone_after)
                    if runtime.key(actual)~=runtime.key(actor)or bone_after~=bone then
                        error('Knife cloned hit context did not survive native input replacement')
                    end
                end)
                if not verified then error(detail)end
                info.knife_scaled=info.knife_scaled+1
            end
            emit_with_instigator(id,bone,c,instigator,COMPONENT_APPLY)
        end)
        if not matched then report_error(why)end
    end
    function self.start()
        if active then return true end
        info.startup_attempts=info.startup_attempts+1;info.fname_api_type=type(api.FName)
        if cleanup_failed then return startup_failure('cleanup','Damage hook cleanup failed; restart required')end
        if type(api.RegisterHook)~='function'or type(api.UnregisterHook)~='function'then
            return startup_failure('hook_api','Damage hook APIs unavailable')
        end
        -- UE4SS 83330635 publishes FName as userdata with __call, not a Lua
        -- function. Attempt its supported constructor syntax and check the value.
        local named,name=pcall(function()return api.FName('SetByCaller.DamageMultiplier')end)
        if not named then return startup_failure('fname','Native damage tag construction failed ('..type(api.FName)..'): '..tostring(name))end
        if string_value(name)~='SetByCaller.DamageMultiplier'then
            return startup_failure('fname','Native damage tag constructor returned an unexpected name')
        end
        multiplier_tag={TagName=name}
        if not live(find(BONE))and type(api.LoadAsset)=='function'then pcall(api.LoadAsset,FIRE)end
        for _,path in ipairs({BONE,APPLY,COMPONENT_APPLY,ASSIGN,LIB,BODYLIB})do
            if not live(find(path))then return startup_failure('symbols','Required damage symbol unavailable: '..path)end
        end
        for _,method in ipairs(RETURN_METHODS)do
            local path=M.RETURN_PATHS[method]
            if not live(find(path))then return startup_failure('symbols','Required native return symbol unavailable: '..path)end
        end
        token=token+1;local installed=token
        local records={{path=APPLY,callback=on_apply,native=true},{path=BONE,callback=on_bone,native=false},
            {path=ASSIGN,callback=on_assign,native=true},{path=COMPONENT_APPLY,callback=on_component_apply,native=true}}
        for _,method in ipairs(RETURN_METHODS)do
            records[#records+1]={path=M.RETURN_PATHS[method],callback=function()end,native=true,
                post=function(_,result)on_native_return(method,result)end}
        end
        for _,record in ipairs(records)do
            local wrapper=function(...)
                if not active or token~=installed then return end
                local ok,err=pcall(record.callback,...);if not ok then report_error(err)end
            end
            local post_wrapper
            if record.post then post_wrapper=function(...)
                if not active or token~=installed then return end
                local ok,err=pcall(record.post,...);if not ok then report_error(err)end
            end end
            local ok,pre,post
            if post_wrapper then ok,pre,post=pcall(api.RegisterHook,record.path,wrapper,post_wrapper)
            else ok,pre,post=pcall(api.RegisterHook,record.path,wrapper)end
            if ok and type(pre)=='number'and type(post)=='number'then
                hooks[#hooks+1]={path=record.path,pre=pre,post=post,callback=wrapper,post_callback=post_wrapper}
                -- UE4SS 83330635 uses equal IDs for script post observers, and
                -- separate IDs for the actual native pre/post pair.
                if (record.native and pre==post)or(not record.native and pre~=post)then
                    self.stop();return startup_failure('hook_convention','Unexpected native/script hook convention: '..record.path)
                end
            else
                self.stop()
                return startup_failure('hook_registration','Damage hook registration failed: '..record.path..(not ok and(' | '..tostring(pre))or''))
            end
        end
        active=true;info.ready=true;info.damage_pre_apply=true
        info.startup_phase='ready';info.startup_error=nil;info.last_error=nil;return true
    end
    function self.prepare_zombie(actor,c)
        if not active or not info.ready or not c or c.authority~=true then return false,'Damage bridge is not ready'end
        local current=context()
        if not current or (current.world_key or current.world_id)~=(c.world_key or c.world_id)
            or current.generation~=c.generation then return false,'World changed'end
        local id=owned(actor,c)
        if not id then return false,'Zombie ownership is unavailable'end
        return true
    end
    function self.verify_zombie(actor,c)
        local prepared,why=self.prepare_zombie(actor,c);if not prepared then return false,why end
        local component=get(actor,'WW_RagdollSystem')
        if not actor_for_component(component,c)then return false,'Native firearm hit component unavailable'end
        local ok,asc=libcall(LIB,'GetAbilitySystemComponent',actor)
        if not ok or not live(asc)then return false,'Owned zombie must use the native GAS firearm path'end
        return true
    end
    function self.forget_zombie(id,c)
        if c and ((c.world_key or c.world_id)~=world_key or c.generation~=generation)then return false end
        for ability,hit in pairs(pending)do if hit.zombie_id==id then pending[ability]=nil end end
        radial[id]=nil
        return true
    end
    function self.reset_world(c)
        if c and world_key and ((c.world_key or c.world_id)~=world_key or c.generation~=generation)then return false end
        pending={};radial={};world_key=nil;generation=nil
        return true
    end
    function self.stop()
        active=false;token=token+1;pending={};radial={};return_frames={};world_key=nil;generation=nil
        info.ready=false;info.damage_pre_apply=false
        local remaining={}
        for _,hook in ipairs(hooks)do
            local ok,result=pcall(api.UnregisterHook,hook.path,hook.pre,hook.post)
            if not ok or result==false then remaining[#remaining+1]=hook end
        end
        hooks=remaining;cleanup_failed=#remaining>0;info.cleanup_failed=cleanup_failed
        return not cleanup_failed
    end
    function self.snapshot()
        local s={};for k,v in pairs(info)do s[k]=v end
        s.registered_hooks=#hooks
        s.native_return_pending=0;for _,frames in pairs(return_frames)do s.native_return_pending=s.native_return_pending+#frames end
        s.pending=0;for _ in pairs(pending)do s.pending=s.pending+1 end
        s.radial_pending=0;for _ in pairs(radial)do s.radial_pending=s.radial_pending+1 end
        return s
    end
    return self
end
return M
