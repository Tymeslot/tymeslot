defmodule Tymeslot.Integrations.Shared.OAuth.GrantSharingTest do
  use Tymeslot.DataCase, async: true

  @moduletag :integrations
  @moduletag :oauth

  import Tymeslot.Factory

  alias Tymeslot.Integrations.Shared.OAuth.GrantSharing
  alias Tymeslot.Integrations.Video.VideoIntegrationQueries
  alias Tymeslot.Security.Encryption

  defp oauth_calendar(user, account_id, attrs \\ []) do
    insert(
      :calendar_integration,
      [
        user: user,
        provider: "google",
        provider_account_id: account_id,
        access_token_encrypted: Encryption.encrypt("access"),
        refresh_token_encrypted: Encryption.encrypt("refresh")
      ] ++ attrs
    )
  end

  defp oauth_video(user, provider, account_id, attrs \\ []) do
    insert(
      :video_integration,
      [user: user, provider: provider, provider_account_id: account_id] ++ attrs
    )
  end

  setup do
    %{leaving: insert(:user), staying: insert(:user)}
  end

  describe "Google" do
    test "a calendar is shared when another account has a calendar on the same Google account",
         %{leaving: leaving, staying: staying} do
      calendar = oauth_calendar(leaving, "google-sub-1")
      oauth_calendar(staying, "google-sub-1")

      assert GrantSharing.shared?(calendar)
    end

    test "a calendar is shared when another account has Google Meet on the same Google account",
         %{leaving: leaving, staying: staying} do
      calendar = oauth_calendar(leaving, "google-sub-1")
      oauth_video(staying, "google_meet", "google-sub-1")

      assert GrantSharing.shared?(calendar)
    end

    test "Google Meet is shared when another account has a calendar on the same Google account",
         %{leaving: leaving, staying: staying} do
      meet = oauth_video(leaving, "google_meet", "google-sub-1")
      oauth_calendar(staying, "google-sub-1")

      assert GrantSharing.shared?(meet)
    end

    test "Google Meet is shared when another account has Google Meet on the same Google account",
         %{leaving: leaving, staying: staying} do
      meet = oauth_video(leaving, "google_meet", "google-sub-1")
      oauth_video(staying, "google_meet", "google-sub-1")

      assert GrantSharing.shared?(meet)
    end

    test "is not shared when the other account is on a different Google account",
         %{leaving: leaving, staying: staying} do
      calendar = oauth_calendar(leaving, "google-sub-1")
      oauth_calendar(staying, "google-sub-2")
      oauth_video(staying, "google_meet", "google-sub-2")

      refute GrantSharing.shared?(calendar)
    end

    test "is not shared when only the same account holds the Google account elsewhere",
         %{leaving: leaving} do
      calendar = oauth_calendar(leaving, "google-sub-1")
      oauth_video(leaving, "google_meet", "google-sub-1")

      refute GrantSharing.shared?(calendar)
    end

    test "is not shared when the other account's row holds no token",
         %{leaving: leaving, staying: staying} do
      calendar = oauth_calendar(leaving, "google-sub-1")

      oauth_calendar(staying, "google-sub-1",
        access_token_encrypted: nil,
        refresh_token_encrypted: nil
      )

      oauth_video(staying, "google_meet", "google-sub-1",
        access_token_encrypted: nil,
        refresh_token_encrypted: nil
      )

      refute GrantSharing.shared?(calendar)
    end

    test "an inactive calendar of another account still counts as holding the grant",
         %{leaving: leaving, staying: staying} do
      meet = oauth_video(leaving, "google_meet", "google-sub-1")
      oauth_calendar(staying, "google-sub-1", is_active: false)

      assert GrantSharing.shared?(meet)
    end

    test "a row that never recorded its Google account reads as not shared",
         %{leaving: leaving, staying: staying} do
      calendar = oauth_calendar(leaving, nil)
      oauth_calendar(staying, nil)

      refute GrantSharing.shared?(calendar)
    end
  end

  describe "Zoom" do
    test "is shared when another account has Zoom on the same Zoom user",
         %{leaving: leaving, staying: staying} do
      zoom = oauth_video(leaving, "zoom", "zoom-user-1")
      oauth_video(staying, "zoom", "zoom-user-1")

      assert GrantSharing.shared?(zoom)
    end

    test "a disconnected Zoom of another account still awaiting room cleanup counts",
         %{leaving: leaving, staying: staying} do
      zoom = oauth_video(leaving, "zoom", "zoom-user-1")

      {:ok, _disconnected} =
        staying |> oauth_video("zoom", "zoom-user-1") |> VideoIntegrationQueries.soft_delete()

      assert GrantSharing.shared?(zoom)
    end

    test "is not shared with another account on a different Zoom user",
         %{leaving: leaving, staying: staying} do
      zoom = oauth_video(leaving, "zoom", "zoom-user-1")
      oauth_video(staying, "zoom", "zoom-user-2")

      refute GrantSharing.shared?(zoom)
    end

    test "is not shared with another provider's row carrying the same id",
         %{leaving: leaving, staying: staying} do
      zoom = oauth_video(leaving, "zoom", "same-id")
      oauth_video(staying, "google_meet", "same-id")
      oauth_video(staying, "teams", "same-id")

      refute GrantSharing.shared?(zoom)
    end
  end

  test "a provider with no revocable grant is never shared", %{leaving: leaving, staying: staying} do
    teams = oauth_video(leaving, "teams", "entra-oid-1")
    oauth_video(staying, "teams", "entra-oid-1")

    refute GrantSharing.shared?(teams)
  end
end
