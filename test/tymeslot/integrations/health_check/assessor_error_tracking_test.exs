defmodule Tymeslot.Integrations.HealthCheck.AssessorErrorTrackingTest do
  # async: false: ErrorTracker's `enabled` switch is global application env.
  use Tymeslot.DataCase, async: false

  @moduletag :integrations

  import ExUnit.CaptureLog
  import Mox
  import Tymeslot.ConfigTestHelpers

  alias ErrorTracker.Error
  alias Tymeslot.Integrations.HealthCheck.Assessor

  setup :verify_on_exit!

  test "a connection test that raises is recorded by exception module, never by message" do
    with_config(:error_tracker, enabled: true)
    integration = insert(:calendar_integration, user: insert(:user), provider: "google")

    expect(GoogleCalendarAPIMock, :list_primary_events, 1, fn _int, _start, _end ->
      raise CaseClauseError, term: %{"error" => "invalid_grant", "password" => "SECRET-PW"}
    end)

    log = capture_log(fn -> Assessor.assess(:calendar, integration) end)

    assert [%Error{reason: "{:raised, CaseClauseError}"} = error] =
             Error |> Repo.all() |> Repo.preload(:occurrences)

    assert [%{context: context} = occurrence] = error.occurrences
    assert context["integration_id"] == integration.id
    assert context["provider"] == "google"
    refute inspect(occurrence) =~ "SECRET-PW"
    refute log =~ "SECRET-PW"
  end
end
