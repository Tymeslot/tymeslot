defmodule Tymeslot.CalendarGrid.EventMoveGoogleWriteTest do
  @moduledoc """
  Whose event a grid move of a synced Google event to another calendar says
  it is, on the wire.

  `EventMoveTest` stops at the `:calendar_module` seam; this module points
  it back at the runtime modules, so only the HTTP client is mocked and the
  body of the create on the destination can be read. A move is a create on
  the destination and a delete of the original, so the copy is a new Google
  event: a mark put on it would make somebody else's event read back as
  Tymeslot's on the next sync, and drop off the dashboard agenda.
  """
  use Tymeslot.DataCase, async: false

  @moduletag :calendar
  @moduletag :integration

  import Mox

  alias Ecto.Changeset
  alias Tymeslot.CalendarGrid
  alias Tymeslot.Integrations.Calendar.Google.CalendarAPI
  alias Tymeslot.Integrations.Calendar.ProviderCalendarEventQueries
  alias Tymeslot.Integrations.Calendar.Runtime.Operations
  alias Tymeslot.Repo
  alias Tymeslot.Security.Encryption

  setup :verify_on_exit!

  @events_url "https://www.googleapis.com/calendar/v3/calendars"

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
    swap_env(:google_calendar_api_module, CalendarAPI)

    user = insert(:user)

    integration =
      insert(:calendar_integration,
        user: user,
        provider: "google",
        access_token_encrypted: Encryption.encrypt("valid_token"),
        refresh_token_encrypted: Encryption.encrypt("refresh_token"),
        token_expires_at: DateTime.add(DateTime.utc_now(), 3600),
        oauth_scope: "https://www.googleapis.com/auth/calendar"
      )

    event =
      insert(:provider_calendar_event,
        calendar_integration: integration,
        uid: "sprintreview",
        provider: "google",
        provider_calendar_id: "primary",
        provider_event_id: "sprintreview",
        summary: "Sprint review",
        start_at: ~U[2026-09-10 09:00:00.000000Z],
        end_at: ~U[2026-09-10 10:00:00.000000Z],
        all_day: false,
        sync_state: "synced"
      )

    %{user: user, integration: integration, event: event}
  end

  # Answers the create on the destination and the delete of the original,
  # recording each request in order.
  defp serve do
    test_pid = self()

    stub(Tymeslot.HTTPClientMock, :request, fn method, url, body, _headers, _opts ->
      send(test_pid, {:request, method, url, body})

      case method do
        :post ->
          {:ok, %Req.Response{status: 200, body: Jason.encode!(%{"id" => "copy1"})}}

        :delete ->
          {:ok, %Req.Response{status: 204, body: ""}}
      end
    end)
  end

  defp requests do
    receive do
      {:request, method, url, body} -> [{method, url, body} | requests()]
    after
      0 -> []
    end
  end

  defp move(user, event, integration) do
    CalendarGrid.move_event(user.id, event, %{integration: integration, calendar_id: "team"})
  end

  describe "moving a synced Google event to another calendar" do
    test "leaves an event someone else made unmarked on the destination", %{
      user: user,
      integration: integration,
      event: event
    } do
      refute event.created_by_tymeslot
      serve()

      assert {:ok, %{uid: uid}} = move(user, event, integration)

      assert [{:post, post_url, body}, {:delete, delete_url, _delete}] = requests()
      assert String.starts_with?(post_url, @events_url <> "/team/events")
      assert String.starts_with?(delete_url, @events_url <> "/primary/events/")

      sent = Jason.decode!(body)
      assert sent["summary"] == "Sprint review"
      refute get_in(sent, ["extendedProperties", "private", "createdBy"])
      refute Map.has_key?(sent, "source")

      assert {:ok, row} = ProviderCalendarEventQueries.get_by_uid(integration.id, uid)
      refute row.created_by_tymeslot
    end

    test "keeps Tymeslot's mark on its own event", %{
      user: user,
      integration: integration,
      event: event
    } do
      event = event |> Changeset.change(created_by_tymeslot: true) |> Repo.update!()
      serve()

      assert {:ok, _moved} = move(user, event, integration)

      assert [{:post, _url, body}, {:delete, _delete_url, _delete}] = requests()
      sent = Jason.decode!(body)
      assert get_in(sent, ["extendedProperties", "private", "createdBy"]) == "tymeslot"
      assert sent["source"]["title"] == "Tymeslot"
    end
  end
end
