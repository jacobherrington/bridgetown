# frozen_string_literal: true

require "tilt/erubi"

module Bridgetown
  class OutputBuffer < ActiveSupport::SafeBuffer
    def initialize(*)
      super
      encode!
    end

    def <<(value)
      return self if value.nil?

      super(value.to_s)
    end
    alias_method :append=, :<<

    def safe_expr_append=(val)
      return self if val.nil? # rubocop:disable Lint/ReturnInVoidContext

      safe_concat val.to_s
    end

    alias_method :safe_append=, :safe_concat
  end

  class ERBEngine < Erubi::Engine
    private

    def add_code(code)
      @src << code
      @src << ";#{@bufvar};" if code.strip.split(".").first == "end"
      @src << ";" unless code[Erubi::RANGE_LAST] == "\n"
    end

    def add_text(text)
      return if text.empty?

      src << bufvar << ".safe_append='"
      src << text.gsub(%r{['\\]}, '\\\\\&') # rubocop:disable Style/StringLiterals
      src << "'.freeze;"
    end

    # pulled from Rails' ActionView
    BLOCK_EXPR = %r!\s*((\s+|\))do|\{)(\s*\|[^|]*\|)?\s*\Z!.freeze

    def add_expression(indicator, code)
      src << bufvar << if (indicator == "==") || @escape
                         ".safe_expr_append="
                       else
                         ".append="
                       end

      if BLOCK_EXPR.match?(code)
        src << " " << code
      else
        src << "(" << code << ");"
      end
    end
  end

  module ERBCapture
    def capture(*args)
      previous_buffer_state = @_erbout
      @_erbout = OutputBuffer.new
      result = yield(*args)
      result = @_erbout.presence || result
      @_erbout = previous_buffer_state

      result.is_a?(String) ? ERB::Util.h(result) : result
    end
  end

  class ERBView < RubyTemplateView
    include ERBCapture

    def h(input)
      Erubi.h(input)
    end

    def partial(partial_name, options = {})
      options.merge!(options[:locals]) if options[:locals]
      options[:content] = yield if block_given?

      partial_segments = partial_name.split("/")
      partial_segments.last.sub!(%r!^!, "_")
      partial_name = partial_segments.join("/")

      Tilt::ErubiTemplate.new(
        site.in_source_dir(site.config[:partials_dir], "#{partial_name}.erb"),
        outvar: "@_erbout",
        bufval: "Bridgetown::OutputBuffer.new",
        engine_class: ERBEngine
      ).render(self, options)
    end
  end

  module Converters
    class ERBTemplates < Converter
      priority :highest
      input :erb

      # Logic to do the ERB content conversion.
      #
      # @param content [String] Content of the file (without front matter).
      # @param convertible [
      #   Bridgetown::GeneratedPage, Bridgetown::Resource::Base, Bridgetown::Layout]
      #   The instantiated object which is processing the file.
      #
      # @return [String] The converted content.
      def convert(content, convertible)
        return content if convertible.data[:template_engine].to_s != "erb"

        erb_view = Bridgetown::ERBView.new(convertible)

        erb_renderer = Tilt::ErubiTemplate.new(
          convertible.relative_path,
          line_start(convertible),
          outvar: "@_erbout",
          bufval: "Bridgetown::OutputBuffer.new",
          engine_class: ERBEngine
        ) { content }

        if convertible.is_a?(Bridgetown::Layout)
          erb_renderer.render(erb_view) do
            convertible.current_document_output.html_safe
          end
        else
          erb_renderer.render(erb_view)
        end
      end

      # @param ext [String]
      # @param convertible [Bridgetown::Resource::Base, Bridgetown::GeneratedPage]
      def matches(ext, convertible)
        if convertible.data[:template_engine].to_s == "erb" ||
            (convertible.data[:template_engine].nil? &&
             @config[:template_engine].to_s == "erb")
          convertible.data[:template_engine] = "erb"
          return true
        end

        super(ext).tap do |ext_matches|
          convertible.data[:template_engine] = "erb" if ext_matches
        end
      end

      def output_ext(ext)
        ext == ".erb" ? ".html" : ext
      end
    end
  end
end
