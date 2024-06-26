require './generator'

class CIncludesGenerator < Generator
    def self.filter_key
        "CIncludes"
    end

    def encode_size(type)
        sz = size_of_type(type)
        return 0 unless sz
        return sz >= 4 ? 3 : sz
    end
    
    def decl(type, thing)
        if thing then
            type =~ /(const +)?([A-Za-z0-9_]+) *((\* *)*)(.*)/
            return "#{$1}#{$2} #{$3}#{thing}#{$5}"
        else
            return type
        end
    end

    def declare_trapnum(name, trapno)
        @out << "enum { _#{name} = #{hexlit(trapno)} };\n"
    end

    def declare_inline(name, rettype, args, expr)
        @out << "#define #{name}(#{args.map {|x|x["name"]}.compact.join(", ")}) (#{expr})\n"
    end

    def generate_function_definition(out:, fun:, name:, args:, m68kinlines:)
        return if not m68kinlines
        writeback = ""
        out << "pascal " << (fun["return"] or "void") << " " << name <<
            "(" << args.map {|x| decl(x["type"],x["name"])}.join(", ") << ")"
        out << "{"

        clobbers = Set.new(["%d0","%d1","%d2","%a0","%a1"])
        inputs = []
        outputs = []
        if fun["returnreg"] then
            register = "%" + fun["returnreg"].downcase
            out << "register #{fun["return"]} _retval __asm__(\"#{register}\");"
            
            clobbers.delete?(register)
            outputs << "\"=r\"(_retval)"
        end

        args.each do |arg|
            if arg["register"] =~ /(Out|InOut)<([AD][0-7])>/ then
                io = $1
                register = "%" + $2.downcase
                if arg["type"] =~ /(.*)\*/ then
                    type = $1
                    out << "register #{type} _#{arg["name"]} __asm__(\"#{register}\");"
                    out << "_#{arg["name"]} = *#{arg["name"]};" if io == "InOut"
                    writeback << "*#{arg["name"]} = _#{arg["name"]};"

                    clobbers.delete?(register)
                    outputs << "\"=r\"(_#{arg["name"]})"
                    inputs << "\"r\"(_#{arg["name"]})" if io == "InOut"
                end
            elsif arg["register"] =~ /[AD][0-7]/ then
                register = "%" + arg["register"].downcase
                out << "register #{arg["type"]} _#{arg["name"]} __asm__(\"#{register}\");"
                out << "_#{arg["name"]} = #{arg["name"]};"

                clobbers.delete?(register)
                inputs << "\"r\"(_#{arg["name"]})"
            end
        end
        
        out << "\n// clang-format off\n"
        out << "    __asm__ volatile(\".short #{m68kinlines.join(", ")}\"\n"
        out << " " * 8 << ": #{outputs.join(", ")}\n"
        out << " " * 8 << ": #{inputs.join(", ")}\n"
        out << " " * 8 << ": #{clobbers.map{|x| '"'+x+'"'}.join(", ")});"
        out << "\n// clang-format on\n"
        out << writeback
        out << "return _retval;" if fun["returnreg"]
        out << "}"
    end

    def generate_cfm_wrapper(out:, fun:, name:, args:)
        if !@cfmwrapper_included then
            @cfmwrapper_included = true
            out << "#include \"cfmwrapper.h\"\n"
        end

        out << "pascal " << (fun["return"] or "void") << " " << name <<
            "(" << args.map {|x| decl(x["type"],x["name"])}.join(", ") << ")"
        out << "{\n"

        out << "__cfmsym symbol;\n"
        out << "OSErr err;\n"

        procinfo = 0
        procinfo |= encode_size(fun["return"]) << 4 if fun["return"]
        shift = 6
        args.each do |arg|
            procinfo |= encode_size(arg["type"]) << shift
            shift += 2
        end

        out << "err = __cfmwrapper_connect(&symbol, \"\\p#{fun["cfm"]}\", \"\\p#{name}\", #{procinfo});"
        
        if fun["return"] == "OSErr" then
            out << "if(err) return err;\n"
        elsif fun["return"] == "Boolean" then
            out << "if(err) return false;\n"
        elsif !fun["return"]
            out << "if(err) return;\n"
        else
            out << "if(err) return 0;\n"
        end

        out << fun["return"] << " retval = " if fun["return"]

        out << "(*(pascal " << (fun["return"] or "void") << "(*)" <<
            "(" << args.map {|x| x["type"]}.join(", ") << ")" << ")" <<
            "(symbol.proc))" <<
            "(" << args.map {|x| x["name"]}.join(", ") << ");\n"

        out << "__cfmwrapper_disconnect(&symbol);\n"

        out << "return retval;" if fun["return"]

        out << "}"
    end

    def declare_function(fun, variant_index:nil)
        return if fun["name"] =~ /ROMlib/
        if fun["variants"] and not variant_index
            
            fun["variants"].each_index { |i| declare_function(fun, variant_index:i) }
            return
        end

        complex = false

        name = fun["name"]
        args = (fun["args"] or [])

        trapbits = 0

        if variant_index then
            name = fun["variants"][variant_index]
            nbits = Math.log2(fun["variants"].length).ceil

            (0..nbits-1).each do |bitidx|
                bitarg = args[-bitidx-1]
                if (variant_index & (1 << bitidx)) != 0 then
                    bitarg["register"] =~ /TrapBit<(.*)>/
                    bitval =
                        case $1 
                        when "SYSBIT" then 0x0400
                        when "CLRBIT" then 0x0200
                        else Integer($1)
                        end
                    trapbits |= bitval
                end
            end

            args = args[0..-nbits-1]
        end

        declare_trapnum(name, fun["trap"] | trapbits) if fun["trap"] and not fun["selector"]
        
        if fun["m68k-inline"] then
            m68kinlines = fun["m68k-inline"]
        else
            m68kinlines = []

            dispatcher = (fun["dispatcher"] and $global_name_map[fun["dispatcher"]]["dispatcher"])
            if dispatcher then
                sel = Integer(fun["selector"])
                case dispatcher["selector-location"]
                when "D0W", "D0<0xFF>", "D0<0xF>"
                    if sel >= -128 and sel <= 127 then
                        m68kinlines << (0x7000 | (sel & 0xFF))
                    else
                        m68kinlines << 0x303C << sel
                    end
                when "D0L", "D0<0xFFFFFF>"
                    if sel >= -128 and sel <= 127 then
                        m68kinlines << (0x7000 | (sel & 0xFF))
                    else
                        m68kinlines << 0x203C << (sel >> 16) << (sel & 0xFFFF)
                    end
                when "StackW"
                    m68kinlines << 0x3F3C << sel
                when "StackL"
                    m68kinlines << 0x2F3C << (sel >> 16) << (sel & 0xFFFF)
                when "TrapBits"
                else
                    complex = true
                end
                m68kinlines << ((fun["trap"] || dispatcher["trap"]) | trapbits)
            else
                m68kinlines << (fun["trap"] | trapbits) if fun["trap"]
            end
        end
        
        m68kinlines = m68kinlines.map {|x| hexlit(x)}
        

        if fun["args"] or fun["returnreg"] then
            regs = []
            regs << fun["returnreg"] if fun["returnreg"]
            
            args.each do |arg|
                regs << arg["register"] if arg["register"]
            end

            simpleregs = regs.map { |txt| if txt =~ /^[AD][0-7]$/ then "__"+txt else nil end }.compact
            complex = true if simpleregs.length < regs.length
            

            if simpleregs.length > 0 and not complex then
                @out << "#if TARGET_CPU_68K\n"
                @out << "#pragma parameter "
                @out << simpleregs.shift if fun["returnreg"]
                @out << " " << name
                @out << "(" << simpleregs.join(", ") << ")" if simpleregs.length > 0
                @out << "\n"
                @out << "#endif\n"
            end
        end

        optionalInline = false
        if fun["inline"] then
            case fun["noinline"] && fun["noinline"].downcase
            when "carbon"
                @out << "#if !TARGET_API_MAC_CARBON\n"
                optionalInline = true
            when "ppc"
                @out << "#if TARGET_CPU_68K\n"
                optionalInline = true
            when "m68k"
                @out << "#if !TARGET_CPU_68K\n"
                optionalInline = true
            end
            declare_inline(name, (fun["return"] or "void"), args, fun["inline"])
        end
        @out << "#else\n" if optionalInline

        if !fun["inline"] || optionalInline then
            @out << "pascal "
            @out << (fun["return"] or "void") << " "
            @out << name << "("
            @out << args.map {|arg| decl(arg["type"], arg["name"])}.join(", ")
            @out << ")"
            @out << " M68K_INLINE(" << m68kinlines.join(", ") << ")" if m68kinlines.length > 0 and not complex
            @out << ";\n"

            if complex and m68kinlines then
                generate_function_definition(out:@impl_out, fun:fun, name:name, args:args, m68kinlines:m68kinlines)
            elsif fun["cfm"] then
                generate_cfm_wrapper(out:@impl_out, fun:fun, name:name, args:args)
            end
        end
        @out << "#endif\n" if optionalInline

        if not fun["inline"] and (m68kinlines.length == 0 or complex) then
            @functions_needing_glue << name
        end

        if fun["old_name"] then
            @out << "#if OLDROUTINENAMES\n"
            argnames = args.map {|arg| arg["name"]}.join(", ")
            @out << "#define #{fun["old_name"]}(#{argnames}) #{name}(#{argnames})\n"
            @out << "#endif\n"
        end
    end

    def declare_struct_union(what, value)
        @out << "typedef #{what} #{value["name"]} #{value["name"]};"
                
        if value["members"] then
            @out << "#{what} #{value["name"]} {"
            declare_members(value["members"])
            @out << "};"
        end
    end

    def declare_dispatcher(value)
        declare_trapnum(value["name"], value["trap"]) unless value["selector-location"] == "TrapBits"
    end


    def declare_funptr(value)
        @out << "typedef pascal "

        name = value["name"]
        if name=~/^([A-Za-z_][A-Za-z0-9]*)(ProcPtr|UPP)$/ then
            name = $1 
        else
            print "WARNING: strange function pointer #{name}\n"
        end
                      

        @out << (value["return"] or "void") << " "
        @out << "(*" << name << "ProcPtr" << ")("
        args = (value["args"] or [])
        @out << args.map {|arg|decl(arg["type"], arg["name"])}.join(", ")
        @out << ");\n"
        
        if args.any? {|arg| arg["register"]} then
            procinfo = 42;
            print "WARNING UNSUPPORTED register funptr: #{name}\n"
        else
            procinfo = 0
            procinfo |= encode_size(value["return"]) << 4
            shift = 6
            args.each do |arg|
                procinfo |= encode_size(arg["type"]) << shift
                shift += 2
            end
        end
        @out << "#if TARGET_API_MAC_CARBON\n"
        @out << "typedef struct Opaque#{name}Proc *#{name}UPP;\n"
        @out << "pascal #{name}UPP New#{name}UPP(#{name}ProcPtr proc);\n"
        @out << "pascal void Dispose#{name}UPP(#{name}UPP upp);\n"
        @out << <<~UPPDECL
            #elif TARGET_RT_MAC_CFM
            typedef UniversalProcPtr #{name}UPP;
            enum { upp#{name}ProcInfo = #{hexlit(procinfo,32)} };
        UPPDECL
        declare_inline("New#{name}UPP", "#{name}UPP", [{"name"=>"proc", "type"=>"#{name}ProcPtr"}],
            "(#{name}UPP)NewRoutineDescriptor((ProcPtr)(proc), upp#{name}ProcInfo, GetCurrentArchitecture())")
        declare_inline("Dispose#{name}UPP", nil, [{"name"=>"upp", "type"=>"#{name}UPP"}],
            "DisposeRoutineDescriptor((UniversalProcPtr)(upp))")
        @out << <<~UPPDECL
            #else

            typedef #{name}ProcPtr #{name}UPP;
            #define New#{name}UPP(proc) (proc)
            #define Dispose#{name}UPP(proc) do { } while(false)

            #endif

            #define New#{name}Proc(proc) New#{name}UPP(proc)
            #define Dispose#{name}Proc(proc) Dispose#{name}UPP(proc)

        UPPDECL
    end

    def declare_lowmem(value)
        if value["type"] =~ /^(.*)\[[^\[\]]*\]$/ then
            declare_inline("LMGet" + value["name"], $1 + "*", [], "(#{$1}*)" + hexlit(value["address"]))
        else
            expr = "*(#{value["type"]}*)" + hexlit(value["address"])
            declare_inline("LMGet" + value["name"], value["type"], [], expr)
            declare_inline("LMSet" + value["name"], "void",
                [{"type" => value["type"], "name" => "val"}], expr + " = val")
        end
    end

    def generate_preamble(header)
        super
        @out << "#pragma pack(push, 2)\n"
        @out << "\n\n"
    end

    def generate_postamble(header)
        @out << "#pragma pack(pop)\n\n\n"              
        super
    end

    def generate_comment(key, value)
        super unless key == "executor_only"
    end
    
    def make_api_ifdef(api)
        if (api && api.downcase) == "carbon" then
            @out << "#if TARGET_API_MAC_CARBON\n"
            yield
            @out << "#endif\n"
        elsif (api && api.downcase) == "classic" then
            @out << "#if !TARGET_API_MAC_CARBON\n"
            yield
            @out << "#endif\n"
        else
            yield
        end
    end

    def generate(defs)
        @functions_needing_glue = []
        
        print "Writing Headers...\n"

        FileUtils.mkdir_p "#{$options.output_dir}/CIncludes"
        FileUtils.mkdir_p "#{$options.output_dir}/RIncludes"
        FileUtils.mkdir_p "#{$options.output_dir}/src"
        FileUtils.mkdir_p "#{$options.output_dir}/obj"
        FileUtils.mkdir_p "#{$options.output_dir}/lib68k"
        
        formatted_file("#{$options.output_dir}/CIncludes/Multiverse.h") do |f|
            f << <<~PREAMBLE
                #pragma once
                #include <stdint.h>
                #include <stdbool.h>
                #include <stddef.h>
                
                #ifdef __m68k__
                    #define TARGET_CPU_68K 1
                    #define TARGET_CPU_PPC 0
                    #define TARGET_RT_MAC_CFM 0
                    #define M68K_INLINE(...) = { __VA_ARGS__ }
                    #define GetCurrentArchitecture() ((int8_t)0)
                #else
                    #define TARGET_CPU_68K 0
                    #define TARGET_CPU_PPC 1
                    #define TARGET_RT_MAC_CFM 1
                    #define M68K_INLINE(...)
                    #define GetCurrentArchitecture() ((int8_t)1)
        
                    #ifndef pascal
                        #define pascal
                    #endif
                #endif
        
                #ifndef TARGET_API_MAC_CARBON
                #define TARGET_API_MAC_CARBON 0
                #endif
        
                //typedef void (*ProcPtr)();
                typedef struct RoutineDescriptor *ProcPtr;
                #define nil NULL
        
                #define STACK_ROUTINE_PARAMETER(n, sz) ((sz) << (kStackParameterPhase + ((n)-1) * kStackParameterWidth))
            
                #ifndef OLDROUTINENAMES
                #define OLDROUTINENAMES 0
                #endif
            PREAMBLE
        
            defs.topsort.each do |name|
                # HACK: MPW.h defines things not defined in Universal Interfaces.
                # We need a better way to specify that this is 'extra' functionality, and it should not be included
                # in Multiverse.h.
                # MPW.h has been added for Executor, and it conflicts with Retro68's sample programs.
                next if name == "MPW"

                header = defs.headers[name]
                @impl_out = ""
                @cfmwrapper_included = false
                inc = generate_header(header)
        
                f << inc
        
                if @impl_out.length > 0 then
                    formatted_file("#{$options.output_dir}/src/#{header.name}.c") do |f|
                        f << "#include \"Multiverse.h\"\n"
                        f << @impl_out
                    end
                end
            end
        
            f << <<~POSTAMBLE
        
                extern QDGlobals qd;
                #if TARGET_RT_MAC_CFM
                #define UnloadSeg(x) do {} while(false)
                #endif
            POSTAMBLE
        end
        
        ["Carbon", "Devices", "Dialogs", "Errors", "Events", "Files", "FixMath",
            "Fonts", "Icons", "LowMem", "MacMemory", "MacTypes", "Memory", "Menus",
            "MixedMode", "NumberFormatting", "OSUtils", "Processes", "Quickdraw",
            "Resources", "SegLoad", "Sound", "TextEdit", "TextUtils", "Timer",
            "ToolUtils", "Traps", "Types", "Windows", "ConditionalMacros",
            "Gestalt", "AppleEvents", "Serial", "StandardFile", "Strings",
            "Navigation"].each do |name|
            File.open("#{$options.output_dir}/CIncludes/#{name}.h", "w") do |f|
                f << "#pragma once\n"
                f << "#include \"Multiverse.h\"\n"
            end
        end 
        
        Dir.glob("custom/*.r") {|f| FileUtils.cp(f, "#{$options.output_dir}/RIncludes/")}
        Dir.glob("custom/*.c") {|f| FileUtils.cp(f, "#{$options.output_dir}/src/")}
        Dir.glob("custom/*.h") {|f| FileUtils.cp(f, "#{$options.output_dir}/src/")}
        ["CodeFragments", "Dialogs", "Finder", "Icons", "MacTypes", "Types",
         "Menus", "MixedMode", "Processes", "Windows", "ConditionalMacros"].each do |name|
            File.open("#{$options.output_dir}/RIncludes/#{name}.r", "w") do |f|
                f << "#include \"Multiverse.r\"\n"
            end
        end
        
        File.open("#{$options.output_dir}/CIncludes/needs-glue.txt", "w") do |f|
            @functions_needing_glue.each {|name| f << name + "\n"}
        end


        print "Compiling glue code...\n"
        allNames = Set.new
        Dir.glob("#{$options.output_dir}/src/*.c") do |file|
            name = File.basename(file, '.c')
            system("m68k-apple-macos-gcc -c #{file} -o #{$options.output_dir}/obj/#{name}.o -I #{$options.output_dir}/CIncludes -O -ffunction-sections")
            allNames << name
        end

        libraries_config = YAML::load(File.read("custom/libraries.yaml"))
        libraries_config.each do |libname, files|
            allNames.subtract(files)
        end
        libraries_config["Interface"] = allNames.to_a

        libraries_config.each do |libname, files|
            print "Linking lib#{libname}.a...\n"
            system("m68k-apple-macos-ar cqs #{$options.output_dir}/lib68k/lib#{libname}.a " +
                files.map {|f| "#{$options.output_dir}/obj/#{f}.o"}.join(" "))
        end
        print "Done.\n"
    end
end
