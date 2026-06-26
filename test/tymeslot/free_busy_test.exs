defmodule Tymeslot.FreeBusyTest do
  use Tymeslot.DataCase, async: true

  @moduletag :database

  import Tymeslot.Factory

  alias Tymeslot.FreeBusy

  describe "feed token lifecycle" do
    test "enable_feed generates a token and is idempotent" do
      profile = insert(:profile)
      refute FreeBusy.feed_enabled?(profile)

      assert {:ok, enabled} = FreeBusy.enable_feed(profile)
      assert FreeBusy.feed_enabled?(enabled)
      assert is_binary(enabled.freebusy_token)

      assert {:ok, again} = FreeBusy.enable_feed(enabled)
      assert again.freebusy_token == enabled.freebusy_token
    end

    test "regenerate_token replaces the token" do
      {:ok, enabled} = FreeBusy.enable_feed(insert(:profile))

      assert {:ok, rotated} = FreeBusy.regenerate_token(enabled)
      assert rotated.freebusy_token != enabled.freebusy_token
    end

    test "disable_feed clears the token" do
      {:ok, enabled} = FreeBusy.enable_feed(insert(:profile))

      assert {:ok, disabled} = FreeBusy.disable_feed(enabled)
      refute FreeBusy.feed_enabled?(disabled)
    end

    test "get_profile_by_token round-trips an enabled feed" do
      {:ok, enabled} = FreeBusy.enable_feed(insert(:profile))

      assert {:ok, found} = FreeBusy.get_profile_by_token(enabled.freebusy_token)
      assert found.id == enabled.id
    end

    test "get_profile_by_token rejects unknown tokens" do
      assert {:error, :not_found} = FreeBusy.get_profile_by_token("nope")
    end
  end

  describe "busy_intervals/3" do
    setup do
      profile = insert(:profile)
      integration = insert(:calendar_integration, user: profile.user)
      %{profile: profile, integration: integration}
    end

    test "includes blocking (opaque) events in the window", %{
      profile: profile,
      integration: integration
    } do
      insert(:provider_calendar_event,
        calendar_integration: integration,
        start_at: ~U[2030-06-01 09:00:00Z],
        end_at: ~U[2030-06-01 10:00:00Z],
        transparency: "opaque",
        status: "confirmed"
      )

      intervals =
        FreeBusy.busy_intervals(profile, ~U[2030-05-01 00:00:00Z], ~U[2030-07-01 00:00:00Z])

      assert Enum.any?(intervals, fn {s, e} ->
               DateTime.truncate(s, :second) == ~U[2030-06-01 09:00:00Z] and
                 DateTime.truncate(e, :second) == ~U[2030-06-01 10:00:00Z]
             end)
    end

    test "excludes transparent (free) events", %{profile: profile, integration: integration} do
      insert(:provider_calendar_event,
        calendar_integration: integration,
        start_at: ~U[2030-06-01 09:00:00Z],
        end_at: ~U[2030-06-01 10:00:00Z],
        transparency: "transparent",
        status: "confirmed"
      )

      assert [] =
               FreeBusy.busy_intervals(
                 profile,
                 ~U[2030-05-01 00:00:00Z],
                 ~U[2030-07-01 00:00:00Z]
               )
    end
  end

  describe "feed/2" do
    test "renders a VFREEBUSY document containing the busy period" do
      profile = insert(:profile)
      integration = insert(:calendar_integration, user: profile.user)

      now = DateTime.utc_now()
      busy_start = DateTime.truncate(DateTime.add(now, 2, :day), :second)
      busy_end = DateTime.add(busy_start, 3600, :second)

      insert(:provider_calendar_event,
        calendar_integration: integration,
        start_at: busy_start,
        end_at: busy_end,
        transparency: "opaque",
        status: "confirmed"
      )

      ics = FreeBusy.feed(profile, now: now)

      assert ics =~ "BEGIN:VFREEBUSY"
      assert ics =~ "FREEBUSY;FBTYPE=BUSY:"
    end
  end
end
