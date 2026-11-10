Code.require_file(
  "dev_support/credo_checks/html_tags.ex",
  Path.join(__DIR__, "../../..")
)

Code.require_file(
  "dev_support/credo_checks/no_native_pickers.ex",
  Path.join(__DIR__, "../../..")
)

defmodule CredoChecks.NoNativePickersTest do
  use Credo.Test.Case, async: false

  alias CredoChecks.NoNativePickers

  @moduletag :dev_support

  setup_all do
    Application.ensure_all_started(:credo)
    :ok
  end

  defp template(body) do
    """
    defmodule TymeslotWeb.SomeLive do
      def render(assigns) do
        ~H\"\"\"
        #{body}
        \"\"\"
      end
    end
    """
  end

  defp check(body) do
    body
    |> template()
    |> to_source_file("lib/tymeslot_web/live/some_live.ex")
    |> run_check(NoNativePickers)
  end

  test "flags a raw colour input" do
    ~s(<input type="color" name="c" />)
    |> check()
    |> assert_issue(fn issue -> assert issue.trigger == "<input" end)
  end

  test "flags the core input component with the colour type" do
    ~s(<.input type="color" name="c" />)
    |> check()
    |> assert_issue(fn issue -> assert issue.trigger == "<.input" end)
  end

  test "flags a colour type the formatter wrapped, written as an expression" do
    ~s(<Forms.input\n  name="c"\n  type={"color"}\n/>)
    |> check()
    |> assert_issue()
  end

  test "flags an alias-qualified input with the colour type" do
    ~s(<CoreComponents.input type="color" name="c" />)
    |> check()
    |> assert_issue(fn issue -> assert issue.trigger == "<CoreComponents.input" end)
  end

  test "leaves the restyled range slider alone" do
    ~s(<input data-cp="hue" type="range" min="0" max="360" />)
    |> check()
    |> refute_issues()
  end

  test "leaves other input types alone" do
    ~s(<.input type="text" name="c" />)
    |> check()
    |> refute_issues()
  end
end
