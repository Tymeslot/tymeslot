defmodule Tymeslot.CalendarGrid.EventCreationIdentityTest do
  @moduledoc """
  The uid a grid create answers with, which the grid caches the new event's
  row under: on a provider that mints its own ids it must be the iCalendar UID
  the provider's sync keys the event by, or the next sync adds a second row.

  The provider write is stubbed at the suite-wide `:calendar_module` seam
  (`Tymeslot.CalendarMock`), answering through Google's own conversion.
  """

  use Tymeslot.DataCase, async: true
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :calendar
  @moduletag :integration

  import Mox

  alias Tymeslot.CalendarGrid.EventCreation
  alias Tymeslot.Integrations.Calendar.CreatedEvent
  alias Tymeslot.Integrations.Calendar.Google.Provider, as: GoogleProvider
  alias Tymeslot.Workers.EmailWorker

  setup :verify_on_exit!

  describe "run_create_event/1 on a provider that mints its own ids" do
    test "answers with the iCalUID Google's sync keys the event by, beside Google's own id" do
      user = insert(:user)
      integration = insert(:calendar_integration, user: user, provider: "google")

      expect(Tymeslot.CalendarMock, :create_event, fn event_data, _context ->
        response = %{
          "id" => "gevent0002",
          "iCalUID" => "9a8b7c6d@google.com",
          "summary" => event_data.summary,
          "start" => %{"dateTime" => "2026-04-08T09:00:00Z"},
          "end" => %{"dateTime" => "2026-04-08T09:30:00Z"}
        }

        {:ok, response |> GoogleProvider.convert_event() |> CreatedEvent.from_provider_event()}
      end)

      payload = %{
        creating: %{
          title: "Planning",
          integration_id: integration.id,
          calendar_id: "primary",
          attendees: ["alice@example.com"]
        },
        user_id: user.id,
        start_at: ~U[2026-04-08 09:00:00Z],
        end_at: ~U[2026-04-08 09:30:00Z]
      }

      assert {:ok, result} = EventCreation.run_create_event(payload)
      assert {result.uid, result.provider_event_id} == {"9a8b7c6d@google.com", "gevent0002"}

      assert_enqueued(
        worker: EmailWorker,
        args: %{"action" => "send_calendar_invitation", "event_uid" => "9a8b7c6d@google.com"}
      )
    end
  end
end
