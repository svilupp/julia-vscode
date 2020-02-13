module VSCodeDebugger

include("../terminalserver/repl.jl")

# This patches JuliaInterpreter.jl to use our private copy of CodeTracking.jl
filename_of_juliainterpreter = joinpath(@__DIR__, "packages", "JuliaInterpreter", "src", "JuliaInterpreter.jl")
filename_of_codetracking = joinpath(@__DIR__, "packages", "CodeTracking", "src", "CodeTracking.jl")
filename_of_codetracking = replace(filename_of_codetracking, "\\"=>"\\\\")
jlinterp_code = read(filename_of_juliainterpreter, String)
jlinterp_code_patched = replace(jlinterp_code, "using CodeTracking"=>"include(\"$filename_of_codetracking\"); using .CodeTracking")
withpath(filename_of_juliainterpreter) do
    include_string(VSCodeDebugger, jlinterp_code_patched, filename_of_juliainterpreter)
end

import .JuliaInterpreter
import Sockets, Base64

mutable struct DebuggerState
    last_exception

    function DebuggerState()
        return new(nothing)
    end
end

function clean_up_ARGS_in_launch_mode()
    pipename = ARGS[1]
    deleteat!(ARGS, 1)

    if ENV["JL_ARGS"] != ""
        cmd_ln_args_encoded = split(ENV["JL_ARGS"], ';')

        delete!(ENV, "JL_ARGS")

        cmd_ln_args_decoded = map(i->String(Base64.base64decode(i)), cmd_ln_args_encoded)

        for arg in cmd_ln_args_decoded
            push!(ARGS, arg)
        end
    end

    return pipename
end

function _parse_julia_file(filename::String)
    return Base.parse_input_line(read(filename, String); filename=filename)
end

is_toplevel_return(frame) = frame.framecode.scope isa Module && JuliaInterpreter.isexpr(JuliaInterpreter.pc_expr(frame), :return)

function attempt_to_set_f_breakpoints!(bps)
    for bp in bps
        @debug "setting func breakpoint for $(bp.name)"
        try
            f = Core.eval(bp.mod, bp.name)

            signat = if bp.signature!==nothing
                Tuple{(Core.eval(Main, i) for i in bp.signature)...}
            else
                nothing
            end
            @debug "Setting breakpoint for $f"
            JuliaInterpreter.breakpoint(f, signat, bp.condition)
            delete!(bps, bp)
        catch err
        end
    end
end

function our_debug_command(frame, cmd, modexs, not_yet_set_function_breakpoints, compile_mode)
    ret = nothing
    while true
        @debug "Now running the following FRAME:"
        @debug frame

        @debug compile_mode

        ret = Base.invokelatest(JuliaInterpreter.debug_command, compile_mode, frame, cmd, true)

        attempt_to_set_f_breakpoints!(not_yet_set_function_breakpoints)

        @debug "We got $ret"

        if ret!==nothing && is_toplevel_return(ret[1])
            ret = nothing
        end

        if ret!==nothing || length(modexs)==0
            break
        end

        insert_bp!(modexs[1][2])
        frame = JuliaInterpreter.prepare_thunk(modexs[1])        
        deleteat!(modexs, 1)

        ret!==nothing && error("THIS SHOULDN't happen")

        if ret===nothing && (cmd==:n ||cmd==:s || cmd==:finish || JuliaInterpreter.shouldbreak(frame, frame.pc))
            ret = (frame, nothing)
            break
        end
    end

    return ret
end

function decode_msg(line::AbstractString)
    pos = findfirst(':', line)
    pos2 = findnext(':', line, pos+1)

    msg_id = line[1:pos-1]        
    msg_cmd = line[pos+1:pos2-1]
    msg_body_encoded = line[pos2+1:end]
    msg_body = String(Base64.base64decode(msg_body_encoded))
    return msg_id, msg_cmd, msg_body
end

