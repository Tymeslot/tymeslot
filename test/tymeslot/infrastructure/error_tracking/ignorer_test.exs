defmodule Tymeslot.Infrastructure.ErrorTracking.IgnorerTest do
  use ExUnit.Case, async: true

  @moduletag :infrastructure
  @moduletag :unit

  import ExUnit.CaptureLog

  alias ErrorTracker.Error
  alias Tymeslot.Infrastructure.ErrorTracking.Ignorer

  defmodule ServerFaultError do
    defexception message: "upstream broke", plug_status: 500
  end

  # ErrorTracker records an exception's kind as `to_string(module)`.
  defp error_for(module), do: %Error{kind: to_string(module)}

  # The context shapes ErrorTracker's integrations record.
  @request %{"request.path" => "/jane/30min", "request.method" => "GET"}
  @live_view %{"live_view.view" => "TymeslotWeb.DashboardLive"}
  @job %{"job.worker" => "Tymeslot.Workers.WebhookWorker", "job.id" => 1}

  describe "ignore?/2" do
    test "ignores client errors raised by Plug and Phoenix while serving a request" do
      for module <- [
            Plug.CSRFProtection.InvalidCSRFTokenError,
            Phoenix.Router.NoRouteError,
            Phoenix.NotAcceptableError
          ] do
        assert Ignorer.ignore?(error_for(module), @request), "expected #{inspect(module)} ignored"
      end
    end

    test "ignores a lookup that found no record while serving a request or a LiveView" do
      assert Ignorer.ignore?(error_for(Ecto.NoResultsError), @request)
      assert Ignorer.ignore?(error_for(Ecto.NoResultsError), @live_view)
    end

    test "tracks the same lookup failure raised in an Oban job" do
      refute Ignorer.ignore?(error_for(Ecto.NoResultsError), @job)
    end

    test "tracks the same lookup failure with no request context at all" do
      refute Ignorer.ignore?(error_for(Ecto.NoResultsError), %{})
    end

    test "tracks a genuine server error raised serving a request" do
      refute Ignorer.ignore?(error_for(RuntimeError), @request)
    end

    test "tracks an exception whose plug_status is a server error" do
      refute Ignorer.ignore?(error_for(ServerFaultError), @request)
    end

    test "tracks a non-exception kind such as an Oban job's error tuple" do
      refute Ignorer.ignore?(%Error{kind: "error"}, @request)
    end

    test "tracks a kind naming no loaded module" do
      capture_log(fn ->
        refute Ignorer.ignore?(%Error{kind: "Elixir.Tymeslot.NoSuchModuleEverDefined"}, @request)
      end)
    end

    test "ignores an event no handle_event/3 clause of a LiveView matches" do
      error = %Error{
        kind: "Elixir.FunctionClauseError",
        reason: "no function clause matching in TymeslotWeb.DashboardLive.handle_event/3"
      }

      assert Ignorer.ignore?(error, Map.put(@live_view, "live_view.event", "forged"))
    end

    test "tracks a function clause error raised inside a matched handle_event/3 clause" do
      error = %Error{
        kind: "Elixir.FunctionClauseError",
        reason: "no function clause matching in Tymeslot.Onboarding.toggle/2"
      }

      refute Ignorer.ignore?(error, @live_view)
    end

    test "tracks the error and logs a warning when the ignorer itself fails" do
      log =
        capture_log(fn ->
          refute Ignorer.ignore?(%{not: "an error"}, %{"password" => "hunter2"})
        end)

      assert log =~ "ErrorTracker ignorer failed"
      refute log =~ "hunter2"
    end
  end
end
