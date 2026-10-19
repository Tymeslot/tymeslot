defmodule TymeslotWeb.CalendarOAuthReactivationTest do
  # The token exchange is replaced with :meck, which is global.
  use TymeslotWeb.ConnCase, async: false

  @moduletag :calendar
  @moduletag :integrations

  import Ecto.Query, only: [from: 2]
  import Mox
  import Tymeslot.AuthTestHelpers, only: [log_in_user: 2]
  import Tymeslot.Factory
  import Tymeslot.OAuthFlowHelpers

  alias Tymeslot.Integrations.Calendar.CalendarEntry
  alias Tymeslot.Integrations.Calendar.CalendarIntegrationSchema
  alias Tymeslot.Integrations.Shared.OAuth.GoogleOAuthHelper
  alias Tymeslot.Repo

  @state_secret "test_google_state_secret"

  setup :verify_on_exit!

  setup do
    original = Application.get_env(:tymeslot, :google_oauth)

    Application.put_env(
      :tymeslot,
      :google_oauth,
      Keyword.merge(original || [], state_secret: @state_secret)
    )

    :meck.new(GoogleOAuthHelper, [:passthrough, :no_link])

    on_exit(fn ->
      :meck.unload(GoogleOAuthHelper)

      if is_nil(original),
        do: Application.delete_env(:tymeslot, :google_oauth),
        else: Application.put_env(:tymeslot, :google_oauth, original)
    end)

    :ok
  end

  # A paused integration is reactivated with its calendars read afresh, and
  # discovery's selection is not the owner's: a calendar a meeting type books
  # into must come back selected and blocking.
  test "reconnecting a paused Google calendar keeps a meeting type's calendar blocking", %{
    conn: conn
  } do
    user = insert(:user)
    paused = paused_integration(user, "work")

    insert(:meeting_type,
      user: user,
      calendar_integration_id: paused.id,
      target_calendar_id: "team"
    )

    reactivated = reconnect(conn, user, paused, [work(), team()])

    assert reactivated.is_active

    assert %{selected: true, blocks_availability: true} =
             Enum.find(reactivated.calendar_list, &(&1.id == "team"))
  end

  test "reconnecting keeps the booking calendar the owner chose while it still exists", %{
    conn: conn
  } do
    user = insert(:user)
    paused = paused_integration(user, "team")

    reactivated = reconnect(conn, user, paused, [work(), team()])

    assert reactivated.default_booking_calendar_id == "team"

    assert %{selected: true, blocks_availability: true} =
             Enum.find(reactivated.calendar_list, &(&1.id == "team"))
  end

  test "reconnecting moves bookings to the primary calendar once the chosen one is gone", %{
    conn: conn
  } do
    user = insert(:user)

    paused =
      paused_integration(user, "team", [
        %{"id" => "work", "name" => "Work", "primary" => true, "blocks_availability" => false},
        %{"id" => "team", "name" => "Team", "selected" => true}
      ])

    reactivated =
      reconnect(conn, user, paused, [
        %{"id" => "other", "summary" => "Other", "selected" => true},
        work()
      ])

    assert reactivated.default_booking_calendar_id == "work"

    assert %{selected: true, blocks_availability: true} =
             Enum.find(reactivated.calendar_list, &(&1.id == "work"))
  end

  # The callback read the integration before discovery went to the network;
  # what the owner changed meanwhile is what the reconnect builds on.
  test "reconnecting keeps changes the owner made while discovery ran", %{conn: conn} do
    user = insert(:user)
    paused = paused_integration(user, "team")

    reactivated =
      reconnect(conn, user, paused, [other(), work(), team()], fn ->
        Repo.update_all(
          from(ci in CalendarIntegrationSchema, where: ci.id == ^paused.id),
          set: [
            default_booking_calendar_id: "other",
            calendar_list: [
              %CalendarEntry{id: "other", name: "Other", selected: true},
              %CalendarEntry{id: "work", name: "Work", primary: true, blocks_availability: false}
            ]
          ]
        )
      end)

    assert reactivated.default_booking_calendar_id == "other"

    assert %{blocks_availability: false} =
             Enum.find(reactivated.calendar_list, &(&1.id == "work"))
  end

  defp work, do: %{"id" => "work", "summary" => "Work", "primary" => true, "selected" => true}
  defp other, do: %{"id" => "other", "summary" => "Other", "selected" => true}
  defp team, do: %{"id" => "team", "summary" => "Team", "selected" => false}

  defp paused_integration(user, default_booking_calendar_id, calendar_list \\ nil) do
    insert(:profile, user: user)

    insert(:calendar_integration,
      user: user,
      provider: "google",
      provider_account_id: "sub-1",
      is_active: false,
      default_booking_calendar_id: default_booking_calendar_id,
      calendar_list:
        calendar_list ||
          [
            %{"id" => "work", "name" => "Work", "primary" => true, "selected" => true},
            %{"id" => "team", "name" => "Team", "selected" => true}
          ]
    )
  end

  # Runs the callback the provider redirects to, with the code exchanged for
  # the account's tokens and discovery answering `discovered`, after running
  # `meanwhile`.
  defp reconnect(conn, user, paused, discovered, meanwhile \\ fn -> :ok end) do
    :meck.expect(GoogleOAuthHelper, :exchange_code_for_tokens, fn "code", _uri, _opts ->
      {:ok,
       %{
         access_token: "new-access",
         refresh_token: "new-refresh",
         expires_at: DateTime.add(DateTime.utc_now(:second), 3600, :second),
         scope: "https://www.googleapis.com/auth/calendar",
         provider_account_id: "sub-1",
         provider_account_email: "sub-1@example.com"
       }}
    end)

    expect(GoogleCalendarAPIMock, :list_calendars, fn _integration ->
      meanwhile.()
      {:ok, discovered}
    end)

    conn =
      conn
      |> log_in_user(user)
      |> get(~p"/auth/google/calendar/callback", %{
        "code" => "code",
        "state" => flow_state(user.id, :google, @state_secret)
      })

    assert redirected_to(conn) == "/dashboard"
    Repo.get!(CalendarIntegrationSchema, paused.id)
  end
end
