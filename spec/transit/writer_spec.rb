require 'spec_helper'

module Transit
  class Handler
    extend Forwardable

    def_delegators :@handlers, :[]=

    def initialize
      @handlers = ClassHash.new
      @handlers[String] = StringHandler.new
      @handlers[Time] = InstantHandler.new
      @handlers[Fixnum] = IntHandler.new
      @handlers[Array] = ArrayHandler.new
      @handlers[Hash] = MapHandler.new
    end

    def [](obj)
      @handlers[obj.class]
    end

    class StringHandler
      def tag(s) "s" end
      def rep(s) s end
      def string_rep(s) s end
    end

    class InstantHandler
      def tag(t) "t" end
      def rep(t) t.strftime("%FT%H:%M:%S.%LZ") end
      def string_rep(t) rep(t) end
    end

    class IntHandler
      def tag(i) "i" end
      def rep(i) i end
      def string_rep(i) i.to_s end
    end

    class ArrayHandler
      def tag(a) :array end
      def rep(a) a end
      def string_rep(_) nil end
    end

    class MapHandler
      def tag(m) :map end
      def rep(m) m end
      def string_rep(_) nil end
    end
  end

  class JsonMarshaler
    ESC = "~"
    SUB = "^"
    RESERVED = "`"

    def initialize(io)
      @oj = Oj::StreamWriter.new(io)
      @handlers = Handler.new
    end

    def escape(s)
      [ESC, SUB, RESERVED].include?(s[0]) ? "#{ESC}#{s}" : s
    end

    def push_value(v, k)
      k ? @oj.push_value(v, k) : @oj.push_value(v)
    end

    def encode_string(obj, as_map_key)
      handler = @handlers[obj]
      tag = handler.tag(obj)
      str_rep = handler.string_rep(obj)
      if as_map_key
        escape(str_rep)
      else
        "#{ESC}#{tag}#{escape(str_rep)}"
      end
    end

    def emit_string(prefix, tag, string, map_key, _cache_)
      push_value("#{prefix}#{tag}#{string}", map_key)
    end

    def emit_int(i, map_key, _cache_)
      push_value(i, map_key)
    end

    def emit_array(a, map_key, _cache_)
      @oj.push_array
      a.each {|e| marshal(e, map_key, _cache_)}
      @oj.pop
    end

    def emit_map(a, map_key, _cache_)
      @oj.push_object
      a.each do |k,v|
        marshal(v, encode_string(k, true), _cache_)
      end
      @oj.pop
    end

    def marshal(obj, map_key, _cache_)
      handler = @handlers[obj]
      tag = handler.tag(obj)
      rep = handler.rep(obj)
      case tag
      when "s"
        emit_string(nil, nil, escape(rep), map_key, _cache_)
      when "i"
        emit_int(rep, map_key, _cache_)
      when :array
        emit_array(rep, map_key, _cache_)
      when :map
        emit_map(rep, map_key, _cache_)
      else
        emit_encoded(tag, obj, map_key, _cache_)
      end
    end

    def emit_encoded(tag, obj, map_key, _cache_)
      if tag
        handler = @handlers[obj]
        rep = handler.rep(obj)
        if String === rep
          emit_string(ESC, tag, rep, map_key, _cache_)
        end
      end
    end
  end

  class Writer
    def initialize(io, type)
      @marshaler = JsonMarshaler.new(io)
    end

    def write(obj)
      @marshaler.marshal(obj, nil, nil)
    end
  end
end

module Transit
  describe JsonWriter do
    let(:io) { StringIO.new }
    let(:writer) { Writer.new(io, :json) }

    it "marshals a string" do
      writer.write("this")
      assert { io.string == "\"this\"" }
    end

    it "escapes a string that begins with ~" do
      writer.write("~this")
      assert { io.string == "\"~~this\"" }
    end

    it "marshals an instant" do
      t = Time.now
      writer.write(t)
      assert { io.string == "\"~t#{t.strftime("%FT%H:%M:%S.%LZ")}\"" }
    end

    it "marshals an int" do
      writer.write(37)
      assert { io.string == "37" }
    end

    it "marshals an array" do
      writer.write([1])
      assert { io.string == "[1]" }
    end

    it "marshals an array with several elements including nested arrays" do
      writer.write([1, "2", [3, ["~4"]]])
      assert { io.string == "[1,\"2\",[3,[\"~~4\"]]]" }
    end

    it "marshals a map w/ string keys" do
      writer.write({"a" => 1, "b" => "c"})
      assert { io.string == "{\"a\":1,\"b\":\"c\"}" }
    end

    it "marshals a map w/ time keys" do
      t = Time.new(2014,1,2,3,4,5)
      writer.write({t => "ignore"})
      assert { io.string == "{\"2014-01-02T03:04:05.000Z\":\"ignore\"}" }
    end

    it "marshals a map w/ string keys and values that require escaping" do
      writer.write({"~a" => 1, "~b" => "~c"})
      assert { io.string == "{\"~~a\":1,\"~~b\":\"~~c\"}" }
    end

    it "raises for non-stringable map keys" do
      assert { rescuing { writer.write({[1,2] => "ignore"}).message =~ /Can not push/ } }
    end
  end
end
