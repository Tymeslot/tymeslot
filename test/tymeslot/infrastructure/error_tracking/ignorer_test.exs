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

  describe "ignore?/2" do
    test "ignores client errors raised by Plug and Phoenix" do
      for module <- [
            Plug.CSRFProtection.InvalidCSRFTokenError,
            Phoenix.Router.NoRouteError,
            Phoenix.NotAcceptableError
          ] do
        assert Ignorer.ignore?(error_for(module), %{}), "expected #{inspect(module)} ignored"
      end
    end

    test "ignores a lookup that found no record (404 through phoenix_ecto)" do
      assert Ignorer.ignore?(error_for(Ecto.NoResultsError), %{})
    end

    test "tracks a genuine server error" do
      refute Ignorer.ignore?(error_for(RuntimeError), %{})
    end

    test "tracks an exception whose plug_status is a server error" do
      refute Ignorer.ignore?(error_for(ServerFaultError), %{})
    end

    test "tracks a non-exception kind such as an Oban job's error tuple" do
      refute Ignorer.ignore?(%Error{kind: "error"}, %{})
    end

    test "tracks a kind naming no loaded module" do
      capture_log(fn ->
        refute Ignorer.ignore?(%Error{kind: "Elixir.Tymeslot.NoSuchModuleEverDefined"}, %{})
      end)
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
