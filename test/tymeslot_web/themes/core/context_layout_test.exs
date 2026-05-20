defmodule TymeslotWeb.Themes.Core.ContextLayoutTest do
  @moduledoc """
  Covers the `layout` allowlist in `Themes.Core.Context.from_params/2`.
  """
  use ExUnit.Case, async: true
  @moduletag :themes
  @moduletag :unit

  alias TymeslotWeb.Themes.Core.Context

  describe "from_params/2 — layout" do
    test "defaults to :default when no layout param is present" do
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

    test "to_assigns/1 exposes the layout for the root template under :embed_layout" do
      context = Context.from_params(%{"layout" => "column"})
      assigns = Context.to_assigns(context)

      # `:layout` is reserved by Phoenix.Template — must surface as :embed_layout
      assert assigns.embed_layout == :column
      refute Map.has_key?(assigns, :layout)
    end
  end
end
