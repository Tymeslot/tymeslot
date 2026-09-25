Code.require_file(
  "dev_support/credo_checks/web_layer_boundary.ex",
  Path.join(__DIR__, "../../..")
)

defmodule CredoChecks.WebLayerBoundaryTest do
  use Credo.Test.Case, async: false

  alias CredoChecks.WebLayerBoundary

  @moduletag :dev_support

  @web_file "lib/tymeslot_web/live/dashboard/some_component.ex"

  setup_all do
    Application.ensure_all_started(:credo)
    :ok
  end

  defp check(source, filename \\ @web_file, params \\ []) do
    source
    |> to_source_file(filename)
    |> run_check(WebLayerBoundary, params)
  end

  describe "query modules" do
    test "a plain alias is flagged at the alias, naming the module" do
      """
      defmodule TymeslotWeb.SomeComponent do
        alias Tymeslot.Meetings.MeetingQueries

        def count(id), do: MeetingQueries.count_awaiting_approval_for_organizer(id)
      end
      """
      |> check()
      |> assert_issue(fn issue ->
        assert issue.line_no == 2
        assert issue.trigger == "Tymeslot.Meetings.MeetingQueries"
        assert issue.message =~ "`Tymeslot.Meetings.MeetingQueries`"
        assert issue.message =~ "public API"
      end)
    end

    test "a multi-alias entry is flagged" do
      """
      defmodule TymeslotWeb.SomeComponent do
        alias Tymeslot.Polls.{Poll, PollParticipantQueries}

        def load(token), do: PollParticipantQueries.get_by_token(token)
      end
      """
      |> check()
      |> assert_issue(fn issue ->
        assert issue.trigger == "PollParticipantQueries"
        assert issue.message =~ "`Tymeslot.Polls.PollParticipantQueries`"
      end)
    end

    test "an alias renamed with as: is flagged" do
      """
      defmodule TymeslotWeb.SomeComponent do
        alias Tymeslot.Meetings.MeetingQueries, as: Q

        def load(id), do: Q.get_meeting(id)
      end
      """
      |> check()
      |> assert_issue(fn issue ->
        assert issue.line_no == 2
        assert issue.message =~ "`Tymeslot.Meetings.MeetingQueries`"
      end)
    end

    test "an import is flagged" do
      """
      defmodule TymeslotWeb.SomeComponent do
        import Tymeslot.Meetings.MeetingQueries

        def load(id), do: get_meeting(id)
      end
      """
      |> check()
      |> assert_issue()
    end

    test "a fully-qualified call is flagged" do
      """
      defmodule TymeslotWeb.SomeComponent do
        def load(id), do: Tymeslot.Meetings.MeetingQueries.get_meeting(id)
      end
      """
      |> check()
      |> assert_issue(fn issue ->
        assert issue.line_no == 2
        assert issue.trigger == "Tymeslot.Meetings.MeetingQueries.get_meeting"
      end)
    end

    test "a call reaching the query module through an aliased parent is flagged" do
      """
      defmodule TymeslotWeb.SomeComponent do
        alias Tymeslot.Meetings

        def load(id), do: Meetings.MeetingQueries.get_meeting(id)
      end
      """
      |> check()
      |> assert_issue(fn issue ->
        assert issue.message =~ "`Tymeslot.Meetings.MeetingQueries`"
      end)
    end

    test "a function capture of a query module is flagged" do
      """
      defmodule TymeslotWeb.SomeComponent do
        def loader, do: &Tymeslot.Meetings.MeetingQueries.get_meeting/1
      end
      """
      |> check()
      |> assert_issue()
    end
  end

  describe "enqueuing jobs" do
    test "a piped Oban.insert after a Worker.new on an aliased worker flags both" do
      """
      defmodule TymeslotWeb.SomeComponent do
        alias Tymeslot.Workers.SyncIcsCalendarWorker

        def sync(id) do
          %{"integration_id" => id}
          |> SyncIcsCalendarWorker.new()
          |> Oban.insert()
        end
      end
      """
      |> check()
      |> assert_issues(fn issues ->
        assert issues |> Enum.map(& &1.line_no) |> Enum.sort() == [6, 7]
        assert Enum.any?(issues, &(&1.message =~ "`Tymeslot.Workers.SyncIcsCalendarWorker.new`"))
        assert Enum.any?(issues, &(&1.trigger == "Oban.insert"))
      end)
    end

    test "Oban.insert!/2 and Oban.insert_all/1 are flagged" do
      """
      defmodule TymeslotWeb.SomeController do
        def enqueue(job, jobs) do
          Oban.insert!(job, timeout: 5000)
          Oban.insert_all(jobs)
        end
      end
      """
      |> check("lib/tymeslot_web/controllers/some_controller.ex")
      |> assert_issues(fn issues -> assert length(issues) == 2 end)
    end

    test "a literal Worker.new is flagged" do
      """
      defmodule TymeslotWeb.SomeController do
        def build(id), do: Tymeslot.Workers.SyncGoogleCalendarWorker.new(%{"id" => id})
      end
      """
      |> check("lib/tymeslot_web/controllers/some_controller.ex")
      |> assert_issue(fn issue ->
        assert issue.trigger == "Tymeslot.Workers.SyncGoogleCalendarWorker.new"
      end)
    end

    # Not every worker is named `*Worker`: `TokenRefreshJob`, and the modules
    # under a `Workers` namespace such as `Tymeslot.Workers.VideoTranscoder`.
    test "new/1 on a *Job module or a module under a Workers namespace is flagged" do
      """
      defmodule TymeslotWeb.SomeController do
        alias Tymeslot.Integrations.Calendar.TokenRefreshJob
        alias Tymeslot.Workers.VideoTranscoder

        def build(args) do
          {TokenRefreshJob.new(args), VideoTranscoder.new(args)}
        end
      end
      """
      |> check("lib/tymeslot_web/controllers/some_controller.ex")
      |> assert_issues(fn issues -> assert length(issues) == 2 end)
    end

    test "other Oban functions are not flagged" do
      """
      defmodule TymeslotWeb.HealthcheckController do
        def queues, do: Oban.check_all_queues()
      end
      """
      |> check("lib/tymeslot_web/controllers/healthcheck_controller.ex")
      |> refute_issues()
    end

    test "new/1 on a non-worker module is not flagged" do
      """
      defmodule TymeslotWeb.SomeComponent do
        def build(list), do: {MapSet.new(list), URI.new("https://example.com")}
      end
      """
      |> check()
      |> refute_issues()
    end
  end

  describe "forbidden modules" do
    test "an alias of Calendar.Operations renamed with as: is flagged" do
      """
      defmodule TymeslotWeb.CalendarGrid.EventDelete do
        alias Tymeslot.Integrations.Calendar.Operations, as: EventOperations

        def delete(uid, ctx), do: EventOperations.delete_event(uid, ctx)
      end
      """
      |> check()
      |> assert_issue(fn issue ->
        assert issue.line_no == 2
        assert issue.message =~ "`Tymeslot.Integrations.Calendar.Operations`"
      end)
    end

    test "a fully-qualified call to Calendar.Operations is flagged" do
      """
      defmodule TymeslotWeb.CalendarGrid.EventDelete do
        def delete(uid, ctx), do: Tymeslot.Integrations.Calendar.Operations.delete_event(uid, ctx)
      end
      """
      |> check()
      |> assert_issue(fn issue ->
        assert issue.trigger == "Tymeslot.Integrations.Calendar.Operations.delete_event"
      end)
    end

    test "a module below the Calendar.Runtime namespace is flagged" do
      """
      defmodule TymeslotWeb.SomeComponent do
        alias Tymeslot.Integrations.Calendar.Runtime.ClientManager

        def client(meeting), do: ClientManager.client_for(meeting)
      end
      """
      |> check()
      |> assert_issue()
    end

    # The base of a multi-alias has the shape of a remote call; it must not be
    # reported on top of the entries themselves.
    test "a multi-alias under a forbidden namespace is flagged once per entry" do
      """
      defmodule TymeslotWeb.SomeComponent do
        alias Tymeslot.Integrations.Calendar.Runtime.{ClientManager, EventFetcher}
      end
      """
      |> check()
      |> assert_issues(fn issues ->
        assert issues |> Enum.map(& &1.trigger) |> Enum.sort() == [
                 "ClientManager",
                 "EventFetcher"
               ]
      end)
    end

    test "the :forbidden_modules param replaces the default list" do
      source = """
      defmodule TymeslotWeb.SomeComponent do
        alias Tymeslot.Integrations.Calendar.Operations
        alias Tymeslot.Some.Internal

        def go, do: {Operations.x(), Internal.y()}
      end
      """

      source
      |> check(@web_file, forbidden_modules: [Tymeslot.Some.Internal])
      |> assert_issue(fn issue -> assert issue.message =~ "`Tymeslot.Some.Internal`" end)
    end
  end

  describe "not flagged" do
    test "schema modules used for structs and pattern matching" do
      """
      defmodule TymeslotWeb.SomeComponent do
        alias Tymeslot.DatabaseSchemas.MeetingSchema
        alias Tymeslot.Meetings.MeetingSchema, as: Meeting

        def pending?(%MeetingSchema{status: "pending"}), do: true
        def pending?(%Meeting{}), do: false
      end
      """
      |> check()
      |> refute_issues()
    end

    test "context and sibling feature modules" do
      """
      defmodule TymeslotWeb.SomeComponent do
        alias Tymeslot.Integrations.Calendar
        alias Tymeslot.Integrations.Calendar.Events
        alias Tymeslot.Meetings

        def load(user, id) do
          {Meetings.get_meeting_for_user(user, id), Calendar.list(user), Events.update(id)}
        end
      end
      """
      |> check()
      |> refute_issues()
    end

    test "Repo calls, which RepoCallBoundary already reports" do
      """
      defmodule TymeslotWeb.SomeComponent do
        alias Tymeslot.Repo

        def load(id), do: Repo.get(Meeting, id)
      end
      """
      |> check()
      |> refute_issues()
    end

    test "a web-namespace module whose name ends in Queries" do
      """
      defmodule TymeslotWeb.SomeComponent do
        alias TymeslotWeb.Dashboard.FilterQueries

        def parse(params), do: FilterQueries.parse(params)
      end
      """
      |> check()
      |> refute_issues()
    end

    test "query modules, workers and Oban mentioned only in comments and docs" do
      """
      defmodule TymeslotWeb.SomeComponent do
        @moduledoc \"\"\"
        Previously called `Tymeslot.Meetings.MeetingQueries.get_meeting/1` and
        `SyncIcsCalendarWorker.new() |> Oban.insert()` directly.
        \"\"\"

        # MeetingQueries.count_awaiting_approval_for_organizer/1 is wrapped by
        # Meetings; Tymeslot.Integrations.Calendar.Operations too.
        @doc "Wraps `Tymeslot.Integrations.Calendar.Operations.delete_event/2`."
        def count(id), do: Tymeslot.Meetings.count_awaiting_approval(id)
      end
      """
      |> check()
      |> refute_issues()
    end

    test "the same code outside the web layer" do
      """
      defmodule Tymeslot.Meetings do
        alias Tymeslot.Integrations.Calendar.Operations
        alias Tymeslot.Meetings.MeetingQueries
        alias Tymeslot.Workers.SyncIcsCalendarWorker

        def load(id), do: MeetingQueries.get_meeting(id)
        def sync(args), do: args |> SyncIcsCalendarWorker.new() |> Oban.insert()
        def delete(uid, ctx), do: Operations.delete_event(uid, ctx)
      end
      """
      |> check("lib/tymeslot/meetings.ex")
      |> refute_issues()
    end

    test "a test file" do
      """
      defmodule TymeslotWeb.SomeComponentTest do
        alias Tymeslot.Meetings.MeetingQueries

        test "loads", do: assert(MeetingQueries.get_meeting(1))
      end
      """
      |> check("test/tymeslot_web/live/dashboard/some_component_test.exs")
      |> refute_issues()
    end

    test "a filename matched by the :allowed param" do
      """
      defmodule TymeslotWeb.SomeComponent do
        alias Tymeslot.Meetings.MeetingQueries

        def load(id), do: MeetingQueries.get_meeting(id)
      end
      """
      |> check(@web_file, allowed: ["live/dashboard/some_component.ex"])
      |> refute_issues()
    end
  end

  describe "applies to both web namespaces" do
    test "a query module alias under lib/tymeslot_saas_web/ is flagged" do
      """
      defmodule TymeslotSaasWeb.SomeLive do
        alias Tymeslot.Auth.UserQueries

        def load(id), do: UserQueries.get_user(id)
      end
      """
      |> check("lib/tymeslot_saas_web/live/some_live.ex")
      |> assert_issue()
    end
  end
end
