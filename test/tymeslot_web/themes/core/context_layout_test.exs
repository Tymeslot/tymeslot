defmodule TymeslotWeb.Themes.Core.ContextLayoutTest do
  @moduledoc """
  Covers the layout resolution rules in `Themes.Core.Context.from_params/2`.

  Layout is opt-in:

  1. Explicit `?layout=column` selects the wide-canvas `:column` layout.
  2. Everything else — no params, `?embed=1` with no layout, `?layout=default`,
     or any invalid value — resolves to the struct's zero value (`:default`,
     centred).

  Crucially, `?embed=1` does NOT imply column. This is back-compat: embed
  snippets deployed before the column layout shipped carry no `data-layout`, so
  embed.js generates their iframe URL with `?embed=1` but no `?layout=`.
  Defaulting those to column would silently flip every already-embedded booking
  page to the wide layout on upgrade. Column is reached only when a newly
  generated snippet emits `data-layout="column"` → `?layout=column`.
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
    test "defaults to :default when embed=1 is present and no layout is set (back-compat)" do
      # Legacy snippets carry no data-layout, so embed.js sends ?embed=1 with no
      # ?layout=. These must keep the old centred default on upgrade — not flip
      # to column.
      context = Context.from_params(%{"embed" => "1"})

      assert %Context{layout: :default} = context
    end

    test "explicit layout=column with embed=1 selects :column" do
      context = Context.from_params(%{"embed" => "1", "layout" => "column"})

      assert %Context{layout: :column} = context
    end

    test "explicit layout=default with embed=1 stays :default" do
      context = Context.from_params(%{"embed" => "1", "layout" => "default"})

      assert %Context{layout: :default} = context
    end

    test "invalid layout with embed=1 falls back to :default" do
      # Any non-"column" string (including malformed values) resolves to the
      # struct default. Predictable contract for clients sending junk.
      context = Context.from_params(%{"embed" => "1", "layout" => "mosaic"})

      assert %Context{layout: :default} = context
    end

    test "embed=0 keeps :default" do
      context = Context.from_params(%{"embed" => "0"})

      assert %Context{layout: :default} = context
    end

    test "embed with empty string keeps :default" do
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
