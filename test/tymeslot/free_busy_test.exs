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
      # 24 random bytes, url-safe base64 without padding.
      assert enabled.freebusy_token =~ ~r/\A[A-Za-z0-9_-]{32}\z/

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

    test "publishes time off as busy alongside calendar events" do
      profile = insert(:profile, timezone: "Europe/Berlin")

      insert(:provider_calendar_event,
        calendar_integration: insert(:calendar_integration, user: profile.user),
        start_at: ~U[2030-06-01 09:00:00Z],
        end_at: ~U[2030-06-01 10:00:00Z],
        transparency: "opaque",
        status: "confirmed"
      )

      insert(:time_off_period,
        profile: profile,
        starts_on: ~D[2030-06-10],
        ends_on: ~D[2030-06-11]
      )

      intervals =
        FreeBusy.busy_intervals(profile, ~U[2030-05-01 00:00:00Z], ~U[2030-07-01 00:00:00Z])

      assert {~U[2030-06-09 22:00:00Z], ~U[2030-06-11 22:00:00Z]} in intervals

      assert Enum.any?(intervals, fn {s, _e} ->
               DateTime.truncate(s, :second) == ~U[2030-06-01 09:00:00Z]
             end)
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

    test "publishes free events as busy from a subscription that counts every event as busy",
         %{profile: profile} do
      subscription =
        insert(:calendar_integration,
          user: profile.user,
          provider: "ics_url",
          all_events_busy: true
        )

      insert(:provider_calendar_event,
        calendar_integration: subscription,
        provider: "ics_url",
        start_at: ~U[2030-06-01 09:00:00Z],
        end_at: ~U[2030-06-01 10:00:00Z],
        transparency: "transparent",
        status: "confirmed"
      )

      insert(:provider_calendar_event,
        calendar_integration: subscription,
        provider: "ics_url",
        start_at: ~U[2030-06-02 09:00:00Z],
        end_at: ~U[2030-06-02 10:00:00Z],
        transparency: "transparent",
        status: "cancelled"
      )

      assert [{s, e}] =
               FreeBusy.busy_intervals(
                 profile,
                 ~U[2030-05-01 00:00:00Z],
                 ~U[2030-07-01 00:00:00Z]
               )

      assert DateTime.truncate(s, :second) == ~U[2030-06-01 09:00:00Z]
      assert DateTime.truncate(e, :second) == ~U[2030-06-01 10:00:00Z]
    end

    test "maps an all-day event to the owner's local day", %{
      profile: profile,
      integration: integration
    } do
      profile = %{profile | timezone: "Australia/Sydney"}

      insert(:provider_calendar_event,
        calendar_integration: integration,
        all_day: true,
        start_date: ~D[2030-06-01],
        end_date: ~D[2030-06-02],
        start_at: nil,
        end_at: nil,
        transparency: "opaque",
        status: "confirmed"
      )

      intervals =
        FreeBusy.busy_intervals(profile, ~U[2030-05-01 00:00:00Z], ~U[2030-07-01 00:00:00Z])

      # 1 June in Sydney (AEST, +10:00), not 1 June in UTC.
      assert [{s, e}] = intervals
      assert DateTime.compare(s, ~U[2030-05-31 14:00:00Z]) == :eq
      assert DateTime.compare(e, ~U[2030-06-01 14:00:00Z]) == :eq
    end
  end

  describe "busy_intervals/3 and the calendars the owner lets block" do
    setup do
      profile = insert(:profile)

      integration =
        insert(:calendar_integration,
          user: profile.user,
          provider: "google",
          calendar_list: [
            %{id: "work", selected: true},
            %{id: "holidays", selected: true, blocks_availability: false},
            %{id: "archive", selected: false}
          ]
        )

      for {calendar_id, hour} <- [{"work", 9}, {"holidays", 11}, {"archive", 13}] do
        start = DateTime.new!(~D[2030-06-03], Time.new!(hour, 0, 0), "Etc/UTC")

        insert(:provider_calendar_event,
          calendar_integration: integration,
          provider_calendar_id: calendar_id,
          start_at: start,
          end_at: DateTime.add(start, 3600, :second)
        )
      end

      %{profile: profile}
    end

    test "publishes a blocking calendar's events only", %{profile: profile} do
      starts =
        profile
        |> FreeBusy.busy_intervals(~U[2030-06-01 00:00:00Z], ~U[2030-06-10 00:00:00Z])
        |> Enum.map(fn {s, _e} -> DateTime.truncate(s, :second) end)

      # 11:00 is a show-only calendar; 13:00 a deselected one whose rows a
      # sync left behind.
      assert starts == [~U[2030-06-03 09:00:00Z]]
    end
  end

  describe "busy_intervals/3 and rows filed under the \"primary\" label" do
    # An Outlook integration's rows cached before discovery named its default
    # calendar carry "primary" until a later read relabels them.
    defp outlook_with(default_blocks?) do
      profile = insert(:profile)

      integration =
        insert(:calendar_integration,
          user: profile.user,
          provider: "outlook",
          calendar_list: [
            %{
              id: "AAMk-default",
              primary: true,
              selected: true,
              blocks_availability: default_blocks?
            },
            %{id: "AAMk-team", selected: true}
          ]
        )

      insert(:provider_calendar_event,
        calendar_integration: integration,
        provider: "outlook",
        provider_calendar_id: "primary",
        start_at: ~U[2030-06-03 09:00:00Z],
        end_at: ~U[2030-06-03 10:00:00Z]
      )

      profile
    end

    defp starts(profile) do
      profile
      |> FreeBusy.busy_intervals(~U[2030-06-01 00:00:00Z], ~U[2030-06-10 00:00:00Z])
      |> Enum.map(fn {s, _e} -> DateTime.truncate(s, :second) end)
    end

    test "count as the default calendar's when it blocks" do
      assert starts(outlook_with(true)) == [~U[2030-06-03 09:00:00Z]]
    end

    test "do not when the default calendar is set to show only" do
      assert starts(outlook_with(false)) == []
    end
  end

  describe "busy_intervals/3 for a CalDAV calendar shared as busy times only" do
    test "publishes the busy periods its sync cached" do
      profile = insert(:profile)
      path = "/calendars/colleague/availability/"

      integration =
        insert(:calendar_integration,
          user: profile.user,
          provider: "caldav",
          calendar_list: [
            %{id: "/calendars/host/personal/", path: "/calendars/host/personal/", selected: true},
            %{id: path, path: path, selected: true, read_only: true, free_busy_only: true}
          ]
        )

      insert(:provider_calendar_event,
        calendar_integration: integration,
        provider: "caldav",
        provider_calendar_id: path,
        provider_event_id: nil,
        role: "busy_only",
        uid: "tymeslot:caldav-busy:1",
        start_at: ~U[2030-06-03 09:00:00Z],
        end_at: ~U[2030-06-03 10:00:00Z]
      )

      assert [{start, _end}] =
               FreeBusy.busy_intervals(
                 profile,
                 ~U[2030-06-01 00:00:00Z],
                 ~U[2030-06-10 00:00:00Z]
               )

      assert DateTime.truncate(start, :second) == ~U[2030-06-03 09:00:00Z]
    end
  end

  describe "busy_intervals/3 for an Exchange mailbox" do
    test "publishes its mailbox-wide busy time whatever folders are selected" do
      profile = insert(:profile)

      integration =
        insert(:calendar_integration,
          user: profile.user,
          provider: "exchange",
          calendar_list: [%{id: "folder-team", name: "Team", selected: true}]
        )

      insert(:provider_calendar_event,
        calendar_integration: integration,
        provider: "exchange",
        provider_calendar_id: "mailbox",
        role: "busy_only",
        start_at: ~U[2030-06-03 09:00:00Z],
        end_at: ~U[2030-06-03 10:00:00Z]
      )

      assert [{start, _end}] =
               FreeBusy.busy_intervals(
                 profile,
                 ~U[2030-06-01 00:00:00Z],
                 ~U[2030-06-10 00:00:00Z]
               )

      assert DateTime.truncate(start, :second) == ~U[2030-06-03 09:00:00Z]
    end
  end

  describe "feed/2" do
    test "renders a VFREEBUSY document with correct interval bounds and ORGANIZER" do
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

      start_str = busy_start |> DateTime.to_iso8601(:basic) |> String.replace(~r/\.\d+/, "")
      end_str = busy_end |> DateTime.to_iso8601(:basic) |> String.replace(~r/\.\d+/, "")

      assert ics =~ "BEGIN:VFREEBUSY"
      assert ics =~ "FREEBUSY;FBTYPE=BUSY:#{start_str}/#{end_str}"
      assert ics =~ "ORGANIZER:mailto:#{profile.user.email}"
    end
  end
end
