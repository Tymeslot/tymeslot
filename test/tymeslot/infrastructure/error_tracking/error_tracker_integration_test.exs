defmodule Tymeslot.Infrastructure.ErrorTracking.ErrorTrackerIntegrationTest do
  # async: false: ErrorTracker's `enabled` switch is global application env.
  use Tymeslot.DataCase, async: false

  @moduletag :infrastructure
  @moduletag :integration

  import Tymeslot.ConfigTestHelpers

  alias ErrorTracker.Error
  alias ErrorTracker.Occurrence

  setup do
    with_config(:error_tracker, enabled: true)
    :ok
  end

  test "stores a reported exception with its context redacted" do
    {exception, stacktrace} = raise_and_capture()

    ErrorTracker.report(exception, stacktrace, %{"password" => "x", "user_id" => 7})

    assert [%Error{kind: "Elixir.RuntimeError", reason: "boom"} = error] = Repo.all(Error)
    assert [%Occurrence{context: context} = occurrence] = Repo.all(Occurrence)
    assert occurrence.error_id == error.id
    assert context == %{"password" => "[REDACTED]", "user_id" => 7}
  end

  test "does not store an ignored client error" do
    {exception, stacktrace} = raise_and_capture(Ecto.NoResultsError, queryable: "users")

    assert ErrorTracker.report(exception, stacktrace, %{}) == :noop
    assert Repo.all(Error) == []
  end

  defp raise_and_capture(module \\ RuntimeError, opts \\ [message: "boom"]) do
    raise module, opts
  rescue
    exception -> {exception, __STACKTRACE__}
  end
end
