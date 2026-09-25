defmodule Tymeslot.Infrastructure.ErrorTracking.ContextIntegrationTest do
  @moduledoc """
  An exception raised at each entry point (a controller action, a LiveView
  event, an Oban job) is stored with the request, user and job context the
  entry point set, so an occurrence can be traced to the user and the log
  lines around it.
  """

  # async: false: ErrorTracker's `enabled` switch is global application env.
  use TymeslotWeb.ConnCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :infrastructure
  @moduletag :integration

  import Ecto.Query
  import Mox
  import Phoenix.LiveViewTest
  import Tymeslot.ConfigTestHelpers
  import Tymeslot.DashboardTestHelpers

  alias ErrorTracker.Error
  alias ErrorTracker.Occurrence
  alias Tymeslot.MeetingPayments.StripeAdapterMock
  alias Tymeslot.Repo
  alias Tymeslot.Workers.ColourWriteBackWorker

  @uuid ~r/\A[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/

  setup :setup_dashboard_user
  setup :set_mox_from_context
  setup :verify_on_exit!

  setup do
    with_config(:error_tracker, enabled: true)
    :ok
  end

  describe "a controller action" do
    setup do
      with_config(:tymeslot,
        meeting_payments_enabled: true,
        feature_access_checker: Tymeslot.Features.DefaultAccessChecker
      )

      :ok
    end

    test "records the user, request id and correlation id", %{conn: conn, user: user} do
      expect(StripeAdapterMock, :create_account, fn _params, _opts -> raise "stripe exploded" end)

      request_id = "context-integration-request-0001"
      correlation_id = "context-integration-correlation-0001"

      conn =
        conn
        |> put_req_header("x-request-id", request_id)
        |> put_req_header("x-correlation-id", correlation_id)

      assert_error_sent 500, fn -> post(conn, ~p"/dashboard/payments/connect") end

      context = occurrence_context!("Elixir.RuntimeError")
      assert context["user_id"] == user.id
      assert context["request_id"] == request_id
      assert context["correlation_id"] == correlation_id
    end
  end

  describe "an error raised before the router" do
    setup do
      # The endpoint dispatches to the router named by `:router`; this one
      # raises the way a crashing endpoint plug would, outside every router.
      with_config(:tymeslot, router: __MODULE__.RaisingRouter)
      :ok
    end

    test "is recorded once, with the request and correlation ids", %{conn: conn} do
      request_id = "context-integration-request-0002"

      conn = put_req_header(conn, "x-request-id", request_id)

      assert_raise RuntimeError, "raised before the router", fn -> get(conn, "/anything") end

      context = occurrence_context!("Elixir.RuntimeError")
      assert context["request_id"] == request_id
      assert context["correlation_id"] =~ @uuid
      assert context["request.path"] == "/anything"
    end
  end

  describe "a LiveView event" do
    test "records the user and the LiveView's correlation id", %{conn: conn, user: user} do
      # The crash takes the LiveView down and, through the test link, the
      # test process with it unless exits are trapped.
      Process.flag(:trap_exit, true)
      {:ok, view, _html} = live(conn, ~p"/dashboard")

      # A client event without the `id` the handler matches on: a stale or
      # tampered client, and a genuine crash in `DashboardLive`.
      catch_exit(render_click(view, "onboarding:toggle", %{}))

      context = occurrence_context!("Elixir.FunctionClauseError")
      assert context["user_id"] == user.id
      assert context["correlation_id"] =~ @uuid
    end
  end

  describe "an Oban job" do
    test "records the user from the job args and the job's correlation id", %{user: user} do
      # A job enqueued before `colour` joined the args shape raises in `perform/1`.
      assert_raise MatchError, fn ->
        perform_job(ColourWriteBackWorker, %{
          "user_id" => user.id,
          "integration_id" => 1,
          "uid" => "event-uid"
        })
      end

      context = occurrence_context!("Elixir.MatchError")
      assert context["user_id"] == user.id
      assert context["correlation_id"] =~ @uuid
    end
  end

  defmodule RaisingRouter do
    @moduledoc false
    @behaviour Plug

    @impl Plug
    def init(opts), do: opts

    @impl Plug
    def call(_conn, _opts), do: raise("raised before the router")
  end

  defp occurrence_context!(kind) do
    assert [%Error{id: error_id}] = Repo.all(from e in Error, where: e.kind == ^kind)

    assert [%Occurrence{context: context}] =
             Repo.all(from o in Occurrence, where: o.error_id == ^error_id)

    context
  end
end
