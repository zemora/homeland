# frozen_string_literal: true

module Homeland
  class Pipeline
    class MathFilter < HTML::Pipeline::TextFilter
      MATH_REGEXP_BLOCK = /\$\$(.*?)\$\$(\s*?\n)?/m
      MATH_REGEXP_INLINE = /\$(.*?)\$/

      def call
        @text.gsub!(MATH_REGEXP_INLINE) do |str|
          str == "$$" ? str : escape_content(str)
        end
        @text.gsub!(MATH_REGEXP_BLOCK) do |str|
          %(<p>#{escape_content(str)}</p>\n)
        end
        @text
      end

      def escape_content(str)
        str.gsub("<", "&lt;").gsub(">", "&gt;").gsub("\\", "&#92;").gsub("_", "&#95;")
      end
    end
  end
end
