defmodule Tymeslot.Scheduling.LinkAccessPolicyTest do
  @moduledoc """
  Covers the public-readiness invariant: a subscription is read-only and can
  never be the calendar that makes an organiser bookable, so it must not
  count toward `check_public_readiness/1`.
  """

  use Tymeslot.DataCase, async: true

  @moduletag :scheduling

  import Tymeslot.Factory

  alias Tymeslot.Scheduling.LinkAccessPolicy
  alias Tymeslot.Security.Encryption

  describe "check_public_readiness/1" do
    test "a subscription-only account is not ready" do
      user = insert(:user)
      profile = insert(:profile, user: user)

      insert(:calendar_integration,
        user: user,
        provider: "ics_url",
        base_url: "https://feeds.example.com",
        username_encrypted: nil,
        password_encrypted: nil,
        subscription_url_encrypted: Encryption.encrypt("https://feeds.example.com/feed.ics")
      )

      assert {:error, :no_calendar} = LinkAccessPolicy.check_public_readiness(profile)
    end

    test "a CalDAV integration alongside the subscription makes the account ready" do
      user = insert(:user)
      profile = insert(:profile, user: user)

      insert(:calendar_integration,
        user: user,
        provider: "ics_url",
        base_url: "https://feeds.example.com",
        username_encrypted: nil,
        password_encrypted: nil,
        subscription_url_encrypted: Encryption.encrypt("https://feeds.example.com/feed.ics")
      )

      insert(:calendar_integration, user: user, provider: "caldav")

      assert {:ok, :ready} = LinkAccessPolicy.check_public_readiness(profile)
    end
  end
end
