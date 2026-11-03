defmodule Tymeslot.Integrations.Calendar.Outlook.CalendarAPITransactionIdTest do
  @moduledoc """
  The `transactionId` an Outlook event create sends Graph, so that a POST
  retried after its answer was lost is answered with the event it already
  wrote. The booking-level journey, with the timeout simulated, is
  `Tymeslot.Bookings.OutlookCreateTimeoutTest`.
  """

  # async: false, as `CalendarAPITest`: the OAuth helpers read the
  # application-wide :outlook_oauth config.
  use Tymeslot.DataCase, async: false
  @moduletag :integrations
  @moduletag :calendar

  import Tymeslot.Factory
  import Mox

  alias Ecto.UUID
  alias Tymeslot.Integrations.Calendar.Outlook.CalendarAPI
  alias Tymeslot.Security.Encryption

  setup :verify_on_exit!

  describe "create_event/3 transactionId" do
    setup do
      %{integration: insert_outlook_integration()}
    end

    test "is the same on every attempt of one create", %{integration: integration} do
      data = keyed_event("meeting-1:uid-1")

      assert transaction_id(integration, data) == transaction_id(integration, data)
      assert {:ok, _uuid} = UUID.cast(transaction_id(integration, data))
    end

    test "differs for another meeting's create", %{integration: integration} do
      refute transaction_id(integration, keyed_event("meeting-1:uid-1")) ==
               transaction_id(integration, keyed_event("meeting-2:uid-2"))
    end

    test "differs for a re-create superseding an earlier event", %{integration: integration} do
      refute transaction_id(integration, keyed_event("meeting-1:uid-1")) ==
               transaction_id(integration, keyed_event("meeting-1:AAMk-deleted"))
    end

    test "differs once the event moved", %{integration: integration} do
      data = keyed_event("meeting-1:uid-1")
      moved = %{data | start_time: ~U[2026-03-02 11:00:00Z], end_time: ~U[2026-03-02 12:00:00Z]}

      refute transaction_id(integration, data) == transaction_id(integration, moved)
    end

    test "is the same when only the event's content changed", %{integration: integration} do
      data = keyed_event("meeting-1:uid-1")

      with_room =
        Map.merge(data, %{
          location: "https://meet.example.com/room",
          description: "Join at https://meet.example.com/room"
        })

      assert transaction_id(integration, data) == transaction_id(integration, with_room)
    end

    test "differs for another calendar", %{integration: integration} do
      data = keyed_event("meeting-1:uid-1")

      refute transaction_id(integration, data, "cal1") ==
               transaction_id(integration, data, "cal2")
    end

    test "is not sent for a create without a creation key", %{integration: integration} do
      assert transaction_id(integration, Map.delete(keyed_event("x"), :creation_key)) == nil
    end
  end

  defp keyed_event(creation_key) do
    %{
      summary: "Consultation",
      start_time: ~U[2026-03-02 10:00:00Z],
      end_time: ~U[2026-03-02 11:00:00Z],
      timezone: "UTC",
      creation_key: creation_key
    }
  end

  # The `transactionId` the create of `event_data` sends Graph.
  defp transaction_id(integration, event_data, calendar_id \\ "cal1") do
    test_pid = self()

    expect(Tymeslot.HTTPClientMock, :request, fn :post, _url, body, _headers, _opts ->
      send(test_pid, {:transaction_id, Jason.decode!(body)["transactionId"]})

      {:ok, %Req.Response{status: 201, body: Jason.encode!(%{"id" => "new", "subject" => "x"})}}
    end)

    assert {:ok, _event} = CalendarAPI.create_event(integration, calendar_id, event_data)
    assert_received {:transaction_id, transaction_id}
    transaction_id
  end

  defp insert_outlook_integration do
    insert(:calendar_integration,
      user: insert(:user),
      provider: "outlook",
      access_token_encrypted: Encryption.encrypt("valid_token"),
      token_expires_at: DateTime.add(DateTime.utc_now(), 3600)
    )
  end
end
