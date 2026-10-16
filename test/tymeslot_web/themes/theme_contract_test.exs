defmodule TymeslotWeb.Themes.ThemeContractTest do
  @moduledoc """
  Holds every theme in `ThemeTestMatrix` to the theme contract: its LiveView,
  its picker metadata, and its meeting, poll and payment pages. A new theme is
  covered by adding it to the matrix. So is the test-only fixture theme, which
  is how this file proves the contract holds for a theme shaped unlike Quill
  and Rhythm.
  """

  use TymeslotWeb.ConnCase, async: true

  @moduletag :themes
  @moduletag :unit

  alias TymeslotWeb.ThemeCommonTestCases, as: Contract
  alias TymeslotWeb.Themes.Core.ThemeInfo
  alias TymeslotWeb.ThemeTestMatrix

  test "the matrix is not empty" do
    assert ThemeTestMatrix.registered_ids() != []
  end

  for theme_id <- ThemeTestMatrix.registered_ids() do
    describe "theme #{theme_id}" do
      setup do
        module = ThemeInfo.get_theme_module(unquote(theme_id))
        assert module, "theme #{unquote(theme_id)} does not load"
        %{theme: module, assigns: Contract.build_meeting_assigns(unquote(theme_id))}
      end

      test "names a LiveView", %{theme: theme} do
        assert Contract.test_live_view_module(theme) == :ok
      end

      test "describes itself for the theme picker", %{theme: theme} do
        assert Contract.test_metadata(theme) == :ok
      end

      test "renders the meeting pages", %{theme: theme, assigns: assigns} do
        assert Contract.test_render_meeting_action(theme, assigns) == :ok
      end

      test "renders the poll page", %{theme: theme, assigns: assigns} do
        assert Contract.test_render_poll_action(theme, assigns) == :ok
      end

      test "renders the payment return pages", %{theme: theme, assigns: assigns} do
        assert Contract.test_render_payment_page(theme, assigns) == :ok
      end
    end
  end
end
