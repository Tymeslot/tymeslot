defmodule Tymeslot.Integrations.Calendar.CallbackPersistenceTest do
  use Tymeslot.DataCase, async: true

  @moduletag :integrations

  use Oban.Testing, repo: Tymeslot.Repo

  import Mox
  import Tymeslot.Factory

  alias Tymeslot.Integrations.Calendar.CalendarIntegrationSchema
  alias Tymeslot.Integrations.Calendar.CallbackPersistence
  alias Tymeslot.Workers.IntegrationHealthWorker

  setup :verify_on_exit!

  defp tokens(account_id) do
    %{
      access_token: "new-access",
      refresh_token: "new-refresh",
      expires_at: DateTime.add(DateTime.utc_now(:second), 3600, :second),
      scope: "calendar",
      provider_account_id: account_id,
      provider_account_email: account_id && "#{account_id}@example.com"
    }
  end

  defp listed, do: [%{"id" => "cal1", "name" => "Primary", "selected" => true}]

  test "creates an integration for a new account and discovers its calendars" do
    user = insert(:user)
    insert(:profile, user: user)

    expect(OutlookCalendarAPIMock, :list_calendars, fn _integration ->
      {:ok, [%{id: "cal1", name: "Calendar", primary: true}]}
    end)

    assert {:ok, integration} =
             CallbackPersistence.upsert("outlook", user.id, nil, tokens("oid-1"))

    assert %{provider: "outlook", name: "Outlook Calendar", is_active: true} = integration
    assert integration.provider_account_id == "oid-1"
    assert integration.calendar_list != []
  end

  test "reconnects the integration already connected to the account" do
    user = insert(:user)

    existing =
      insert(:calendar_integration,
        user: user,
        provider: "google",
        provider_account_id: "sub-1",
        calendar_list: listed()
      )

    assert {:ok, %{id: id} = reconnected} =
             CallbackPersistence.upsert("google", user.id, nil, tokens("sub-1"))

    assert id == existing.id

    assert CalendarIntegrationSchema.decrypt_oauth_tokens(reconnected).access_token ==
             "new-access"
  end

  # The reconnect a paused integration's own "Reconnect" button starts: both
  # providers reactivate it, as connecting means wanting it active.
  test "reactivates a paused integration reconnected by id, for either provider" do
    user = insert(:user)

    for provider <- ["google", "outlook"] do
      paused =
        insert(:calendar_integration,
          user: user,
          provider: provider,
          provider_account_id: "#{provider}-account",
          is_active: false,
          calendar_list: listed()
        )

      assert {:ok, %{id: id, is_active: true}} =
               CallbackPersistence.upsert(
                 provider,
                 user.id,
                 paused.id,
                 tokens("#{provider}-account")
               )

      assert id == paused.id
    end
  end

  test "refuses a reconnect whose tokens belong to another account" do
    user = insert(:user)

    existing =
      insert(:calendar_integration,
        user: user,
        provider: "google",
        provider_account_id: "sub-1",
        calendar_list: listed()
      )

    assert {:error, _message} =
             CallbackPersistence.upsert("google", user.id, existing.id, tokens("sub-2"))

    assert CalendarIntegrationSchema.decrypt_oauth_tokens(Repo.reload!(existing)).access_token !=
             "new-access"
  end

  test "refuses a reconnect of another user's integration" do
    other = insert(:calendar_integration, provider: "google", calendar_list: listed())

    assert {:error, "Integration not found"} =
             CallbackPersistence.upsert("google", insert(:user).id, other.id, tokens(nil))
  end

  test "will not guess which integration an unidentified account belongs to" do
    user = insert(:user)
    insert(:calendar_integration, user: user, provider: "outlook", calendar_list: listed())

    assert {:error, "Could not identify your Outlook account." <> _rest} =
             CallbackPersistence.upsert("outlook", user.id, nil, tokens(nil))
  end

  # A reconnect proves the grant: the health streak behind any auto-pause
  # starts again, and a probe confirms the recovery straight away.
  test "resets the health of the integration it reconnects" do
    user = insert(:user)

    existing =
      insert(:calendar_integration,
        user: user,
        provider: "google",
        provider_account_id: "sub-1",
        calendar_list: listed()
      )

    assert {:ok, _reconnected} =
             CallbackPersistence.upsert("google", user.id, nil, tokens("sub-1"))

    assert_enqueued(
      worker: IntegrationHealthWorker,
      args: %{"type" => "calendar", "integration_id" => existing.id}
    )
  end

  # Out of use for a while, so its calendar list is read afresh even though
  # it still holds one.
  test "rediscovers the calendars of an integration it reactivates" do
    user = insert(:user)

    paused =
      insert(:calendar_integration,
        user: user,
        provider: "outlook",
        provider_account_id: "oid-paused",
        is_active: false,
        calendar_list: listed()
      )

    expect(OutlookCalendarAPIMock, :list_calendars, fn _integration ->
      {:ok, [%{"id" => "cal2", "name" => "Work", "isDefaultCalendar" => true}]}
    end)

    assert {:ok, %{id: id, is_active: true} = reactivated} =
             CallbackPersistence.upsert("outlook", user.id, nil, tokens("oid-paused"))

    assert id == paused.id
    assert Enum.map(reactivated.calendar_list, & &1.id) == ["cal2"]
  end
end
