Code.require_file(
  "dev_support/credo_checks/no_inline_svg.ex",
  Path.join(__DIR__, "../../..")
)

defmodule CredoChecks.NoInlineSvgTest do
  use Credo.Test.Case, async: false

  alias CredoChecks.NoInlineSvg

  @moduletag :dev_support

  setup_all do
    Application.ensure_all_started(:credo)
    :ok
  end

  describe "flagged cases" do
    test "flags a hand-written svg in a ~H template" do
      ~S'''
      defmodule TymeslotWeb.Widget do
        use Phoenix.Component

        def tick(assigns) do
          ~H"""
          <svg class="w-5 h-5" fill="none" stroke="currentColor" viewBox="0 0 24 24">
            <path d="M5 13l4 4L19 7" />
          </svg>
          """
        end
      end
      '''
      |> to_source_file("lib/tymeslot_web/widget.ex")
      |> run_check(NoInlineSvg)
      |> assert_issue(fn issue -> assert issue.line_no == 6 end)
    end

    test "flags an svg tag the formatter split after its name" do
      ~S'''
      defmodule TymeslotWeb.Widget do
        def tick(assigns) do
          ~H"""
          <svg
            class="w-5 h-5"
          >
          </svg>
          """
        end
      end
      '''
      |> to_source_file("lib/tymeslot_web/widget.ex")
      |> run_check(NoInlineSvg)
      |> assert_issue()
    end
  end

  describe "accepted cases" do
    test "accepts the icon component" do
      ~S'''
      defmodule TymeslotWeb.Widget do
        def tick(assigns) do
          ~H"""
          <.icon name="hero-check" class="w-5 h-5" />
          """
        end
      end
      '''
      |> to_source_file("lib/tymeslot_web/widget.ex")
      |> run_check(NoInlineSvg)
      |> refute_issues()
    end

    test "accepts prose that names the element" do
      ~S'''
      defmodule TymeslotWeb.Widget do
        @moduledoc "Renders a complete `<svg>` of its own."
      end
      '''
      |> to_source_file("lib/tymeslot_web/widget.ex")
      |> run_check(NoInlineSvg)
      |> refute_issues()
    end

    test "accepts a file listed in allowed_files" do
      ~S'''
      defmodule TymeslotWeb.Chart do
        def chart(assigns), do: ~H|<svg viewBox="0 0 10 10"></svg>|
      end
      '''
      |> to_source_file("lib/tymeslot_web/chart.ex")
      |> run_check(NoInlineSvg, allowed_files: ["lib/tymeslot_web/chart.ex"])
      |> refute_issues()
    end

    test "ignores files outside lib/" do
      ~S'''
      defmodule TymeslotWeb.WidgetTest do
        test "renders", do: assert(html =~ ~s(<svg class="w-5"))
      end
      '''
      |> to_source_file("test/tymeslot_web/widget_test.exs")
      |> run_check(NoInlineSvg)
      |> refute_issues()
    end
  end
end
