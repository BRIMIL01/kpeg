require 'kpeg/grammar_renderer'
require 'stringio'

module KPeg
  class CodeGenerator
    def initialize(name, gram, debug=false)
      @name = name
      @grammar = gram
      @debug = debug
      @saves = 0
      @output = nil
      @standalone = false
    end

    attr_accessor :standalone

    def method_name(name)
      name = name.gsub("-","_hyphen_")
      "_#{name}"
    end

    def save
      if @saves == 0
        str = "_save"
      else
        str = "_save#{@saves}"
      end

      @saves += 1
      str
    end

    def reset_saves
      @saves = 0
    end

    def output_op(code, op)
      case op
      when Dot
        code << "    _tmp = get_byte\n"
      when LiteralString
        code << "    _tmp = match_string(#{op.string.dump})\n"
      when LiteralRegexp
        lang = op.regexp.kcode.to_s[0,1]
        code << "    _tmp = scan(/\\A#{op.regexp}/#{lang})\n"
      when CharRange
        ss = save()
        if op.start.bytesize == 1 and op.fin.bytesize == 1
          code << "    #{ss} = self.pos\n"
          code << "    _tmp = get_byte\n"
          code << "    if _tmp\n"

          if op.start.respond_to? :getbyte
            left  = op.start.getbyte 0
            right = op.fin.getbyte 0
          else
            left  = op.start[0]
            right = op.fin[0]
          end

          code << "      unless _tmp >= #{left} and _tmp <= #{right}\n"
          code << "        self.pos = #{ss}\n"
          code << "        _tmp = nil\n"
          code << "      end\n"
          code << "    end\n"
        else
          raise "Unsupported char range - #{op.inspect}"
        end
      when Choice
        ss = save()
        code << "\n    #{ss} = self.pos\n"
        code << "    while true # choice\n"
        op.ops.each_with_index do |n,idx|
          output_op code, n

          code << "    break if _tmp\n"
          code << "    self.pos = #{ss}\n"
          if idx == op.ops.size - 1
            code << "    break\n"
          end
        end
        code << "    end # end choice\n\n"
      when Multiple
        ss = save()
        if op.min == 0 and op.max == 1
          code << "    #{ss} = self.pos\n"
          output_op code, op.op
          if op.save_values
            code << "    @result = nil unless _tmp\n"
          end
          code << "    unless _tmp\n"
          code << "      _tmp = true\n"
          code << "      self.pos = #{ss}\n"
          code << "    end\n"
        elsif op.min == 0 and !op.max
          if op.save_values
            code << "    _ary = []\n"
          end

          code << "    while true\n"
          output_op code, op.op
          if op.save_values
            code << "    _ary << @result if _tmp\n"
          end
          code << "    break unless _tmp\n"
          code << "    end\n"
          code << "    _tmp = true\n"

          if op.save_values
            code << "    @result = _ary\n"
          end

        elsif op.min == 1 and !op.max
          code << "    #{ss} = self.pos\n"
          if op.save_values
            code << "    _ary = []\n"
          end
          output_op code, op.op
          code << "    if _tmp\n"
          if op.save_values
            code << "      _ary << @result\n"
          end
          code << "      while true\n"
          code << "    "
          output_op code, op.op
          if op.save_values
            code << "        _ary << @result if _tmp\n"
          end
          code << "        break unless _tmp\n"
          code << "      end\n"
          code << "      _tmp = true\n"
          if op.save_values
            code << "      @result = _ary\n"
          end
          code << "    else\n"
          code << "      self.pos = #{ss}\n"
          code << "    end\n"
        else
          code << "    #{ss} = self.pos\n"
          code << "    _count = 0\n"
          code << "    while true\n"
          code << "  "
          output_op code, op.op
          code << "      if _tmp\n"
          code << "        _count += 1\n"
          code << "        break if _count == #{op.max}\n"
          code << "      else\n"
          code << "        break\n"
          code << "      end\n"
          code << "    end\n"
          code << "    if _count >= #{op.min}\n"
          code << "      _tmp = true\n"
          code << "    else\n"
          code << "      self.pos = #{ss}\n"
          code << "      _tmp = nil\n"
          code << "    end\n"
        end

      when Sequence
        ss = save()
        code << "\n    #{ss} = self.pos\n"
        code << "    while true # sequence\n"
        op.ops.each_with_index do |n, idx|
          output_op code, n

          if idx == op.ops.size - 1
            code << "    unless _tmp\n"
            code << "      self.pos = #{ss}\n"
            code << "    end\n"
            code << "    break\n"
          else
            code << "    unless _tmp\n"
            code << "      self.pos = #{ss}\n"
            code << "      break\n"
            code << "    end\n"
          end
        end
        code << "    end # end sequence\n\n"
      when AndPredicate
        ss = save()
        code << "    #{ss} = self.pos\n"
        if op.op.kind_of? Action
          code << "    _tmp = begin; #{op.op.action}; end\n"
        else
          output_op code, op.op
        end
        code << "    self.pos = #{ss}\n"
      when NotPredicate
        ss = save()
        code << "    #{ss} = self.pos\n"
        if op.op.kind_of? Action
          code << "    _tmp = begin; #{op.op.action}; end\n"
        else
          output_op code, op.op
        end
        code << "    _tmp = _tmp ? nil : true\n"
        code << "    self.pos = #{ss}\n"
      when RuleReference
        code << "    _tmp = apply(:#{method_name op.rule_name})\n"
      when InvokeRule
        if op.arguments
          code << "    _tmp = #{method_name op.rule_name}#{op.arguments}\n"
        else
          code << "    _tmp = #{method_name op.rule_name}()\n"
        end
      when ForeignInvokeRule
        if op.arguments
          code << "    _tmp = @_grammar_#{op.grammar_name}.external_invoke(self, :#{method_name op.rule_name}, #{op.arguments[1..-2]})\n"
        else
          code << "    _tmp = @_grammar_#{op.grammar_name}.external_invoke(self, :#{method_name op.rule_name})\n"
        end
      when Tag
        if op.tag_name and !op.tag_name.empty?
          output_op code, op.op
          code << "    #{op.tag_name} = @result\n"
        else
          output_op code, op.op
        end
      when Action
        code << "    @result = begin; "
        code << op.action << "; end\n"
        if @debug
          code << "    puts \"   => \" #{op.action.dump} \" => \#{@result.inspect} \\n\"\n"
        end
        code << "    _tmp = true\n"
      when Collect
        code << "    _text_start = self.pos\n"
        output_op code, op.op
        code << "    if _tmp\n"
        code << "      text = get_text(_text_start)\n"
        code << "    end\n"
      else
        raise "Unknown op - #{op.class}"
      end

    end

    def standalone_region(path)
      cp = File.read(path)
      start = cp.index("# STANDALONE START")
      fin = cp.index("# STANDALONE END")

      return nil unless start and fin
      cp[start..fin]
    end

    def output
      return @output if @output
      if @standalone
        code = "class #{@name}\n"

        unless cp = standalone_region(
                    File.expand_path("../compiled_parser.rb", __FILE__))

          puts "Standalone failure. Check compiler_parser.rb for proper boundary comments"
          exit 1
        end

        unless pp = standalone_region(
                    File.expand_path("../position.rb", __FILE__))
          puts "Standalone failure. Check position.rb for proper boundary comments"
        end

        cp.gsub!(/include Position/, pp)
        code << cp << "\n"
      else
        code =  "require 'kpeg/compiled_parser'\n\n"
        code << "class #{@name} < KPeg::CompiledParser\n"
      end

      @grammar.setup_actions.each do |act|
        code << "\n#{act.action}\n\n"
      end

      fg = @grammar.foreign_grammars

      if fg.empty?
        if @standalone
          code << "  def setup_foreign_grammar; end\n"
        end
      else
        code << "  def setup_foreign_grammar\n"
        @grammar.foreign_grammars.each do |name, gram|
          code << "    @_grammar_#{name} = #{gram}.new(nil)\n"
        end
        code << "  end\n"
      end

      render = GrammarRenderer.new(@grammar)

      renderings = {}

      @grammar.rule_order.each do |name|
        reset_saves

        rule = @grammar.rules[name]
        io = StringIO.new
        render.render_op io, rule.op

        rend = io.string
        rend.gsub! "\n", " "

        renderings[name] = rend

        code << "\n"
        code << "  # #{name} = #{rend}\n"

        if rule.arguments
          code << "  def #{method_name name}(#{rule.arguments.join(',')})\n"
        else
          code << "  def #{method_name name}\n"
        end

        if @debug
          code << "    puts \"START #{name} @ \#{show_pos}\\n\"\n"
        end

        output_op code, rule.op
        if @debug
          code << "    if _tmp\n"
          code << "      puts \"   OK #{name} @ \#{show_pos}\\n\"\n"
          code << "    else\n"
          code << "      puts \" FAIL #{name} @ \#{show_pos}\\n\"\n"
          code << "    end\n"
        end

        code << "    set_failed_rule :#{method_name name} unless _tmp\n"
        code << "    return _tmp\n"
        code << "  end\n"
      end

      code << "\n  Rules = {}\n"
      @grammar.rule_order.each do |name|
        rule = @grammar.rules[name]

        rend = GrammarRenderer.escape renderings[name], true
        code << "  Rules[:#{method_name name}] = rule_info(\"#{name}\", \"#{rend}\")\n"
      end

      code << "end\n"
      @output = code
    end

    def make(str)
      m = Module.new
      m.module_eval output

      cls = m.const_get(@name)
      cls.new(str)
    end

    def parse(str)
      make(str).parse
    end
  end
end
