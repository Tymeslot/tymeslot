defmodule Tymeslot.Integrations.Calendar.RemovedCalendarsTest do
  @moduledoc """
  The record of calendars the server stopped listing: which ones a
  deselection removed, how they join the integration's list, the one email
  about them, and the owner dismissing the notice.
  """
  use Tymeslot.DataCase, async: true
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :calendar
  @moduletag :integrations

  import Tymeslot.Factory

  alias Ecto.Changeset
  alias Tymeslot.Integrations.Calendar
  alias Tymeslot.Integrations.Calendar.CalendarEntry
  alias Tymeslot.Integrations.Calendar.CalendarIntegrationSchema
  alias Tymeslot.Integrations.Calendar.RemovedCalendar
  alias Tymeslot.Integrations.Calendar.RemovedCalendars
  alias Tymeslot.Security.RateLimiter
  alias Tymeslot.Workers.EmailWorker

  @now ~U[2026-10-10 09:30:15.123456Z]

  defp entry(attrs), do: struct!(CalendarEntry, Keyword.merge([selected: true], attrs))

  describe "removed/2" do
    test "a calendar deselected by path or by id is removed" do
      by_path = entry(path: "/dav/work/", name: "Work")
      by_id = entry(id: "team@example.com", name: "Team")
      kept = entry(path: "/dav/home/", name: "Home")

      after_list = [
        %{by_path | selected: false},
        %{by_id | selected: false},
        kept
      ]

      assert RemovedCalendars.removed([by_path, by_id, kept], after_list) == [by_path, by_id]
    end

    # Discovery deselects by leaving the calendar out of the merged list.
    test "a calendar missing from the new list altogether is removed" do
      gone = entry(path: "/dav/gone/", name: "Gone")
      kept = entry(path: "/dav/home/", name: "Home")

      assert RemovedCalendars.removed([gone, kept], [kept]) == [gone]
    end

    test "a calendar that was not selected, or still is under its id, is not" do
      unselected = entry(path: "/dav/off/", selected: false)
      renamed_path = entry(path: "/dav/old/", id: "cal-1")
      moved = entry(path: "/dav/new/", id: "cal-1")

      assert RemovedCalendars.removed([unselected, renamed_path], [moved]) == []
    end
  end

  describe "merge/3" do
    test "adds each calendar once, by its path or id, with the time to the second" do
      existing = [
        %RemovedCalendar{id: "/dav/work/", name: "Work", removed_at: ~U[2026-10-01 08:00:00Z]},
        %RemovedCalendar{id: "/dav/old/", name: "Old", removed_at: ~U[2026-10-01 08:00:00Z]}
      ]

      merged =
        RemovedCalendars.merge(
          existing,
          [entry(path: "/dav/work/", name: "Work"), entry(id: "team@example.com", name: nil)],
          @now
        )

      assert Enum.map(merged, &{&1.id, &1.name, &1.removed_at}) == [
               {"/dav/old/", "Old", ~U[2026-10-01 08:00:00Z]},
               {"/dav/work/", "Work", ~U[2026-10-10 09:30:15Z]},
               {"team@example.com", "team@example.com", ~U[2026-10-10 09:30:15Z]}
             ]
    end

    test "lists a calendar once when it is removed again under the other encoding of its path" do
      existing = [
        %RemovedCalendar{
          id: "/dav/user@example.org/Rota/",
          name: "Rota",
          removed_at: ~U[2026-10-01 08:00:00Z]
        }
      ]

      merged =
        RemovedCalendars.merge(
          existing,
          [entry(path: "/dav/user%40example.org/Rota/", name: "Rota")],
          @now
        )

      assert Enum.map(merged, &{&1.id, &1.removed_at}) == [
               {"/dav/user%40example.org/Rota/", ~U[2026-10-10 09:30:15Z]}
             ]
    end
  end

  describe "notify/2" do
    test "schedules one email naming every calendar removed" do
      user = insert(:user)
      integration = insert(:calendar_integration, user: user)

      assert :ok =
               RemovedCalendars.notify(integration, [
                 entry(path: "/dav/work/", name: "Work"),
                 entry(path: "/dav/team/", name: "Team")
               ])

      assert [job] = all_enqueued(worker: EmailWorker)

      assert job.args == %{
               "action" => "send_calendars_removed_notification",
               "user_id" => user.id,
               "integration_id" => integration.id,
               "calendar_names" => ["Work", "Team"]
             }
    end

    test "schedules nothing when nothing was removed" do
      integration = insert(:calendar_integration)

      assert :ok = RemovedCalendars.notify(integration, [])
      assert all_enqueued(worker: EmailWorker) == []
    end
  end

  describe "dismissing the notice" do
    setup do
      user = insert(:user)

      integration =
        insert(:calendar_integration,
          user: user,
          removed_calendars: [
            %RemovedCalendar{
              id: "/dav/work/",
              name: "Work",
              removed_at: ~U[2026-10-01 08:00:00Z]
            }
          ]
        )

      %{user: user, integration: integration}
    end

    test "drops the calendars its owner was shown", %{user: user, integration: integration} do
      assert {:ok, true} =
               Calendar.dismiss_removed_calendars(user.id, integration.id, ["/dav/work/"])

      assert Repo.get!(CalendarIntegrationSchema, integration.id).removed_calendars == []
    end

    # Recorded after the notice was rendered, so the owner has not seen it.
    test "keeps a calendar recorded since the owner was shown the notice", %{
      user: user,
      integration: integration
    } do
      integration
      |> Changeset.change()
      |> Changeset.put_embed(
        :removed_calendars,
        integration.removed_calendars ++
          [%RemovedCalendar{id: "/dav/team/", name: "Team", removed_at: ~U[2026-10-01 09:00:00Z]}]
      )
      |> Repo.update!()

      assert {:ok, true} =
               Calendar.dismiss_removed_calendars(user.id, integration.id, ["/dav/work/"])

      assert [%RemovedCalendar{id: "/dav/team/"}] =
               Repo.get!(CalendarIntegrationSchema, integration.id).removed_calendars
    end

    test "is not found for another user", %{integration: integration} do
      intruder = insert(:user)

      assert {:error, :not_found} =
               Calendar.dismiss_removed_calendars(intruder.id, integration.id, ["/dav/work/"])

      assert [_kept] = Repo.get!(CalendarIntegrationSchema, integration.id).removed_calendars
    end

    test "is refused once the owner's budget is spent", %{user: user, integration: integration} do
      fn -> RateLimiter.check(:integration_appearance, user.id) end
      |> Stream.repeatedly()
      |> Enum.find(&match?({:error, :rate_limited, _message}, &1))

      assert {:error, {:rate_limited, _message}} =
               Calendar.dismiss_removed_calendars(user.id, integration.id, ["/dav/work/"])

      assert [_kept] = Repo.get!(CalendarIntegrationSchema, integration.id).removed_calendars
    end
  end
end
