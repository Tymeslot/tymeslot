defmodule Tymeslot.Infrastructure.ErrorTracking.IgnorerTest do
  use ExUnit.Case, async: true

  @moduletag :infrastructure
  @moduletag :unit

  alias ErrorTracker.Error
  alias Tymeslot.Infrastructure.ErrorTracking.Ignorer

  # ErrorTracker records an exception's kind as `to_string(module)`.
  defp error_for(module), do: %Error{kind: to_string(module)}

  describe "ignore?/2" do
    test "ignores a request for a route that does not exist" do
      assert Ignorer.ignore?(error_for(Phoenix.Router.NoRouteError), %{})
    end

    test "ignores a lookup that found no record" do
      assert Ignorer.ignore?(error_for(Ecto.NoResultsError), %{})
    end

    test "tracks a genuine server error" do
      refute Ignorer.ignore?(error_for(RuntimeError), %{})
    end

    test "tracks a non-exception kind such as an Oban job's error tuple" do
      refute Ignorer.ignore?(%Error{kind: "error"}, %{})
    end
  end
end
