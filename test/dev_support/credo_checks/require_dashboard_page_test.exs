Code.require_file(
  "dev_support/credo_checks/require_dashboard_page.ex",
  Path.join(__DIR__, "../../..")
)

defmodule CredoChecks.RequireDashboardPageTest do
  use Credo.Test.Case, async: false

  alias CredoChecks.RequireDashboardPage

  @moduletag :dev_support

  setup_all do
    Application.ensure_all_started(:credo)
    :ok
  end

  defp source(body) do
    """
    defmodule TymeslotWeb.Dashboard.PollsComponent do
      def render(assigns) do
        ~H\"\"\"
        <div>
          #{body}
        </div>
        \"\"\"
      end
    end
    """
  end

  test "flags a dashboard page component that renders no dashboard_page" do
    ~s(<.section_header title="Polls" />)
    |> source()
    |> to_source_file("lib/tymeslot_web/live/dashboard/polls/polls_component.ex")
    |> run_check(RequireDashboardPage)
    |> assert_issue()
  end

  test "flags an overlay's dashboard page component too" do
    ~s(<.section_header title="Subscription" />)
    |> source()
    |> to_source_file("lib/tymeslot_saas_web/live/dashboard/subscription_component.ex")
    |> run_check(RequireDashboardPage)
    |> assert_issue()
  end

  test "accepts a page component rendered inside dashboard_page" do
    ~s(<.dashboard_page title="Polls"><p>Body</p></.dashboard_page>)
    |> source()
    |> to_source_file("lib/tymeslot_web/live/dashboard/polls/polls_component.ex")
    |> run_check(RequireDashboardPage)
    |> refute_issues()
  end

  test "leaves a helper the page renders on its behalf alone" do
    ~s(<.section_header level={2} title="Create Webhook" />)
    |> source()
    |> to_source_file("lib/tymeslot_web/live/dashboard/automation/webhook_form_component.ex")
    |> run_check(RequireDashboardPage)
    |> refute_issues()
  end
end
