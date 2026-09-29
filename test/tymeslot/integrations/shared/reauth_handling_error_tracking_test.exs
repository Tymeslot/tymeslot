defmodule Tymeslot.Integrations.Shared.ReauthHandlingErrorTrackingTest do
  @moduledoc """
  Credentials that no longer decrypt usually mean the encryption key was lost
  or rotated, which is the operator's to fix and affects every integration at
  once. The job that meets them is discarded as an expected end, so the
  failure is recorded where it is diagnosed instead: once, as one error.
  """

  # async: false: ErrorTracker's `enabled` switch is global.
  use Tymeslot.DataCase, async: false

  @moduletag :integrations
  @moduletag :security

  import ExUnit.CaptureLog
  import Tymeslot.ConfigTestHelpers

  alias ErrorTracker.Error
  alias Tymeslot.Integrations.CalendarManagement
  alias Tymeslot.Integrations.Shared.ReauthHandling
  alias Tymeslot.Integrations.Video
  alias Tymeslot.Repo

  setup do
    with_config(:error_tracker, enabled: true)
    :ok
  end

  defp errors, do: Repo.all(from(e in Error, preload: :occurrences))

  test "undecryptable credentials across integrations are one error, the discard still expected" do
    discard_reason = ReauthHandling.discard_reason()

    capture_log(fn ->
      for provider <- ["google", "caldav"] do
        integration = insert(:calendar_integration, provider: provider)

        assert {:discard, ^discard_reason} =
                 CalendarManagement.handle_reauth_required(integration)
      end

      video = insert(:video_integration)
      assert {:discard, ^discard_reason} = Video.handle_reauth_required(video)
    end)

    assert [%Error{} = error] = errors()
    assert error.reason =~ "credentials_undecryptable"
    assert length(error.occurrences) == 3
  end

  test "an expired grant is the owner's to fix, and records nothing" do
    integration = insert(:calendar_integration, provider: "google")

    capture_log(fn ->
      assert {:discard, _reason} =
               CalendarManagement.handle_reauth_required(integration, cause: :expired_grant)
    end)

    assert errors() == []
  end
end
