defmodule TymeslotWeb.Themes.Core.ContextLayoutTest do
  @moduledoc """
  Covers the layout resolution rules in `Themes.Core.Context.from_params/2`.

  Three signals can pick the layout:

  1. Explicit `?layout=column` always wins.
  2. Otherwise, `?embed=1` (the marker embed.js puts on every iframe URL)
     defaults the layout to `:column` — wide canvas adapts to any container.
  3. Otherwise, the struct's zero value (`:default`, centred) applies.

  An explicit `?layout=default` opts back into the centred view even when
  `?embed=1` would have selected column.
  """
  use ExUnit.Case, async: true
  @moduletag :themes
  @moduletag :unit

  alias TymeslotWeb.Themes.Core.Context

  describe "from_params/2 — standalone (no embed marker)" do
    test "defaults to :default when no params are present" do
      context = Context.from_params(%{})

      assert %Context{layout: :default} = context
    end

    test "switches to :column when layout=column is passed" do
      context = Context.from_params(%{"layout" => "column"})

      assert %Context{layout: :column} = context
    end

    test "ignores layout values outside the allowlist" do
      for invalid <- ["mosaic", "wide", "", "COLUMN", "Default", "default;"] do
        context = Context.from_params(%{"layout" => invalid})

        assert %Context{layout: :default} = context,
               "expected layout #{inspect(invalid)} to fall back to :default"
      end
    end
  end

  describe "from_params/2 — embedded (?embed=1)" do
    test "defaults to :column when embed=1 is present and no layout is set" do
      context = Context.from_params(%{"embed" => "1"})

      assert %Context{layout: :column} = context
    end

    test "explicit layout=column with embed=1 stays :column" do
      context = Context.from_params(%{"embed" => "1", "layout" => "column"})

      assert %Context{layout: :column} = context
    end

    test "explicit layout=default with embed=1 opts back into :default" do
      context = Context.from_params(%{"embed" => "1", "layout" => "default"})

      assert %Context{layout: :default} = context
    end

    test "invalid layout with embed=1 still falls back to :default" do
      # The explicit-layout clause matches before the embed clause, and any
      # non-"column" string falls through to the struct default. This keeps
      # the contract predictable for clients sending malformed values.
      context = Context.from_params(%{"embed" => "1", "layout" => "mosaic"})

      assert %Context{layout: :default} = context
    end

    test "embed=0 does not activate column layout" do
      # Only the literal value "1" matches the embed clause — any other value
      # must not silently enable column layout, matching EmbedTokenPlug semantics.
      context = Context.from_params(%{"embed" => "0"})

      assert %Context{layout: :default} = context
    end

    test "embed with empty string does not activate column layout" do
      context = Context.from_params(%{"embed" => ""})

      assert %Context{layout: :default} = context
    end
  end

  describe "from_params/2 — to_assigns" do
    test "exposes the layout for the root template under :embed_layout" do
      context = Context.from_params(%{"layout" => "column"})
      assigns = Context.to_assigns(context)

      # `:layout` is reserved by Phoenix.Template — must surface as :embed_layout
      assert assigns.embed_layout == :column
      refute Map.has_key?(assigns, :layout)
    end
  end
end
