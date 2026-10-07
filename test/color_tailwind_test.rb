# frozen_string_literal: true

require "minitest/autorun"
require "set"
require_relative "#{File.expand_path('../scripts', __dir__)}/color_tailwind"

class ColorTailwindTest < Minitest::Test
  TOKENS = Set["--brand", "--primary"].freeze

  def statuses(value, tokens: TOKENS)
    ColorTailwind.findings(value, tokens: tokens).map { |e| [ e.text, e.status ] }
  end

  def test_every_frozen_prefix_reports_a_palette_class
    ColorTailwind::PREFIXES.each do |prefix|
      cls = "#{prefix}-red-500"
      assert_equal [ [ cls, :finding ] ], statuses(cls), cls
    end
  end

  def test_every_frozen_prefix_reports_black_and_white
    ColorTailwind::PREFIXES.each do |prefix|
      %w[black white].each do |word|
        cls = "#{prefix}-#{word}"
        assert_equal [ [ cls, :finding ] ], statuses(cls), cls
      end
    end
  end

  def test_table
    {
      "bg-[#abc]" => :finding,
      "text-[rgb(1,2,3)]" => :finding,
      "border-[color:#fff]" => :finding,
      "bg-[rgb(1_2_3)]" => :finding,
      "hover:bg-red-500/50" => :finding,
      "bg-red-500/[0.3]" => :finding,
      "!bg-black" => :finding,
      "bg-black!" => :finding,
      "md:dark:text-white" => :finding,
      "[&:hover]:bg-sky-200" => :finding,
      "decoration-sky-500" => :finding,
      "ring-offset-slate-50" => :finding,
      "bg-current" => :exempt,
      "text-transparent" => :exempt,
      "fill-inherit" => :exempt,
      "bg-brand" => :exempt,
      "bg-[var(--brand)]" => :exempt,
      "bg-[var(--nope)]" => :unresolved,
      "bg-nope" => :unresolved
    }.each do |cls, want|
      assert_equal [ [ cls, want ] ], statuses(cls), cls
    end
  end

  def test_unknown_word_is_unresolved_without_the_token
    assert_equal [ [ "bg-brand", :unresolved ] ], statuses("bg-brand", tokens: Set.new)
    entry = ColorTailwind.findings("bg-brand").first
    assert_equal "unknown Tailwind color word", entry.reason
  end

  def test_non_color_utilities_are_skipped
    %w[text-sm text-2xl text-center border-2 border-x-4 ring-1 shadow-md outline-none
       decoration-2 border-dashed from-10% bg-[3px] w-[#abc] p-4 flex].each do |cls|
      assert_empty statuses(cls), cls
    end
  end

  def test_one_entry_per_utility_text_is_the_utility
    value = "flex  bg-slate-100\ttext-blue-600 p-2 bg-primary\nhover:ring-red-500"
    assert_equal [ [ "bg-slate-100", :finding ], [ "text-blue-600", :finding ],
                   [ "bg-primary", :exempt ], [ "hover:ring-red-500", :finding ] ], statuses(value)
  end

  def test_longest_prefix_wins
    assert_equal [ [ "border-t-red-500", :finding ] ], statuses("border-t-red-500")
    assert_equal [ [ "inset-ring-white", :finding ] ], statuses("inset-ring-white")
  end
end
