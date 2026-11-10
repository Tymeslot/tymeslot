Code.require_file(
  "dev_support/credo_checks/html_tags.ex",
  Path.join(__DIR__, "../../..")
)

Code.require_file(
  "dev_support/credo_checks/no_browser_validation.ex",
  Path.join(__DIR__, "../../..")
)

defmodule CredoChecks.NoBrowserValidationTest do
  use Credo.Test.Case, async: false

  alias CredoChecks.NoBrowserValidation

  @moduletag :dev_support

  setup_all do
    Application.ensure_all_started(:credo)
    :ok
  end

  defp check(body, opts \\ []) do
    filename = Keyword.get(opts, :filename, "lib/tymeslot_web/live/some_live.ex")

    """
    defmodule TymeslotWeb.SomeLive do
      def render(assigns) do
        ~H\"\"\"
        #{body}
        \"\"\"
      end
    end
    """
    |> to_source_file(filename)
    |> run_check(NoBrowserValidation, Keyword.take(opts, [:allowed_files]))
  end

  test "flags a form without novalidate" do
    ~s(<form phx-submit="save"></form>)
    |> check()
    |> assert_issue(fn issue -> assert issue.trigger == "<form" end)
  end

  test "flags a function-component form without novalidate, tag wrapped across lines" do
    "<.form\n  for={@form}\n  phx-change=\"v\"\n></.form>"
    |> check()
    |> assert_issue(fn issue -> assert issue.trigger == "<.form" end)
  end

  test "reads novalidate on a later line of a wrapped tag" do
    "<form\n  id=\"f\"\n  novalidate\n></form>"
    |> check()
    |> refute_issues()
  end

  test "form_wrapper and auth_form default on, so only an opt-out is flagged" do
    ~s(<.form_wrapper for={@f}></.form_wrapper>) |> check() |> refute_issues()
    ~s(<.auth_form action="/x"></.auth_form>) |> check() |> refute_issues()

    ~s(<.auth_form action="/x" novalidate={false}></.auth_form>)
    |> check()
    |> assert_issue()
  end

  test "treats novalidate={false} on a form as missing" do
    ~s(<form novalidate={false}></form>) |> check() |> assert_issue()
  end

  test "an allow-listed file may omit it" do
    ~s(<form phx-submit="save"></form>)
    |> check(
      filename: "lib/tymeslot_web/components/dashboard/integrations/video/jitsi_config.ex",
      allowed_files: ["video/jitsi_config.ex"]
    )
    |> refute_issues()
  end

  test "a bare <form> in prose is ignored" do
    "<form>" |> check() |> refute_issues()
  end

  test "skips dev controllers" do
    ~s(<form></form><form phx-submit="x"></form>)
    |> check(filename: "lib/tymeslot_web/controllers/dev/embed_test_html.ex")
    |> refute_issues()
  end
end