function send_msg(conn, msg_cmd::AbstractString, msg_id::AbstractString, msg_body::AbstractString="")
    encoded_msg_body = Base64.base64encode(msg_body)
    println(conn, msg_cmd, ':', msg_id, ':', encoded_msg_body)
end

function lowercase_drive(a)
    if length(a) >= 2 && a[2]==':'
        return lowercase(a[1]) * a[2:end]
    else
        return a
    end
end

function insert_bp!(expr)
    i = length(expr.args)
    for arg in reverse(expr.args)
        if arg isa LineNumberNode
            lln = arg
            for bp in JuliaInterpreter.breakpoints()
                if bp isa JuliaInterpreter.BreakpointFileLocation
                    if lowercase_drive(string(lln.file)) == lowercase_drive(bp.abspath) && lln.line == bp.line                        
                        insert!(expr.args, i, JuliaInterpreter.BREAKPOINT_EXPR)
                        insert!(expr.args, i, lln)
                        i -= 1
                    end
                end
            end
        end
        if arg isa Expr && !(arg.head in (:function, :struct))
            insert_bp!(arg)
        end
        i -= 1
    end
end

function send_stopped_msg(conn, ret_val, state)
    if ret_val isa JuliaInterpreter.BreakpointRef
        if ret_val.err===nothing
            send_msg(conn, "STOPPEDBP", "notification")
        else
            state.last_exception = ret_val.err
            send_msg(conn, "STOPPEDEXCEPTION", "notification", string(ret_val.err))
        end
    elseif ret_val isa Number
        send_msg(conn, "STOPPEDSTEP", "notification")
    elseif ret_val===nothing
        send_msg(conn, "STOPPEDSTEP", "notification")
    end
end

