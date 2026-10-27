defmodule Tymeslot.CalendarGrid.EventEditOutlookWriteTest do
  @moduledoc """
  Whose event a grid edit of a synced Outlook event says it is, on the wire.

  The `:calendar_module` seam and the Outlook API module are pointed back at
  the runtime modules, so the edit travels the whole way down (grid domain,
  provider adapter, Graph client) and only the HTTP client is mocked: the
  `PATCH` body Graph receives is the thing under test.

  Tymeslot's mark on an Outlook event is a single-value extended property,
  and a `PATCH` that carries it sets it on the event for good. On somebody
  else's event that is a lie the next sync believes: the event is read back
  as Tymeslot's, and drops off the organiser's dashboard agenda.
  """
  use Tymeslot.DataCase, async: false

  @moduletag :calendar
  @moduletag :integration

  import Mox

  alias Ecto.Changeset
  alias Tymeslot.CalendarGrid
  alias Tymeslot.Integrations.Calendar.Outlook.CalendarAPI, as: OutlookAPI
  alias Tymeslot.Integrations.Calendar.Outlook.TymeslotFingerprint
  alias Tymeslot.Integrations.Calendar.Runtime.Operations
  alias Tymeslot.Repo
  alias Tymeslot.Security.Encryption

  setup :verify_on_exit!

  # What the sync stored of the raw Graph event: another app's categories
  # and extended property, and the guest permission Graph keeps per event.
  @foreign_metadata %{
    "id" => "AAMkReview",
    "type" => "singleInstance",
    "seriesMasterId" => nil,
    "categories" => ["Customer"],
    "allowNewTimeProposals" => false,
    "singleValueExtendedProperties" => [
      %{"id" => "String {00020329-0000-0000-c000-000000000046} Name crmId", "value" => "deal-42"}
    ]
  }

  defp swap_env(key, module) do
    previous = Application.get_env(:tymeslot, key)
    Application.put_env(:tymeslot, key, module)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:tymeslot, key, previous),
        else: Application.delete_env(:tymeslot, key)
    end)
  end

  setup do
    swap_env(:calendar_module, Operations)
    swap_env(:outlook_calendar_api_module, OutlookAPI)

    user = insert(:user)

    integration =
      insert(:calendar_integration,
        user: user,
        provider: "outlook",
        access_token_encrypted: Encryption.encrypt("valid_token"),
        refresh_token_encrypted: Encryption.encrypt("refresh_token"),
        token_expires_at: DateTime.add(DateTime.utc_now(), 3600),
        oauth_scope: "https://graph.microsoft.com/Calendars.ReadWrite"
      )

    event =
      insert(:provider_calendar_event,
        calendar_integration: integration,
        uid: "040000008200E00074C5B7101A82E00A",
        provider: "outlook",
        provider_calendar_id: "primary",
        provider_event_id: "AAMkReview",
        summary: "Quarterly review",
        start_at: ~U[2026-11-10 09:00:00.000000Z],
        end_at: ~U[2026-11-10 10:00:00.000000Z],
        all_day: false,
        timezone: "Etc/UTC",
        sync_state: "synced"
      )

    %{user: user, event: event}
  end

  defp stored_as(event, attrs), do: event |> Changeset.change(attrs) |> Repo.update!()

  # Graph answers a PATCH with the event as it now stands: whatever the
  # request asked for, over everything it left alone.
  defp patch_and_capture do
    test_pid = self()

    expect(Tymeslot.HTTPClientMock, :request, fn :patch, url, body, _headers, _opts ->
      send(test_pid, {:patch, url, body})
      sent = Jason.decode!(body)

      answer =
        @foreign_metadata
        |> Map.merge(%{
          "iCalUId" => "040000008200E00074C5B7101A82E00A",
          "start" => %{"dateTime" => "2026-11-10T09:00:00.0000000", "timeZone" => "UTC"},
          "end" => %{"dateTime" => "2026-11-10T10:00:00.0000000", "timeZone" => "UTC"}
        })
        |> Map.merge(Map.take(sent, ["subject", "singleValueExtendedProperties"]))

      {:ok, %Req.Response{status: 200, body: Jason.encode!(answer)}}
    end)
  end

  defp fingerprinted?(sent) do
    property_id = TymeslotFingerprint.property_id()
    Enum.any?(sent["singleValueExtendedProperties"] || [], &(&1["id"] == property_id))
  end

  describe "renaming a synced Outlook event from the grid" do
    test "leaves an event someone else made unmarked, and its properties alone", %{
      user: user,
      event: event
    } do
      event = stored_as(event, created_by_tymeslot: false, provider_metadata: @foreign_metadata)
      patch_and_capture()

      assert {:ok, updated} = CalendarGrid.update_event(user.id, event, %{summary: "Renamed"})
      assert updated.summary == "Renamed"

      assert_received {:patch, url, body}
      assert url =~ "/events/AAMkReview"
      sent = Jason.decode!(body)

      assert sent["subject"] == "Renamed"
      refute fingerprinted?(sent)

      # A PATCH changes only what it carries, so another app's marks survive
      # by being absent from the body.
      refute Map.has_key?(sent, "singleValueExtendedProperties")
      refute Map.has_key?(sent, "categories")
      refute Map.has_key?(sent, "allowNewTimeProposals")

      stored = Repo.reload!(event)
      refute stored.created_by_tymeslot
      assert stored.summary == "Renamed"
      assert stored.provider_metadata["categories"] == ["Customer"]
    end

    test "keeps Tymeslot's mark on its own event", %{user: user, event: event} do
      event = stored_as(event, created_by_tymeslot: true)
      patch_and_capture()

      assert {:ok, _updated} = CalendarGrid.update_event(user.id, event, %{summary: "Renamed"})

      assert_received {:patch, _url, body}
      assert body |> Jason.decode!() |> fingerprinted?()
    end
  end
end
