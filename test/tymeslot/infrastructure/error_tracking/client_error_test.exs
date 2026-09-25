defmodule Tymeslot.Infrastructure.ErrorTracking.ClientErrorTest do
  use ExUnit.Case, async: true

  @moduletag :infrastructure
  @moduletag :unit

  import ExUnit.CaptureLog

  alias Tymeslot.Infrastructure.ErrorTracking.ClientError

  defmodule MisconfiguredError do
    defexception message: "bad status", plug_status: :not_a_status
  end

  # The context shapes ErrorTracker's integrations record.
  @request %{"request.path" => "/jane/30min", "request.method" => "GET"}
  @live_view %{"live_view.view" => "TymeslotWeb.DashboardLive", "user_id" => 7}
  @job %{"job.worker" => "Tymeslot.Workers.WebhookWorker", "job.id" => 1}

  describe "client_error_kind?/2" do
    test "is true for a 4xx exception raised serving a request or a LiveView" do
      assert ClientError.client_error_kind?("Elixir.Plug.Parsers.ParseError", @request)
      assert ClientError.client_error_kind?("Elixir.Phoenix.Router.MalformedURIError", @request)
      assert ClientError.client_error_kind?("Elixir.Plug.Conn.InvalidQueryError", @request)
      assert ClientError.client_error_kind?("Elixir.Ecto.NoResultsError", @live_view)
    end

    test "is false for a 4xx exception raised outside a request" do
      refute ClientError.client_error_kind?("Elixir.Ecto.NoResultsError", @job)
      refute ClientError.client_error_kind?("Elixir.Ecto.NoResultsError", %{})
    end

    test "is false for a job context even when request keys are present" do
      refute ClientError.client_error_kind?(
               "Elixir.Ecto.NoResultsError",
               Map.merge(@request, @job)
             )
    end

    test "is false, with a warning, when the status cannot be resolved" do
      log =
        capture_log(fn ->
          refute ClientError.client_error_kind?(Atom.to_string(MisconfiguredError), @request)
        end)

      assert log =~ "Could not tell whether an exception is a client error"
    end

    test "resolves the exception module from its name" do
      assert ClientError.client_error_kind?("Elixir.Plug.BadRequestError", @request)
      refute ClientError.client_error_kind?("Elixir.Plug.BadRequestError", @job)
      refute ClientError.client_error_kind?("Elixir.RuntimeError", @request)
    end

    test "is false for a module that is not an exception" do
      refute ClientError.client_error_kind?("Elixir.Enum", @request)
    end

    test "is false, with a warning, for a name that is not an existing atom" do
      log =
        capture_log(fn ->
          refute ClientError.client_error_kind?(
                   "Elixir.Tymeslot.NoSuchModuleEverDefined",
                   @request
                 )
        end)

      assert log =~ "Could not tell whether an exception is a client error"
    end
  end

  describe "request_origin?/1" do
    test "is true for request and LiveView contexts only" do
      assert ClientError.request_origin?(@request)
      assert ClientError.request_origin?(@live_view)
      refute ClientError.request_origin?(@job)
      refute ClientError.request_origin?(%{"user_id" => 7})
      refute ClientError.request_origin?(%{})
    end
  end
end