function startdebug(pipename)
    conn = Sockets.connect(pipename)
    try
        state = DebuggerState()

        modexs = []
        frame = nothing

        not_yet_set_function_breakpoints = Set{String}()

        sources = Dict{Int,String}()
        curr_source_id = 1

        debug_mode = missing

        compile_mode = JuliaInterpreter.finish_and_return!

        while true      
            @debug "Current FRAME is"    
            @debug frame
            @debug "NOW WAITING FOR COMMAND FROM DAP"
            le = readline(conn)
            
            msg_id, msg_cmd, msg_body = decode_msg(le)
            
            @debug "COMMAND is '$msg_cmd'"

            if msg_cmd=="DISCONNECT"
                @debug "DISCONNECT"
                break
            elseif msg_cmd=="RUN"
                debug_mode = :launch
                @debug "WE ARE RUNNING"
                try
                    include(msg_body)
                catch err
                    Base.display_error(stderr, err, catch_backtrace())
                end

                send_msg(conn, "FINISHED", "notification")     
                break           
            elseif msg_cmd=="DEBUG"
                debug_mode = :launch
                index_of_sep = findfirst(';', msg_body)

                stop_on_entry_as_string = msg_body[1:index_of_sep-1]

                stop_on_entry = stop_on_entry_as_string=="stopOnEntry=true"

                filename_to_debug = msg_body[index_of_sep+1:end]

                @debug "We are debugging $filename_to_debug"

                ex = _parse_julia_file(filename_to_debug)

                @debug typeof(ex)
                @debug ex

                modexs, _ = JuliaInterpreter.split_expressions(Main, ex)

                insert_bp!(modexs[1][2])
                frame = JuliaInterpreter.prepare_thunk(modexs[1])
                deleteat!(modexs, 1)

                if stop_on_entry
                    send_msg(conn, "STOPPEDENTRY", "notification")
                elseif JuliaInterpreter.shouldbreak(frame, frame.pc)
                    send_msg(conn, "STOPPEDBP", "notification")
                else
                    ret = our_debug_command(frame, :c, modexs, not_yet_set_function_breakpoints, compile_mode)

                    if ret===nothing
                        send_msg(conn, "FINISHED", "notification")
                        break
                    else
                        frame = ret[1]
                        send_stopped_msg(conn, ret[2], state)                        
                    end
                end
            elseif msg_cmd=="EXEC"
                debug_mode = :attach
                @debug "WE ARE EXECUTING"

                index_of_sep = findfirst(';', msg_body)

                stop_on_entry_as_string = msg_body[1:index_of_sep-1]

                stop_on_entry = stop_on_entry_as_string=="stopOnEntry=true"

                code_to_debug = msg_body[index_of_sep+1:end]

                sources[0] = code_to_debug

                ex = Meta.parse(code_to_debug)

                modexs, _ = JuliaInterpreter.split_expressions(Main, ex)
    
                insert_bp!(modexs[1][2])
                frame = JuliaInterpreter.prepare_thunk(modexs[1])
                deleteat!(modexs, 1)
    
                if stop_on_entry
                    send_msg(conn, "STOPPEDENTRY", "notification")
                elseif JuliaInterpreter.shouldbreak(frame, frame.pc)
                    send_msg(conn, "STOPPEDBP", "notification")
                else
                    ret = our_debug_command(frame, :c, modexs, not_yet_set_function_breakpoints, compile_mode)

                    if ret===nothing
                        @debug "WE ARE SENDING FINISHED"
                        send_msg(conn, "FINISHED", "notification")
                    else
                        @debug "NOW WE NEED TO SEND A ON STOP MSG"
                        frame = ret[1]
                        send_stopped_msg(conn, ret[2], state)
                    end                
                end
            elseif msg_cmd=="TERMINATE"
                send_msg(conn, "FINISHED", "notification")
            elseif msg_cmd=="SETBREAKPOINTS"
                splitted_line = split(msg_body, ';')

                file = splitted_line[1]
                bps = map(split(i, ':') for i in splitted_line[2:end]) do i
                    decoded_condition = String(Base64.base64decode(i[2]))
                    # We handle conditions that don't parse properly as
                    # no condition for now
                    parsed_condition = try
                        decoded_condition=="" ? nothing : Meta.parse(decoded_condition)
                    catch err
                        nothing
                    end

                    (line=parse(Int,i[1]), condition=parsed_condition)
                end

                for bp in JuliaInterpreter.breakpoints()
                    if bp isa JuliaInterpreter.BreakpointFileLocation
                        if bp.path==file
                            JuliaInterpreter.remove(bp)
                        end
                    end
                end
    
                for bp in bps
                    @debug "Setting one breakpoint at line $(bp.line) with condition $(bp.condition) in file $file"
    
                    JuliaInterpreter.breakpoint(string(file), bp.line, bp.condition)                        
                end
            elseif msg_cmd=="SETEXCEPTIONBREAKPOINTS"
                opts = Set(split(msg_body, ';'))

                if "error" in opts                    
                    JuliaInterpreter.break_on(:error)
                else
                    JuliaInterpreter.break_off(:error)
                end

                if "throw" in opts
                    JuliaInterpreter.break_on(:throw )
                else
                    JuliaInterpreter.break_off(:throw )
                end

                if "compilemode" in opts
                    compile_mode = JuliaInterpreter.Compiled()
                else
                    compile_mode = JuliaInterpreter.finish_and_return!
                end
            elseif msg_cmd=="SETFUNCBREAKPOINTS"
                @debug "SETTING FUNC BREAKPOINT"                

                funcs = split(msg_body, ';', keepempty=false)

                bps = map(split(i, ':') for i in funcs) do i
                    decoded_name = String(Base64.base64decode(i[1]))
                    decoded_condition = String(Base64.base64decode(i[2]))

                    parsed_condition = try
                        decoded_condition=="" ? nothing : Meta.parse(decoded_condition)
                    catch err
                        nothing
                    end

                    try
                        parsed_name = Meta.parse(decoded_name)

                        if parsed_name isa Symbol
                            return (mod=Main, name=parsed_name, signature=nothing, condition=parsed_condition)
                        elseif parsed_name isa Expr
                            if parsed_name.head==:.
                                # TODO Support this case
                                return nothing
                            elseif parsed_name.head==:call
                                all_args_are_legit = true
                                if length(parsed_name.args)>1
                                    for arg in parsed_name.args[2:end]
                                        if !(arg isa Expr) || arg.head!=Symbol("::") || length(arg.args)!=1
                                            all_args_are_legit =false
                                        end
                                    end
                                    if all_args_are_legit

                                        return (mod=Main, name=parsed_name.args[1], signature=map(j->j.args[1], parsed_name.args[2:end]), condition=parsed_condition)
                                    else
                                        return (mod=Main, name=parsed_name.args[1], signature=nothing, condition=parsed_condition)
                                    end
                                else
                                    return (mod=Main, name=parsed_name.args[1], signature=nothing, condition=parsed_condition)
                                end
                            else
                                return nothing
                            end
                        else
                            return nothing
                        end
                    catch err
                        return nothing
                    end

                    return nothing
                end

                bps = filter(i->i!==nothing, bps)

                for bp in JuliaInterpreter.breakpoints()
                    if bp isa JuliaInterpreter.BreakpointSignature
                        JuliaInterpreter.remove(bp)
                    end
                end

                not_yet_set_function_breakpoints = Set(bps)

                attempt_to_set_f_breakpoints!(not_yet_set_function_breakpoints)
            elseif msg_cmd=="GETSTACKTRACE"
                @debug "Stacktrace requested"

                fr = frame

                curr_fr = JuliaInterpreter.leaf(fr)

                frames_as_string = String[]

                id = 1
                while curr_fr!==nothing
                    curr_scopeof = JuliaInterpreter.scopeof(curr_fr)
                    curr_whereis = JuliaInterpreter.whereis(curr_fr)

                    file_name = curr_whereis[1]
                    lineno = curr_whereis[2]
                    meth_or_mod_name = Base.nameof(curr_fr)

                    if isfile(file_name)
                        push!(frames_as_string, string(id, ";", meth_or_mod_name, ";path;", file_name, ";", lineno))
                    elseif curr_scopeof isa Method
                        sources[curr_source_id], loc = JuliaInterpreter.CodeTracking.definition(String, curr_fr.framecode.scope)
                        s = string(id, ";", meth_or_mod_name, ";ref;", curr_source_id, ";", file_name, ";", lineno)
                        push!(frames_as_string, s)
                        curr_source_id += 1
                    else
                        # For now we are assuming that this can only happen
                        # for code that is passed via the @enter or @run macros,
                        # and that code we have stored as source with id 0
                        s = string(id, ";", meth_or_mod_name, ";ref;", 0, ";", "REPL", ";", lineno)
                        push!(frames_as_string, s)
                    end
                    
                    id += 1
                    curr_fr = curr_fr.caller
                end

                send_msg(conn, "RESPONSE", msg_id, join(frames_as_string, '\n'))
                @debug "DONE SENDING stacktrace"
            elseif msg_cmd=="GETSCOPE"
                frameId = parse(Int, msg_body)

                curr_fr = JuliaInterpreter.leaf(frame)

                i = 1

                while frameId > i
                    curr_fr = curr_fr.caller
                    i += 1
                end

                curr_scopeof = JuliaInterpreter.scopeof(curr_fr)
                curr_whereis = JuliaInterpreter.whereis(curr_fr)

                file_name = curr_whereis[1]
                code_range = curr_scopeof isa Method ? JuliaInterpreter.compute_corrected_linerange(curr_scopeof) : nothing

                if isfile(file_name) && code_range!==nothing
                    send_msg(conn, "RESPONSE", msg_id, "$(code_range.start);$(code_range.stop);$file_name")
                else
                    send_msg(conn, "RESPONSE", msg_id, "")
                end
            elseif msg_cmd=="GETSOURCE"
                source_id = parse(Int, msg_body)

                send_msg(conn, "RESPONSE", msg_id, sources[source_id])
            elseif msg_cmd=="GETVARIABLES"
                @debug "START VARS"

                frameId = parse(Int, msg_body)

                fr = frame
                curr_fr = JuliaInterpreter.leaf(fr)

                i = 1

                while frameId > i
                    curr_fr = curr_fr.caller
                    i += 1
                end

                vars = JuliaInterpreter.locals(curr_fr)

                vars_as_string = String[]

                for v in vars
                    # TODO Figure out why #self# is here in the first place
                    # For now we don't report it to the client
                    if !startswith(string(v.name), "#") && string(v.name)!=""
                        push!(vars_as_string, string(v.name, ";", typeof(v.value), ";", v.value))
                    end
                end

                if JuliaInterpreter.isexpr(JuliaInterpreter.pc_expr(curr_fr), :return)
                    ret_val = JuliaInterpreter.get_return(curr_fr)
                    push!(vars_as_string, string("Return Value", ";", typeof(ret_val), ";", ret_val))
                end

                send_msg(conn, "RESPONSE", msg_id, join(vars_as_string, '\n'))
                @debug "DONE VARS"
            elseif msg_cmd=="CONTINUE"
                ret = our_debug_command(frame, :c, modexs, not_yet_set_function_breakpoints, compile_mode)

                if ret===nothing
                    @debug "WE ARE SENDING FINISHED"
                    send_msg(conn, "FINISHED", "notification")
                    debug_mode==:launch && break
                else
                    @debug "NOW WE NEED TO SEND A ON STOP MSG"
                    frame = ret[1]
                    send_stopped_msg(conn, ret[2], state)
                end
            elseif msg_cmd=="NEXT"
                @debug "NEXT COMMAND"
                ret = our_debug_command(frame, :n, modexs, not_yet_set_function_breakpoints, compile_mode)

                if ret===nothing
                    @debug "WE ARE SENDING FINISHED"
                    send_msg(conn, "FINISHED", "notification")
                    debug_mode==:launch && break
                else
                    @debug "NOW WE NEED TO SEND A ON STOP MSG"
                    frame = ret[1]
                    send_stopped_msg(conn, ret[2], state)
                end
            elseif msg_cmd=="STEPIN"
                @debug "STEPIN COMMAND"
                ret = our_debug_command(frame, :s, modexs, not_yet_set_function_breakpoints, compile_mode)

                if ret===nothing
                    @debug "WE ARE SENDING FINISHED"
                    send_msg(conn, "FINISHED", "notification")
                    debug_mode==:launch && break
                else
                    @debug "NOW WE NEED TO SEND A ON STOP MSG"
                    frame = ret[1]
                    send_stopped_msg(conn, ret[2], state)
                end
            elseif msg_cmd=="STEPOUT"
                @debug "STEPOUT COMMAND"
                ret = our_debug_command(frame, :finish, modexs, not_yet_set_function_breakpoints, compile_mode)

                if ret===nothing
                    @debug "WE ARE SENDING FINISHED"
                    send_msg(conn, "FINISHED", "notification")
                    debug_mode==:launch && break
                else
                    @debug "NOW WE NEED TO SEND A ON STOP MSG"
                    frame = ret[1]
                    send_stopped_msg(conn, ret[2], state)
                end
            elseif msg_cmd=="EVALUATE"
                index_of_sep = findfirst(':', msg_body)

                stack_id = parse(Int, msg_body[1:index_of_sep-1])

                expression = msg_body[index_of_sep+1:end]

                curr_fr = frame
                curr_i = 1

                while stack_id > curr_i
                    if curr_fr.caller!==nothing
                        curr_fr = curr_fr.caller
                        curr_i += 1
                    else
                        break
                    end
                end

                try
                    ret_val = JuliaInterpreter.eval_code(curr_fr, expression)

                    send_msg(conn, "RESPONSE", msg_id, string(ret_val))
                catch err
                    send_msg(conn, "RESPONSE", msg_id, "#error")
                end

            end
        end
    finally
        close(conn)
    end
end

end